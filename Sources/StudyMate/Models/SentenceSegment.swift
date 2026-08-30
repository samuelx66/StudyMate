import Foundation

/// 单个断句模型
public struct SentenceSegment: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var index: Int
    public var startTime: Double // 秒 (精确到毫秒)
    public var endTime: Double   // 秒 (精确到毫秒)
    public var text: String
    public var translation: String
    public var note: String
    /// 独立于“难句收藏”星标的列表导航书签。
    /// 该标记只用于在“显示 > 书签”中快速定位句子。
    public var isNavigationBookmarked: Bool
    public var isBookmarked: Bool
    /// Speaker labels that participate in this sentence. The list may contain
    /// multiple speakers who took turns; `isSpeakerOverlap` is reserved for
    /// speakers that were active at the same time.
    public var speakerID: Int?
    public var speakerIDs: [Int]
    public var isSpeakerOverlap: Bool
    
    public init(
        id: UUID = UUID(),
        index: Int,
        startTime: Double,
        endTime: Double,
        text: String = "",
        translation: String = "",
        note: String = "",
        isNavigationBookmarked: Bool = false,
        isBookmarked: Bool = false,
        speakerID: Int? = nil,
        speakerIDs: [Int] = [],
        isSpeakerOverlap: Bool = false
    ) {
        let safeStart = startTime.isFinite ? max(0, startTime) : 0
        let safeEnd = endTime.isFinite ? endTime : safeStart + 0.05
        self.id = id
        self.index = index
        self.startTime = safeStart
        self.endTime = max(safeStart + 0.05, safeEnd)
        self.text = text
        self.translation = translation
        self.note = note
        self.isNavigationBookmarked = isNavigationBookmarked
        self.isBookmarked = isBookmarked
        var normalizedSpeakerIDs = Set(speakerIDs)
        if let speakerID { normalizedSpeakerIDs.insert(speakerID) }
        self.speakerIDs = normalizedSpeakerIDs.sorted()
        self.speakerID = speakerID ?? (self.speakerIDs.count == 1 ? self.speakerIDs[0] : nil)
        // Do not infer overlap from the number of labels. A sentence can span
        // a turn boundary without containing simultaneous speech.
        self.isSpeakerOverlap = isSpeakerOverlap
    }

    private enum CodingKeys: String, CodingKey {
        case id, index, startTime, endTime, text, translation, note, isNavigationBookmarked, isBookmarked,
             speakerID, speakerIDs, isSpeakerOverlap
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let resolvedID: UUID
        if let directUUID = try? container.decodeIfPresent(UUID.self, forKey: .id) {
            resolvedID = directUUID
        } else if let stringID = try? container.decodeIfPresent(String.self, forKey: .id),
                  let parsed = UUID(uuidString: stringID) {
            resolvedID = parsed
        } else {
            resolvedID = UUID()
        }
        self.init(
            id: resolvedID,
            index: (try? container.decodeIfPresent(Int.self, forKey: .index)) ?? 0,
            startTime: (try? container.decodeIfPresent(Double.self, forKey: .startTime)) ?? 0,
            endTime: (try? container.decodeIfPresent(Double.self, forKey: .endTime)) ?? 0.05,
            text: (try? container.decodeIfPresent(String.self, forKey: .text)) ?? "",
            translation: (try? container.decodeIfPresent(String.self, forKey: .translation)) ?? "",
            note: (try? container.decodeIfPresent(String.self, forKey: .note)) ?? "",
            isNavigationBookmarked: (try? container.decodeIfPresent(Bool.self, forKey: .isNavigationBookmarked)) ?? false,
            isBookmarked: (try? container.decodeIfPresent(Bool.self, forKey: .isBookmarked)) ?? false,
            speakerID: try? container.decodeIfPresent(Int.self, forKey: .speakerID),
            speakerIDs: (try? container.decodeIfPresent([Int].self, forKey: .speakerIDs)) ?? [],
            isSpeakerOverlap: (try? container.decodeIfPresent(Bool.self, forKey: .isSpeakerOverlap)) ?? false
        )
    }
    
    public var duration: Double {
        max(0, endTime - startTime)
    }
    
    public func contains(time: Double) -> Bool {
        time >= startTime && time < endTime
    }
    
    public var formattedStartTime: String {
        SentenceSegment.formatTimecode(startTime)
    }
    
    public var formattedEndTime: String {
        SentenceSegment.formatTimecode(endTime)
    }
    
    public var formattedDuration: String {
        String(format: "%.2fs", duration)
    }
    
    public static func formatTimecode(_ seconds: Double) -> String {
        guard !seconds.isNaN && seconds.isFinite && seconds >= 0 else {
            return "00:00.000"
        }
        let roundedMilliseconds = Int((seconds * 1000).rounded())
        let totalMs = roundedMilliseconds % 1000
        let totalSecs = roundedMilliseconds / 1000
        let mins = (totalSecs / 60) % 60
        let hours = totalSecs / 3600
        let secs = totalSecs % 60

        let msStr: String
        if totalMs < 10 {
            msStr = "00\(totalMs)"
        } else if totalMs < 100 {
            msStr = "0\(totalMs)"
        } else {
            msStr = "\(totalMs)"
        }

        let secStr = secs < 10 ? "0\(secs)" : "\(secs)"
        let minStr = mins < 10 ? "0\(mins)" : "\(mins)"

        if hours > 0 {
            let hourStr = hours < 10 ? "0\(hours)" : "\(hours)"
            return "\(hourStr):\(minStr):\(secStr).\(msStr)"
        } else {
            return "\(minStr):\(secStr).\(msStr)"
        }
    }
}
