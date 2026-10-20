import Foundation

/// O(n) index for the "same speaker" count displayed on sentence rows.
///
/// Both the sentence-list and list-mode rows used to run
/// `segments.filter { ... }.count` inside every row body, with two string
/// replacements per comparison (O(n²) for long transcripts). The index keeps
/// the exact same predicate: a candidate matches when its normalized speaker
/// label equals the target label **or** its raw `speakerRole` equals the
/// target label.
struct SpeakerCountIndex {
    private var byLabel: [String: Int] = [:]
    private var byRole: [String: Int] = [:]
    private var byBoth: [String: Int] = [:]

    init(segments: [SentenceSegment]) {
        for segment in segments {
            let normalized = Self.normalize(segment.speakerRoleLabel)
            let role = segment.speakerRoleLabel
            byLabel[normalized, default: 0] += 1
            byRole[role, default: 0] += 1
            byBoth[Self.bothKey(normalized, role), default: 0] += 1
        }
    }

    func count(for segment: SentenceSegment) -> Int {
        let normalized = Self.normalize(segment.speakerRoleLabel)
        let role = segment.speakerRoleLabel
        return (byLabel[normalized] ?? 0)
            + (byRole[role] ?? 0)
            - (byBoth[Self.bothKey(normalized, role)] ?? 0)
    }

    private static func normalize(_ value: String) -> String {
        value.replacingOccurrences(of: "→", with: "->")
    }

    private static func bothKey(_ normalized: String, _ role: String) -> String {
        normalized + "\u{1F}" + role
    }
}
