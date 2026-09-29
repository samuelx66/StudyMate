import Foundation
#if canImport(StudyMatePackage)
import StudyMatePackage
#endif

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
    public var speakerRole: String?
    public var phoneticText: String?
    public var associatedWords: [StudyMatePackageVocabularyCard]?
    public var wordTokens: [StudyMatePackageWordToken]?
    public var originalIndex: Int?
    public var contextBefore: String?
    public var contextAfter: String?
    public var sourceMediaName: String?
    public var sourceStartTime: Double?
    
    public init(
        id: UUID = UUID(),
        index: Int,
        originalIndex: Int? = nil,
        startTime: Double,
        endTime: Double,
        text: String = "",
        translation: String = "",
        note: String = "",
        isNavigationBookmarked: Bool = false,
        isBookmarked: Bool = false,
        speakerID: Int? = nil,
        speakerIDs: [Int] = [],
        isSpeakerOverlap: Bool = false,
        speakerRole: String? = nil,
        phoneticText: String? = nil,
        associatedWords: [StudyMatePackageVocabularyCard]? = nil,
        wordTokens: [StudyMatePackageWordToken]? = nil,
        contextBefore: String? = nil,
        contextAfter: String? = nil,
        sourceMediaName: String? = nil,
        sourceStartTime: Double? = nil
    ) {
        let safeStart = startTime.isFinite ? max(0, startTime) : 0
        let safeEnd = endTime.isFinite ? endTime : safeStart + 0.05
        self.id = id
        self.index = index
        self.originalIndex = originalIndex
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
        self.isSpeakerOverlap = isSpeakerOverlap
        self.speakerRole = speakerRole
        self.phoneticText = phoneticText
        self.associatedWords = associatedWords
        self.wordTokens = wordTokens
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.sourceMediaName = sourceMediaName
        self.sourceStartTime = sourceStartTime
    }

    private enum CodingKeys: String, CodingKey {
        case id, index, originalIndex, startTime, endTime, text, translation, note, isNavigationBookmarked, isBookmarked,
             speakerID, speakerIDs, isSpeakerOverlap, speakerRole, phoneticText, associatedWords,
             wordTokens, contextBefore, contextAfter, sourceMediaName, sourceStartTime
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
            originalIndex: try? container.decodeIfPresent(Int.self, forKey: .originalIndex),
            startTime: (try? container.decodeIfPresent(Double.self, forKey: .startTime)) ?? 0,
            endTime: (try? container.decodeIfPresent(Double.self, forKey: .endTime)) ?? 0.05,
            text: (try? container.decodeIfPresent(String.self, forKey: .text)) ?? "",
            translation: (try? container.decodeIfPresent(String.self, forKey: .translation)) ?? "",
            note: (try? container.decodeIfPresent(String.self, forKey: .note)) ?? "",
            isNavigationBookmarked: (try? container.decodeIfPresent(Bool.self, forKey: .isNavigationBookmarked)) ?? false,
            isBookmarked: (try? container.decodeIfPresent(Bool.self, forKey: .isBookmarked)) ?? false,
            speakerID: try? container.decodeIfPresent(Int.self, forKey: .speakerID),
            speakerIDs: (try? container.decodeIfPresent([Int].self, forKey: .speakerIDs)) ?? [],
            isSpeakerOverlap: (try? container.decodeIfPresent(Bool.self, forKey: .isSpeakerOverlap)) ?? false,
            speakerRole: try? container.decodeIfPresent(String.self, forKey: .speakerRole),
            phoneticText: try? container.decodeIfPresent(String.self, forKey: .phoneticText),
            associatedWords: try? container.decodeIfPresent([StudyMatePackageVocabularyCard].self, forKey: .associatedWords),
            wordTokens: try? container.decodeIfPresent([StudyMatePackageWordToken].self, forKey: .wordTokens),
            contextBefore: try? container.decodeIfPresent(String.self, forKey: .contextBefore),
            contextAfter: try? container.decodeIfPresent(String.self, forKey: .contextAfter),
            sourceMediaName: try? container.decodeIfPresent(String.self, forKey: .sourceMediaName),
            sourceStartTime: try? container.decodeIfPresent(Double.self, forKey: .sourceStartTime)
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

    /// 角色/说话人标签（优先使用自定义 speakerRole，如 "Jim"；若无则回退到 s1, s2 等；重叠时如 s1+s2，轮替时如 s1→s2；无角色时返回空字符串）
    public var speakerRoleLabel: String {
        if let role = speakerRole, !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return role
        }
        guard !speakerIDs.isEmpty else { return "" }
        let labels = speakerIDs.map { "s\($0 + 1)" }
        if isSpeakerOverlap {
            return labels.joined(separator: "+")
        }
        if labels.count > 1 {
            return labels.joined(separator: "→")
        }
        return labels[0]
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

    /// 将秒数格式化为原片坐标标准时间戳（HH:mm:ss，如 00:15:23）
    public static func formatCoordinateTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && seconds.isFinite && seconds >= 0 else {
            return "00:00:00"
        }
        let totalSecs = Int(seconds.rounded(.down))
        let hours = totalSecs / 3600
        let mins = (totalSecs / 60) % 60
        let secs = totalSecs % 60
        return String(format: "%02d:%02d:%02d", hours, mins, secs)
    }

    /// 原片坐标描述小字，形如：
    /// 来源：阿甘正传.mp4 · #88 (00:15:23)
    public func formattedCoordinate(language: AppLanguage = .zh) -> String? {
        let origIdx = (originalIndex != nil && originalIndex! > 0) ? originalIndex : nil
        let media = sourceMediaName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMedia = media != nil && !media!.isEmpty

        guard hasMedia || origIdx != nil else { return nil }

        let time = sourceStartTime ?? startTime
        let timeStr = SentenceSegment.formatCoordinateTime(time)

        if let media, !media.isEmpty {
            if let idx = origIdx {
                return language == .en
                    ? "Source: \(media) · #\(idx) (\(timeStr))"
                    : "来源：\(media) · 原#\(idx) (\(timeStr))"
            } else {
                return language == .en
                    ? "Source: \(media) (\(timeStr))"
                    : "来源：\(media) (\(timeStr))"
            }
        } else if let idx = origIdx {
            return language == .en
                ? "Orig #\(idx) (\(timeStr))"
                : "原片 #\(idx) (\(timeStr))"
        }
        return nil
    }
}

