import Foundation
#if canImport(StudyMatePackage)
import StudyMatePackage
#endif

public struct SentenceLibraryDescriptor: Identifiable, Codable, Equatable, Hashable, Sendable {
    public static let formatIdentifier = "com.studymate.sentence-library"
    public static let currentFormatVersion = 4

    public let format: String
    public let version: Int
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var updatedAt: Date
    public var sourceLanguage: String?
    public var targetLanguage: String?
    public var videoAspectRatio: String?
    public var speakerNames: [String: String]?
    public var session: StudyMatePackageSessionState?

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sourceLanguage: String? = nil,
        targetLanguage: String? = nil,
        videoAspectRatio: String? = nil,
        speakerNames: [String: String]? = nil,
        session: StudyMatePackageSessionState? = nil
    ) {
        self.format = Self.formatIdentifier
        self.version = Self.currentFormatVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.videoAspectRatio = videoAspectRatio
        self.speakerNames = speakerNames
        self.session = session
    }

    /// 默认句库由应用自动创建并始终保留，不能被用户删除。
    /// 旧版本可能使用相同的中文名称，英文名称也一并识别以避免迁移后误删。
    public var isDefault: Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "默认句库" || normalized == "default library"
    }

    private enum CodingKeys: String, CodingKey {
        case format, version, id, name, createdAt, updatedAt
        case sourceLanguage, targetLanguage, videoAspectRatio, speakerNames, session
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.format = (try? container.decode(String.self, forKey: .format)) ?? Self.formatIdentifier
        self.version = (try? container.decode(Int.self, forKey: .version)) ?? Self.currentFormatVersion
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        self.updatedAt = (try? container.decode(Date.self, forKey: .updatedAt)) ?? self.createdAt
        self.sourceLanguage = try? container.decodeIfPresent(String.self, forKey: .sourceLanguage)
        self.targetLanguage = try? container.decodeIfPresent(String.self, forKey: .targetLanguage)
        self.videoAspectRatio = try? container.decodeIfPresent(String.self, forKey: .videoAspectRatio)
        self.speakerNames = try? container.decodeIfPresent([String: String].self, forKey: .speakerNames)
        self.session = try? container.decodeIfPresent(StudyMatePackageSessionState.self, forKey: .session)
    }
}

public struct SentenceLibraryEntry: Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var originalIndex: Int
    public var originalText: String
    public var translation: String
    public var phoneticText: String?
    public var note: String
    public var isBookmarked: Bool
    public var tags: [String]
    public var associatedWords: [StudyMatePackageVocabularyCard]?
    public var contextBefore: String?
    public var contextAfter: String?
    public var sourceMediaName: String
    public var sourceMediaPath: String
    public var startTime: Double
    public var endTime: Double
    public let createdAt: Date
    public var mediaFilename: String
    public var previewFilename: String?
    public var speakerRole: String?
    public var speakerID: Int?
    public var speakerIDs: [Int]
    public var isSpeakerOverlap: Bool
    public var wordTokens: [StudyMatePackageWordToken]?
    public var shadowing: StudyMatePackageShadowingReference?

    public init(
        id: UUID = UUID(),
        originalIndex: Int = 0,
        originalText: String,
        translation: String,
        phoneticText: String? = nil,
        note: String = "",
        isBookmarked: Bool = false,
        tags: [String] = [],
        associatedWords: [StudyMatePackageVocabularyCard]? = nil,
        contextBefore: String? = nil,
        contextAfter: String? = nil,
        sourceMediaName: String,
        sourceMediaPath: String,
        startTime: Double,
        endTime: Double,
        createdAt: Date = Date(),
        mediaFilename: String,
        previewFilename: String? = nil,
        speakerRole: String? = nil,
        speakerID: Int? = nil,
        speakerIDs: [Int] = [],
        isSpeakerOverlap: Bool = false,
        wordTokens: [StudyMatePackageWordToken]? = nil,
        shadowing: StudyMatePackageShadowingReference? = nil
    ) {
        self.id = id
        self.originalIndex = originalIndex
        self.originalText = originalText
        self.translation = translation
        self.phoneticText = phoneticText
        self.note = note
        self.isBookmarked = isBookmarked
        self.tags = tags
        self.associatedWords = associatedWords
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.sourceMediaName = sourceMediaName
        self.sourceMediaPath = sourceMediaPath
        self.startTime = startTime
        self.endTime = endTime
        self.createdAt = createdAt
        self.mediaFilename = mediaFilename
        self.previewFilename = previewFilename
        self.speakerRole = speakerRole
        self.speakerID = speakerID
        self.speakerIDs = speakerIDs
        self.isSpeakerOverlap = isSpeakerOverlap
        self.wordTokens = wordTokens
        self.shadowing = shadowing
    }

    /// 显示用角色标签：如果设置了 speakerRole 则优先使用，否则格式化为 s1, s2
    public var effectiveSpeakerLabel: String {
        if let role = speakerRole, !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return role
        }
        guard !speakerIDs.isEmpty else {
            if let sid = speakerID { return "s\(sid + 1)" }
            return ""
        }
        let labels = speakerIDs.map { "s\($0 + 1)" }
        if isSpeakerOverlap {
            return labels.joined(separator: "+")
        }
        if labels.count > 1 {
            return labels.joined(separator: "→")
        }
        return labels[0]
    }
}

