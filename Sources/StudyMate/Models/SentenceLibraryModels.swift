import Foundation

public struct SentenceLibraryDescriptor: Identifiable, Codable, Equatable, Hashable, Sendable {
    public static let formatIdentifier = "com.studymate.sentence-library"
    public static let currentFormatVersion = 3

    public let format: String
    public let version: Int
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.format = Self.formatIdentifier
        self.version = Self.currentFormatVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 默认句库由应用自动创建并始终保留，不能被用户删除。
    /// 旧版本可能使用相同的中文名称，英文名称也一并识别以避免迁移后误删。
    public var isDefault: Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "默认句库" || normalized == "default library"
    }
}

public struct SentenceLibraryEntry: Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let originalText: String
    public let translation: String
    public let note: String
    public let sourceMediaName: String
    public let sourceMediaPath: String
    public let startTime: Double
    public let endTime: Double
    public let createdAt: Date
    public let previewFilename: String?
    /// 句库包内 `Media/` 目录中的独立 AAC M4A 片段文件名。
    public let mediaFilename: String

    public init(
        id: UUID = UUID(),
        originalText: String,
        translation: String,
        note: String = "",
        sourceMediaName: String,
        sourceMediaPath: String,
        startTime: Double,
        endTime: Double,
        createdAt: Date = Date(),
        mediaFilename: String,
        previewFilename: String? = nil
    ) {
        self.id = id
        self.originalText = originalText
        self.translation = translation
        self.note = note
        self.sourceMediaName = sourceMediaName
        self.sourceMediaPath = sourceMediaPath
        self.startTime = startTime
        self.endTime = endTime
        self.createdAt = createdAt
        self.previewFilename = previewFilename
        self.mediaFilename = mediaFilename
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
            return calendar.date(byAdding: .day, value: -7, to: now)
        case .lastThirtyDays:
            return calendar.date(byAdding: .day, value: -30, to: now)
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

/// 句库列表的入库时间排序方式。句子编号由当前排序后的列表位置派生，
/// 因此删除任意句子后不会留下断号，也不会把编号写死在句库数据里。
public enum SentenceLibrarySortOrder: String, CaseIterable, Identifiable, Sendable {
    case newestFirst
    case oldestFirst

    public var id: String { rawValue }
}

/// 句库试听播放模式。普通单句播放保留现有行为，另外提供单句循环和
/// 当前筛选结果的全篇循环。
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
