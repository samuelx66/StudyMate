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
        case resolvedToComposite(fromRoleKey: String, speakerIDs: [Int], isOverlap: Bool, speakerRole: String?, displayName: String)
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

    public struct MergeSpeakerResult: Equatable, Sendable {
        public let updatedCount: Int
        public let affectedSourceIDs: Set<Int>
        public let targetSpeakerID: Int

        public init(updatedCount: Int, affectedSourceIDs: Set<Int>, targetSpeakerID: Int) {
            self.updatedCount = updatedCount
            self.affectedSourceIDs = affectedSourceIDs
            self.targetSpeakerID = targetSpeakerID
        }
    }

    private let lock = NSLock()

    public init() {}

    /// 判断角色标签是否属于复合/多说话人标签（如 s1+s2, s1->s2, s1→s2, jim+lily 等）
    public static func isCompositeRole(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("+") || trimmed.contains("→") || trimmed.contains("->") || trimmed.contains("/")
    }

    /// 从复合角色标签中按顺序提取各组成部分原始名称（保留原始大小写，如从 "Jim+Lily" 提取 ["Jim", "Lily"]）
    public static func extractRawCompositeParts(from raw: String) -> [String] {
        let cleaned = raw
            .replacingOccurrences(of: "->", with: "+")
            .replacingOccurrences(of: "→", with: "+")
            .replacingOccurrences(of: "/", with: "+")
        var result = [String]()
        for part in cleaned.split(separator: "+") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result.append(trimmed)
            }
        }
        return result
    }

    /// 判断复合角色标签是否完全由默认角色代号组成（如 "s2+s3", "s1->s2" 返回 true；而 "jim+lily" 返回 false）
    public static func isDefaultCompositeRole(_ raw: String) -> Bool {
        guard isCompositeRole(raw) else { return false }
        let parts = extractRawCompositeParts(from: raw)
        return !parts.isEmpty && parts.allSatisfy { speakerID(from: $0) != nil }
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

    /// 标准化角色标识符（仅将默认编号如 "1", "S1", "s1" 统一为 "s1"，自定义姓名严格保留原始大小写）
    public static func normalizeRoleKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("s"), let num = Int(lower.dropFirst()), num >= 1 {
            return "s\(num)"
        }
        if let intVal = Int(trimmed), intVal >= 1 {
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

    /// 执行重命名、合并或单一化判定（自定义姓名严格区分大小写，如 "Jim" 与 "jim" 视为两个不同的人）
    public func resolveRename(
        fromRoleKey: String,
        inputName: String,
        currentSpeakerNames: [String: String],
        allExistingSpeakerIDs: Set<Int> = []
    ) -> (action: RenameResult, updatedNames: [String: String]) {
        lock.lock()
        defer { lock.unlock() }

        let trimmedFrom = fromRoleKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInput = inputName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            return (.unchanged, currentSpeakerNames)
        }

        // 0. 如果输入与当前角色标签完全相同（且该角色未绑定其它自定义名称），直接返回未修改
        let normFromKey = Self.normalizeRoleKey(trimmedFrom)
        let normInputKey = Self.normalizeRoleKey(trimmedInput)
        if Self.speakerID(from: normFromKey) != nil && normInputKey == normFromKey {
            if let boundName = currentSpeakerNames[normFromKey], boundName != normFromKey {
                // 允许将已绑定自定义名称的角色（如 s1: Alice）通过 inputName="s1" 恢复为默认 s1
            } else {
                return (.unchanged, currentSpeakerNames)
            }
        } else if trimmedInput == trimmedFrom {
            return (.unchanged, currentSpeakerNames)
        }

        var names = currentSpeakerNames

        // 0.5 如果目标输入本身是一个复合角色标签（如 "jim+lily" 或 "s2+s3"）
        if Self.isCompositeRole(trimmedInput) {
            let rawParts = Self.extractRawCompositeParts(from: trimmedInput)
            let isOverlap = trimmedInput.contains("+") || trimmedInput.contains("/")
            let allDefaultKeys = !rawParts.isEmpty && rawParts.allSatisfy { Self.speakerID(from: $0) != nil }
            let sourceCandIDs = Self.extractCandidateRoles(from: trimmedFrom).compactMap { Self.speakerID(from: $0) }
            var maxID = max(
                max(names.keys.compactMap { Self.speakerID(from: $0) }.max() ?? -1, allExistingSpeakerIDs.max() ?? -1),
                sourceCandIDs.max() ?? -1
            )
            var resolvedIDs = [Int]()
            for (idx, part) in rawParts.enumerated() {
                if let sid = Self.speakerID(from: part) {
                    resolvedIDs.append(sid)
                    maxID = max(maxID, sid)
                } else if let matchedKey = names.first(where: { $0.value == part })?.key,
                          let sid = Self.speakerID(from: matchedKey) {
                    resolvedIDs.append(sid)
                    maxID = max(maxID, sid)
                } else if idx < sourceCandIDs.count {
                    let sid = sourceCandIDs[idx]
                    resolvedIDs.append(sid)
                    maxID = max(maxID, sid)
                } else {
                    maxID += 1
                    resolvedIDs.append(maxID)
                }
            }
            let finalIDs = resolvedIDs.isEmpty ? (sourceCandIDs.isEmpty ? [0] : sourceCandIDs) : resolvedIDs
            if allDefaultKeys {
                let sep = isOverlap ? "+" : "→"
                let display = finalIDs.map { Self.roleKey(for: $0) }.joined(separator: sep)
                return (.resolvedToComposite(
                    fromRoleKey: fromRoleKey,
                    speakerIDs: finalIDs,
                    isOverlap: isOverlap,
                    speakerRole: nil,
                    displayName: display
                ), names)
            } else {
                return (.resolvedToComposite(
                    fromRoleKey: fromRoleKey,
                    speakerIDs: finalIDs,
                    isOverlap: isOverlap,
                    speakerRole: trimmedInput,
                    displayName: trimmedInput
                ), names)
            }
        }

        // 反查源角色的标准代号键（例如从自定义姓名 "Alice" 反查出 "s1"，严格区分大小写）
        var resolvedSourceKey = normFromKey
        if Self.speakerID(from: resolvedSourceKey) == nil {
            for (key, name) in names {
                if name == trimmedFrom {
                    resolvedSourceKey = Self.normalizeRoleKey(key)
                    break
                }
            }
        }

        // 若源角色是以默认键（如 "s1"）传入，且其已绑定的自定义姓名与输入完全一致（含大小写），则无变化
        if Self.speakerID(from: normFromKey) != nil,
           let existing = names[resolvedSourceKey],
           existing == trimmedInput {
            return (.unchanged, currentSpeakerNames)
        }

        // 1. 如果源角色是一个复合/多说话人标签（如 "s1+s2", "s1->s2", "s1→s2", "jim+lily"）且输入为单一角色
        if Self.isCompositeRole(trimmedFrom) {
            // 1.1 检查输入是否是一个角色标识符（如 "s1", "s2", "1"）
            if let targetID = Self.speakerID(from: normInputKey) {
                let targetKey = Self.roleKey(for: targetID)
                let unifiedName = names[targetKey] ?? targetKey
                return (.resolvedToSingle(fromRoleKey: fromRoleKey, toRoleKey: targetKey, unifiedName: unifiedName, targetSpeakerID: targetID), names)
            }

            // 1.2 检查输入是否匹配某个已有角色的名字（严格区分大小写，如把 s1+s2 改为已有角色 "Jim"）
            for (existingKey, existingName) in names {
                if existingName == trimmedInput,
                   let targetID = Self.speakerID(from: existingKey) {
                    return (.resolvedToSingle(fromRoleKey: fromRoleKey, toRoleKey: existingKey, unifiedName: existingName, targetSpeakerID: targetID), names)
                }
            }

            // 1.3 输入了一个全新的单一角色姓名（如 "Alice"）
            let candidateRoles = Self.extractCandidateRoles(from: trimmedFrom)
            var assignedTargetID: Int? = nil
            for cand in candidateRoles {
                let existing = names[cand]
                if let cid = Self.speakerID(from: cand),
                   (existing == nil || existing == cand),
                   !allExistingSpeakerIDs.contains(cid) {
                    assignedTargetID = cid
                    break
                }
            }
            if assignedTargetID == nil {
                let existingIDs = names.keys.compactMap { Self.speakerID(from: $0) }
                let maxID = max(
                    max(existingIDs.max() ?? -1, allExistingSpeakerIDs.max() ?? -1),
                    candidateRoles.compactMap { Self.speakerID(from: $0) }.max() ?? 0
                )
                assignedTargetID = maxID + 1
            }

            let targetID = assignedTargetID!
            let targetKey = Self.roleKey(for: targetID)
            names[targetKey] = trimmedInput
            return (.resolvedToSingle(fromRoleKey: fromRoleKey, toRoleKey: targetKey, unifiedName: trimmedInput, targetSpeakerID: targetID), names)
        }

        // 2. 普通单说话人重命名、合并或恢复默认
        // 2.1 用户输入了自身对应的默认代号（例如把 Alice 改回 "s1" 或 "1"），恢复为默认编号并清除自定义名
        if Self.speakerID(from: normInputKey) != nil && normInputKey == resolvedSourceKey {
            names.removeValue(forKey: resolvedSourceKey)
            names.removeValue(forKey: trimmedFrom)
            for (k, v) in names where v == trimmedFrom {
                names.removeValue(forKey: k)
            }
            return (.renamed(roleKey: resolvedSourceKey, newName: resolvedSourceKey), names)
        }

        // 2.2 用户输入了另一个角色的标识符（例如输入了 "s2"）
        if let targetID = Self.speakerID(from: normInputKey) {
            let targetKey = Self.roleKey(for: targetID)
            let unifiedName = names[targetKey] ?? targetKey
            names.removeValue(forKey: resolvedSourceKey)
            names.removeValue(forKey: trimmedFrom)
            for (k, v) in names where v == trimmedFrom {
                names.removeValue(forKey: k)
            }
            if unifiedName != targetKey {
                names[targetKey] = unifiedName
            }
            return (.merged(fromRoleKey: fromRoleKey, toRoleKey: targetKey, unifiedName: unifiedName, updatedCount: 0), names)
        }

        // 2.3 检查输入的姓名是否已绑定到另一个角色（严格区分大小写：如把 s10 改名为 "Richard"，而 s11 已经是 "Richard"；但 "Jim" 与 "jim" 不合并）
        for (existingKey, existingName) in names {
            if existingKey != resolvedSourceKey && existingName == trimmedInput {
                // 触发智能合并！
                names.removeValue(forKey: resolvedSourceKey)
                names.removeValue(forKey: trimmedFrom)
                for (k, v) in names where v == trimmedFrom {
                    names.removeValue(forKey: k)
                }
                return (.merged(fromRoleKey: fromRoleKey, toRoleKey: existingKey, unifiedName: existingName, updatedCount: 0), names)
            }
        }

        // 2.4 普通重命名为全新姓名或仅大小写变更（如将 "jim" 改为 "Jim"，或将 "s1" 改为 "Alice"）
        names.removeValue(forKey: trimmedFrom)
        for (k, v) in names where v == trimmedFrom && k != resolvedSourceKey {
            names.removeValue(forKey: k)
        }
        names[resolvedSourceKey] = trimmedInput
        return (.renamed(roleKey: resolvedSourceKey, newName: trimmedInput), names)
    }

    /// 解析对单个断句修改发言人的结果（仅作用于当前句，不修改全局其它同角色句子；自定义姓名严格区分大小写）
    public func resolveSingleSentenceSpeaker(
        currentSegment: SentenceSegment,
        inputName: String,
        currentSpeakerNames: [String: String],
        allExistingSpeakerIDs: Set<Int> = [],
        otherSegmentsSpeakerIDs: Set<Int>? = nil
    ) -> SingleSentenceSpeakerResult {
        lock.lock()
        defer { lock.unlock() }

        let trimmedInput = inputName.trimmingCharacters(in: .whitespacesAndNewlines)
        var names = currentSpeakerNames
        let otherUsedIDs = otherSegmentsSpeakerIDs ?? allExistingSpeakerIDs

        // 1. 如果输入是一个复合标签（如用户输入了 "s2+s3", "jim+lily", "s1->s2", "Jim->Lily"）
        if Self.isCompositeRole(trimmedInput) {
            let rawParts = Self.extractRawCompositeParts(from: trimmedInput)
            let isOverlap = trimmedInput.contains("+") || trimmedInput.contains("/")
            let allDefaultKeys = !rawParts.isEmpty && rawParts.allSatisfy { Self.speakerID(from: $0) != nil }

            var maxID = max(
                max(names.keys.compactMap { Self.speakerID(from: $0) }.max() ?? -1, allExistingSpeakerIDs.max() ?? -1),
                max(currentSegment.speakerID ?? -1, currentSegment.speakerIDs.max() ?? -1)
            )
            var resolvedIDs = [Int]()
            for (idx, part) in rawParts.enumerated() {
                if let sid = Self.speakerID(from: part) {
                    resolvedIDs.append(sid)
                    maxID = max(maxID, sid)
                } else if let matchedKey = names.first(where: { $0.value == part })?.key,
                          let sid = Self.speakerID(from: matchedKey) {
                    resolvedIDs.append(sid)
                    maxID = max(maxID, sid)
                } else if idx < currentSegment.speakerIDs.count {
                    let sid = currentSegment.speakerIDs[idx]
                    resolvedIDs.append(sid)
                    maxID = max(maxID, sid)
                } else if idx == 0, let sid = currentSegment.speakerID {
                    resolvedIDs.append(sid)
                    maxID = max(maxID, sid)
                } else {
                    maxID += 1
                    resolvedIDs.append(maxID)
                }
            }
            let fallbackIDs = currentSegment.speakerIDs.isEmpty ? [currentSegment.speakerID ?? 0] : currentSegment.speakerIDs
            let finalIDs = resolvedIDs.isEmpty ? fallbackIDs : resolvedIDs

            if allDefaultKeys {
                let sep = isOverlap ? "+" : "→"
                let normalizedDisplay = finalIDs.map { Self.roleKey(for: $0) }.joined(separator: sep)
                return SingleSentenceSpeakerResult(
                    speakerID: finalIDs[0],
                    speakerIDs: finalIDs,
                    isOverlap: isOverlap,
                    speakerRole: nil,
                    displayName: normalizedDisplay,
                    updatedNames: names
                )
            } else {
                return SingleSentenceSpeakerResult(
                    speakerID: finalIDs[0],
                    speakerIDs: finalIDs,
                    isOverlap: isOverlap,
                    speakerRole: trimmedInput,
                    displayName: trimmedInput,
                    updatedNames: names
                )
            }
        }

        // 2. 检查输入是否是一个角色标识符（如 "s1", "s2", "1", "2"）
        let normalizedInputKey = Self.normalizeRoleKey(trimmedInput)
        if let targetID = Self.speakerID(from: normalizedInputKey) {
            let targetKey = Self.roleKey(for: targetID)
            let isCurrentSingleTarget = !Self.isCompositeRole(currentSegment.speakerRoleLabel)
                && (currentSegment.speakerID == targetID || currentSegment.speakerIDs == [targetID])
            let isResettingCurrentSentenceToDefault = isCurrentSingleTarget
                && currentSegment.speakerRole != nil
                && currentSegment.speakerRole != targetKey

            if isResettingCurrentSentenceToDefault {
                if !otherUsedIDs.contains(targetID) {
                    names.removeValue(forKey: targetKey)
                }
                return SingleSentenceSpeakerResult(
                    speakerID: targetID,
                    speakerIDs: [targetID],
                    isOverlap: false,
                    speakerRole: nil,
                    displayName: targetKey,
                    updatedNames: names
                )
            }

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

        // 3. 检查输入是否匹配某个已有角色的名字（严格区分大小写，如输入 "Jim" 仅匹配 "Jim"，不匹配 "jim"）
        for (existingKey, existingName) in names {
            if existingName == trimmedInput,
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

        // 4. 输入了一个新名字（如 "Alice"，或与已有 "jim" 大小写不同的新角色 "Jim"）
        // 4.1 如果当前句子原本是复合角色（如 s1+s2 或 jim+lily），尝试分配给其中未被其它句子占用的未命名候选角色
        if Self.isCompositeRole(currentSegment.speakerRoleLabel) {
            let rawParts = Self.extractRawCompositeParts(from: currentSegment.speakerRoleLabel)
            let candidateRoles = Self.extractCandidateRoles(from: currentSegment.speakerRoleLabel)
            var assignedTargetID: Int? = nil

            // 若输入名恰好对应自定义复合角色中的某一部分（例如从 "jim+lily" 选了 "lily"），优先取对应位置的未占用 speakerID
            if let matchIdx = rawParts.firstIndex(where: { $0 == trimmedInput }),
               matchIdx < currentSegment.speakerIDs.count {
                let candidateID = currentSegment.speakerIDs[matchIdx]
                let candidateKey = Self.roleKey(for: candidateID)
                let existing = names[candidateKey]
                if (existing == nil || existing == candidateKey) && !otherUsedIDs.contains(candidateID) {
                    assignedTargetID = candidateID
                }
            }

            if assignedTargetID == nil {
                for cand in candidateRoles {
                    let existing = names[cand]
                    if let cid = Self.speakerID(from: cand),
                       (existing == nil || existing == cand),
                       !otherUsedIDs.contains(cid) {
                        assignedTargetID = cid
                        break
                    }
                }
            }
            if assignedTargetID == nil {
                for sid in currentSegment.speakerIDs {
                    let key = Self.roleKey(for: sid)
                    let existing = names[key]
                    if (existing == nil || existing == key) && !otherUsedIDs.contains(sid) {
                        assignedTargetID = sid
                        break
                    }
                }
            }
            if assignedTargetID == nil {
                let existingIDs = names.keys.compactMap { Self.speakerID(from: $0) }
                let maxID = max(
                    max(existingIDs.max() ?? -1, allExistingSpeakerIDs.max() ?? -1),
                    max(candidateRoles.compactMap { Self.speakerID(from: $0) }.max() ?? -1, currentSegment.speakerIDs.max() ?? 0)
                )
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

        // 4.2 单独修改本句为一个新名字：为该单句的新角色分配一个新的独立 speakerID，绝不覆盖绑架原角色的全局映射
        let existingIDs = names.keys.compactMap { Self.speakerID(from: $0) }
        let currentMax = max(currentSegment.speakerID ?? -1, currentSegment.speakerIDs.max() ?? -1)
        let maxID = max(
            max(existingIDs.max() ?? -1, allExistingSpeakerIDs.max() ?? -1),
            currentMax
        )
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

    /// 批量在断句段落列表中应用合并（将 fromRoleKey 合并为 toRoleKey / unifiedName）
    /// 返回更新句数、涉及的所有源 speakerID 集合，以及目标 speakerID
    @discardableResult
    public func mergeSpeakerEx(
        fromRoleKey: String,
        toRoleKey: String,
        unifiedName: String? = nil,
        in segments: inout [SentenceSegment]
    ) -> MergeSpeakerResult {
        lock.lock()
        defer { lock.unlock() }

        let trimmedFrom = fromRoleKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTo = toRoleKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normFrom = Self.normalizeRoleKey(trimmedFrom)
        let normFromTarget = trimmedFrom.replacingOccurrences(of: "→", with: "->")

        // 1. 确定目标 speakerID (targetSpeakerID)
        var resolvedTargetID: Int? = Self.speakerID(from: trimmedTo)
        if resolvedTargetID == nil, let unifiedName, !unifiedName.isEmpty {
            for seg in segments {
                if let r = seg.speakerRole, r == unifiedName, let sid = seg.speakerID {
                    resolvedTargetID = sid
                    break
                }
            }
        }
        if resolvedTargetID == nil {
            let existingIDs = segments.compactMap { $0.speakerID }
            resolvedTargetID = (existingIDs.max() ?? -1) + 1
        }
        let targetSpeakerID = resolvedTargetID!
        let targetKey = Self.roleKey(for: targetSpeakerID)

        // 2. 确定候选源数值 ID
        let fromNumericalID = Self.speakerID(from: trimmedFrom)

        // 3. 收集所有直接匹配源角色的句子索引和相关源 speakerID
        var matchedIndices = [Int]()
        var affectedSourceIDs = Set<Int>()
        if let fromNumericalID, fromNumericalID != targetSpeakerID {
            affectedSourceIDs.insert(fromNumericalID)
        }

        for i in 0..<segments.count {
            let seg = segments[i]
            let segLabel = seg.speakerRoleLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let normSegLabel = segLabel.replacingOccurrences(of: "→", with: "->")
            let segRole = seg.speakerRole?.trimmingCharacters(in: .whitespacesAndNewlines)

            var isMatch = false
            if segRole == trimmedFrom || segLabel == trimmedFrom || normSegLabel == normFromTarget {
                isMatch = true
            } else if let fID = fromNumericalID {
                if !seg.isSpeakerOverlap && seg.speakerIDs.count <= 1 &&
                   (segRole == nil || segRole == trimmedFrom || segRole == normFrom) &&
                   (seg.speakerID == fID || seg.speakerIDs.contains(fID)) {
                    isMatch = true
                }
            }

            if isMatch {
                matchedIndices.append(i)
                if let sid = seg.speakerID, sid != targetSpeakerID {
                    affectedSourceIDs.insert(sid)
                }
                for id in seg.speakerIDs where id != targetSpeakerID {
                    affectedSourceIDs.insert(id)
                }
            }
        }

        // 4. 计算最终角色名称
        let finalRoleName: String?
        if let unifiedName, !unifiedName.isEmpty {
            finalRoleName = (unifiedName == targetKey) ? nil : unifiedName
        } else {
            finalRoleName = nil
        }

        // 5. 更新所有直接匹配的句子
        var count = 0
        for idx in matchedIndices {
            segments[idx].speakerID = targetSpeakerID
            segments[idx].speakerIDs = [targetSpeakerID]
            segments[idx].isSpeakerOverlap = false
            segments[idx].speakerRole = finalRoleName
            count += 1
        }

        // 6. 处理非直接匹配但包含旧 ID 的重叠/多说话人句子
        if !affectedSourceIDs.isEmpty {
            for i in 0..<segments.count {
                guard !matchedIndices.contains(i) else { continue }
                var modified = false
                var updatedIDs = segments[i].speakerIDs

                if let sid = segments[i].speakerID, affectedSourceIDs.contains(sid) {
                    segments[i].speakerID = targetSpeakerID
                    modified = true
                }

                if updatedIDs.contains(where: { affectedSourceIDs.contains($0) }) {
                    updatedIDs = updatedIDs.map { affectedSourceIDs.contains($0) ? targetSpeakerID : $0 }
                    segments[i].speakerIDs = Array(NSOrderedSet(array: updatedIDs)) as? [Int] ?? Array(Set(updatedIDs)).sorted()
                    if segments[i].speakerIDs.count == 1 {
                        segments[i].speakerID = segments[i].speakerIDs[0]
                        segments[i].isSpeakerOverlap = false
                        segments[i].speakerRole = finalRoleName
                    } else if let existingRole = segments[i].speakerRole, Self.isCompositeRole(existingRole) {
                        let sep = segments[i].isSpeakerOverlap ? "+" : "→"
                        let replacementLabel = finalRoleName ?? targetKey
                        let updatedParts = Self.extractRawCompositeParts(from: existingRole).map { part -> String in
                            if part == trimmedFrom || Self.normalizeRoleKey(part) == normFrom {
                                return replacementLabel
                            }
                            return part
                        }
                        var dedupedParts = [String]()
                        for p in updatedParts where !dedupedParts.contains(p) {
                            dedupedParts.append(p)
                        }
                        segments[i].speakerRole = dedupedParts.joined(separator: sep)
                    }
                    modified = true
                }

                if modified {
                    count += 1
                }
            }
        }

        // 7. 确保原本就是目标说话人的单人句子，其 speakerRole 统一为目标名称
        if let finalRoleName {
            for i in 0..<segments.count {
                if segments[i].speakerID == targetSpeakerID && segments[i].speakerIDs == [targetSpeakerID] && !segments[i].isSpeakerOverlap {
                    segments[i].speakerRole = finalRoleName
                }
            }
        }

        return MergeSpeakerResult(
            updatedCount: count,
            affectedSourceIDs: affectedSourceIDs,
            targetSpeakerID: targetSpeakerID
        )
    }

    /// 兼容旧签名的 mergeSpeaker
    @discardableResult
    public func mergeSpeaker(
        fromRoleKey: String,
        toRoleKey: String,
        in segments: inout [SentenceSegment]
    ) -> Int {
        mergeSpeakerEx(fromRoleKey: fromRoleKey, toRoleKey: toRoleKey, unifiedName: nil, in: &segments).updatedCount
    }
}
