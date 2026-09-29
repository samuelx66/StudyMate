import Foundation

/// 角色管理与智能合并纠错引擎：
/// 1. 维护角色标识符与真实姓名的映射字典（如 `["s1": "Jim", "s2": "Tom"]`）；
/// 2. 支持智能纠错合并：当用户把 s2 改名为 Jim 且 s1 已经是 Jim（或直接改名为 s1）时，
///    自动触发全量合并，将所有 s2 句子归并至 s1，消除声纹过切分。
public final class SpeakerRoleManager: @unchecked Sendable {
    public static let shared = SpeakerRoleManager()

    public enum RenameResult: Equatable, Sendable {
        case renamed(roleKey: String, newName: String)
        case merged(fromRoleKey: String, toRoleKey: String, unifiedName: String, updatedCount: Int)
        case unchanged
    }

    private let lock = NSLock()

    public init() {}

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

    /// 执行重命名或合并判定
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
