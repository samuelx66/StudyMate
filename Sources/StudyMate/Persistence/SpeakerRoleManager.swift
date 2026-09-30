import Foundation

/// 角色管理与智能合并纠错引擎：
/// 1. 维护角色标识符与真实姓名的映射字典（如 `["s1": "Jim", "s2": "Tom"]`）；
/// 2. 支持多说话人复合角色（如 `s1+s2`, `s1->s2`, `s1→s2`）修正为单一某个人；
/// 3. 支持智能纠错合并：当用户把 s2 改名为 Jim 且 s1 已经是 Jim（或直接改名为 s1）时，
///    自动触发全量合并，将所有 s2 句子归并至 s1，消除声纹过切分。
/// 说话人修改作用范围：仅此句 vs 所有相同角色
public enum SpeakerChangeScope: String, CaseIterable, Sendable, Codable {
    case thisSentenceOnly
    case allMatching
}

public final class SpeakerRoleManager: @unchecked Sendable {
    public static let shared = SpeakerRoleManager()

    public enum RenameResult: Equatable, Sendable {
        case renamed(roleKey: String, newName: String)
        case merged(fromRoleKey: String, toRoleKey: String, unifiedName: String, updatedCount: Int)
        case resolvedToSingle(fromRoleKey: String, toRoleKey: String, unifiedName: String, targetSpeakerID: Int)
        case unchanged
    }

    public struct SingleSentenceSpeakerResult: Equatable, Sendable {
        public let speakerID: Int
        public let speakerIDs: [Int]
        public let isOverlap: Bool
        public let speakerRole: String?
        public let displayName: String
        public let updatedNames: [String: String]
    }

    private let lock = NSLock()

    public init() {}

    /// 判断角色标签是否属于复合/多说话人标签（如 s1+s2, s1->s2, s1→s2 等）
    public static func isCompositeRole(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("+") || trimmed.contains("→") || trimmed.contains("->") || trimmed.contains("/")
    }