public struct SentenceLibraryOperationProgress: Sendable, Equatable {
    public let fraction: Double
    public let phase: String
    public let currentItem: String

    public init(fraction: Double, phase: String, currentItem: String = "") {
        self.fraction = min(1, max(0, fraction.isFinite ? fraction : 0))
        self.phase = phase
        self.currentItem = currentItem
    }
}

public enum SentenceLibraryTypeFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case bookmarkedOnly
    case withVocabularyOnly

    public var id: String { rawValue }

    public func localized(with lang: LanguageManager = .shared) -> String {
        switch self {
        case .all: return lang.text("全部句子", "All Sentences")
        case .bookmarkedOnly: return lang.text("星标难句", "Starred")
        case .withVocabularyOnly: return lang.text("含生词", "Vocabulary")
        }
    }
}

public enum SentenceLibraryDateFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case today
    case lastSevenDays
    case lastThirtyDays
    case specificDay

    public var id: String { rawValue }

    public func lowerBound(
        now: Date = Date(),
        selectedDate: Date? = nil,
        calendar: Calendar = .current
    ) -> Date? {
        switch self {
        case .all:
            return nil
        case .today:
            return calendar.startOfDay(for: now)
        case .lastSevenDays:
            let today = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: -6, to: today)
        case .lastThirtyDays:
            let today = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: -29, to: today)
        case .specificDay:
            return calendar.startOfDay(for: selectedDate ?? now)
        }
    }

    public func upperBound(
        now: Date = Date(),
        selectedDate: Date? = nil,
        calendar: Calendar = .current
    ) -> Date? {
        switch self {
        case .today:
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        case .specificDay:
            let start = calendar.startOfDay(for: selectedDate ?? now)
            return calendar.date(byAdding: .day, value: 1, to: start)
        case .all, .lastSevenDays, .lastThirtyDays:
            return nil
        }
    }
}

/// 句库列表的入库时间排序方式。
public enum SentenceLibrarySortOrder: String, CaseIterable, Identifiable, Sendable {
    case newestFirst
    case oldestFirst
    case originalIndexFirst

    public var id: String { rawValue }

    public func localized(with lang: LanguageManager = .shared) -> String {
        switch self {
        case .newestFirst: return lang.text("最新入库", "Newest First")
        case .oldestFirst: return lang.text("最早入库", "Oldest First")
        case .originalIndexFirst: return lang.text("原片时序", "Original Order")
        }
    }
}

/// 句库试听播放模式。
public enum SentenceLibraryPlaybackMode: String, CaseIterable, Identifiable, Sendable {
    case single
    case singleLoop
    case allLoop

    public var id: String { rawValue }

    public var chineseName: String {
        switch self {
        case .single: return "单句播放"
        case .singleLoop: return "单句循环"
        case .allLoop: return "全篇循环"
        }
    }

    public var englishName: String {
        switch self {
        case .single: return "Play Sentence"
        case .singleLoop: return "Loop Sentence"
        case .allLoop: return "Loop All"
        }
    }
}