    /// 从复合角色标签中提取涉及的候选角色代号（如从 "s1+s2" 或 "s1->s2" 提取 ["s1", "s2"]）
    public static func extractCandidateRoles(from raw: String) -> [String] {
        let cleaned = raw
            .replacingOccurrences(of: "->", with: "+")
            .replacingOccurrences(of: "→", with: "+")
            .replacingOccurrences(of: "/", with: "+")
        var result = [String]()
        for part in cleaned.split(separator: "+") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = normalizeRoleKey(trimmed)
            if !normalized.isEmpty && !result.contains(normalized) {
                result.append(normalized)
            }
        }
        return result
    }

    /// 标准化角色标识符（如将 "1", "S1", "s1" 统一为 "s1"）
    public static func normalizeRoleKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("s") {
            return trimmed
        }
        if let intVal = Int(trimmed) {
            return "s\(intVal)"
        }
        return trimmed
    }

    /// 将角色整数 ID（从 0 开始）格式化为内部键（0 -> "s1", 1 -> "s2"）
    public static func roleKey(for speakerID: Int) -> String {
        "s\(speakerID + 1)"
    }

    /// 从角色内部键解析整数 ID（"s1" -> 0, "s2" -> 1）
    public static func speakerID(from roleKey: String) -> Int? {
        let normalized = normalizeRoleKey(roleKey)
        guard normalized.hasPrefix("s"), let num = Int(normalized.dropFirst()), num >= 1 else {
            return nil
        }
        return num - 1
    }

    /// 执行重命名、合并或单一化判定
    public func resolveRename(
        fromRoleKey: String,
        inputName: String,
        currentSpeakerNames: [String: String]
    ) -> (action: RenameResult, updatedNames: [String: String]) {
        lock.lock()
        defer { lock.unlock() }

        let normalizedSource = Self.normalizeRoleKey(fromRoleKey)
        let trimmedInput = inputName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            return (.unchanged, currentSpeakerNames)
        }

        var names = currentSpeakerNames

        // 1. 如果源角色是一个复合/多说话人标签（如 "s1+s2", "s1->s2", "s1→s2"）
        if Self.isCompositeRole(fromRoleKey) {
            let normalizedInputKey = Self.normalizeRoleKey(trimmedInput)
            // 1.1 检查输入是否是一个角色标识符（如 "s1", "s2", "1"）
            if let targetID = Self.speakerID(from: normalizedInputKey) {
                let targetKey = Self.roleKey(for: targetID)
                let unifiedName = names[targetKey] ?? targetKey
                return (.resolvedToSingle(fromRoleKey: fromRoleKey, toRoleKey: targetKey, unifiedName: unifiedName, targetSpeakerID: targetID), names)
            }

            // 1.2 检查输入是否匹配某个已有角色的名字（如把 s1+s2 改为已有角色 "Jim"，而 s1 的名字是 "Jim"）
            for (existingKey, existingName) in names {
                if existingName.caseInsensitiveCompare(trimmedInput) == .orderedSame,
                   let targetID = Self.speakerID(from: existingKey) {
                    return (.resolvedToSingle(fromRoleKey: fromRoleKey, toRoleKey: existingKey, unifiedName: existingName, targetSpeakerID: targetID), names)
                }
            }

            // 1.3 输入了一个全新的角色姓名（如 "Alice"）
            let candidateRoles = Self.extractCandidateRoles(from: fromRoleKey)
            var assignedTargetID: Int? = nil
            for cand in candidateRoles {
                if let cid = Self.speakerID(from: cand), names[cand] == nil {
                    assignedTargetID = cid
                    break
                }
            }
            if assignedTargetID == nil {
                let existingIDs = names.keys.compactMap { Self.speakerID(from: $0) }
                let maxID = existingIDs.max() ?? (candidateRoles.compactMap { Self.speakerID(from: $0) }.max() ?? 0)
                assignedTargetID = maxID + 1
            }

            let targetID = assignedTargetID!
            let targetKey = Self.roleKey(for: targetID)
            names[targetKey] = trimmedInput
            return (.resolvedToSingle(fromRoleKey: fromRoleKey, toRoleKey: targetKey, unifiedName: trimmedInput, targetSpeakerID: targetID), names)
        }

        // 2. 普通单说话人重命名或合并
        // 检查输入是否是一个已有的角色标识符（例如输入了 "s1"）
        let normalizedInputKey = Self.normalizeRoleKey(trimmedInput)
        if normalizedInputKey != normalizedSource,
           let targetID = Self.speakerID(from: normalizedInputKey),
           Self.speakerID(from: normalizedSource) != nil {
            let targetKey = Self.roleKey(for: targetID)
            let unifiedName = names[targetKey] ?? names[normalizedSource] ?? targetKey
            names.removeValue(forKey: normalizedSource)
            names[targetKey] = unifiedName
            return (.merged(fromRoleKey: normalizedSource, toRoleKey: targetKey, unifiedName: unifiedName, updatedCount: 0), names)
        }

        // 检查输入的姓名是否已绑定到另一个角色（例如把 s2 改名为 "Jim"，而 s1 已经是 "Jim"）
        for (existingKey, existingName) in names {
            if existingKey != normalizedSource && existingName.caseInsensitiveCompare(trimmedInput) == .orderedSame {
                // 触发智能合并！
                names.removeValue(forKey: normalizedSource)
                return (.merged(fromRoleKey: normalizedSource, toRoleKey: existingKey, unifiedName: existingName, updatedCount: 0), names)
            }
        }

        // 普通重命名
        names[normalizedSource] = trimmedInput
        return (.renamed(roleKey: normalizedSource, newName: trimmedInput), names)
    }

    /// 解析对单个断句修改发言人的结果（仅作用于当前句，不修改全局其它同角色句子）
    public func resolveSingleSentenceSpeaker(
        currentSegment: SentenceSegment,
        inputName: String,
        currentSpeakerNames: [String: String]
    ) -> SingleSentenceSpeakerResult {
        lock.lock()
        defer { lock.unlock() }

        let trimmedInput = inputName.trimmingCharacters(in: .whitespacesAndNewlines)
        var names = currentSpeakerNames

        // 1. 如果输入是一个复合标签（如用户手动输入了 "s1+s2" 或 "s1->s2"）
        if Self.isCompositeRole(trimmedInput) {
            let candidateRoles = Self.extractCandidateRoles(from: trimmedInput)
            let ids = candidateRoles.compactMap { Self.speakerID(from: $0) }
            let finalIDs = ids.isEmpty ? [0] : ids
            let isOverlap = trimmedInput.contains("+")
            return SingleSentenceSpeakerResult(
                speakerID: finalIDs[0],
                speakerIDs: finalIDs,
                isOverlap: isOverlap,
                speakerRole: nil,
                displayName: trimmedInput,
                updatedNames: names
            )
        }

        // 2. 检查输入是否是一个角色标识符（如 "s1", "s2", "1", "2"）
        let normalizedInputKey = Self.normalizeRoleKey(trimmedInput)
        if let targetID = Self.speakerID(from: normalizedInputKey) {
            let targetKey = Self.roleKey(for: targetID)
            let assignedName = names[targetKey]
            let roleToSet: String? = (assignedName != nil && assignedName != targetKey) ? assignedName : nil
            let displayName = assignedName ?? targetKey
            return SingleSentenceSpeakerResult(
                speakerID: targetID,
                speakerIDs: [targetID],
                isOverlap: false,
                speakerRole: roleToSet,
                displayName: displayName,
                updatedNames: names
            )
        }

        // 3. 检查输入是否匹配某个已有角色的名字（如输入 "Jim"，而 s1 已经是 "Jim"）
        for (existingKey, existingName) in names {
            if existingName.caseInsensitiveCompare(trimmedInput) == .orderedSame,
               let targetID = Self.speakerID(from: existingKey) {
                return SingleSentenceSpeakerResult(
                    speakerID: targetID,
                    speakerIDs: [targetID],
                    isOverlap: false,
                    speakerRole: existingName,
                    displayName: existingName,
                    updatedNames: names
                )
            }
        }

        // 4. 输入了一个新名字（如 "Alice"）
        // 4.1 如果当前句子原本是复合角色（如 s1+s2），尝试分配给其中未命名的候选角色
        if Self.isCompositeRole(currentSegment.speakerRoleLabel) {
            let candidateRoles = Self.extractCandidateRoles(from: currentSegment.speakerRoleLabel)
            var assignedTargetID: Int? = nil
            for cand in candidateRoles {
                if let cid = Self.speakerID(from: cand), names[cand] == nil {
                    assignedTargetID = cid
                    break
                }
            }
            if assignedTargetID == nil {
                let existingIDs = names.keys.compactMap { Self.speakerID(from: $0) }
                let maxID = existingIDs.max() ?? (candidateRoles.compactMap { Self.speakerID(from: $0) }.max() ?? 0)
                assignedTargetID = maxID + 1
            }
            let targetID = assignedTargetID!
            let targetKey = Self.roleKey(for: targetID)
            names[targetKey] = trimmedInput
            return SingleSentenceSpeakerResult(
                speakerID: targetID,
                speakerIDs: [targetID],
                isOverlap: false,
                speakerRole: trimmedInput,
                displayName: trimmedInput,
                updatedNames: names
            )
        }

        // 4.2 如果当前句子是单人角色
        if let currentID = currentSegment.speakerID {
            let currentKey = Self.roleKey(for: currentID)
            // 若当前角色代号尚未有自定义名字（例如仅为 s1），则将其绑定为输入的名字
            if names[currentKey] == nil || names[currentKey] == currentKey {
                names[currentKey] = trimmedInput
                return SingleSentenceSpeakerResult(
                    speakerID: currentID,
                    speakerIDs: [currentID],
                    isOverlap: false,
                    speakerRole: trimmedInput,
                    displayName: trimmedInput,
                    updatedNames: names
                )
            }
        }

        // 当前角色已有其它名字，且仅改此句：为新角色分配一个新的 speakerID
        let existingIDs = names.keys.compactMap { Self.speakerID(from: $0) }
        let currentID = currentSegment.speakerID ?? 0
        let maxID = max(existingIDs.max() ?? 0, currentID)
        let newID = maxID + 1
        let newKey = Self.roleKey(for: newID)
        names[newKey] = trimmedInput
        return SingleSentenceSpeakerResult(
            speakerID: newID,
            speakerIDs: [newID],
            isOverlap: false,
            speakerRole: trimmedInput,
            displayName: trimmedInput,
            updatedNames: names
        )
    }

    /// 批量在断句段落列表中应用合并（将 fromID 合并为 toID）
    public func mergeSpeaker(
        fromRoleKey: String,
        toRoleKey: String,
        in segments: inout [SentenceSegment]
    ) -> Int {
        guard let fromID = Self.speakerID(from: fromRoleKey),
              let toID = Self.speakerID(from: toRoleKey),
              fromID != toID else { return 0 }

        var count = 0
        for i in 0..<segments.count {
            var modified = false
            var updatedIDs = segments[i].speakerIDs

            if segments[i].speakerID == fromID {
                segments[i].speakerID = toID
                modified = true
            }

            if updatedIDs.contains(fromID) {
                updatedIDs = updatedIDs.map { $0 == fromID ? toID : $0 }
                segments[i].speakerIDs = Array(Set(updatedIDs)).sorted()
                modified = true
            }

            if modified {
                count += 1
            }
        }
        return count
    }
}
