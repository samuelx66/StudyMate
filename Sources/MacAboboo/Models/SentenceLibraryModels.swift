import Foundation

public struct SentenceLibraryDescriptor: Identifiable, Codable, Equatable, Hashable, Sendable {
    public static let formatIdentifier = "com.macaboboo.sentence-library"
    public static let currentFormatVersion = 1

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
    }
}

public enum SentenceLibraryDateFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case today
    case lastSevenDays
    case lastThirtyDays

    public var id: String { rawValue }

    public func lowerBound(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .all:
            return nil
        case .today:
            return calendar.startOfDay(for: now)
        case .lastSevenDays:
            return calendar.date(byAdding: .day, value: -7, to: now)
        case .lastThirtyDays:
            return calendar.date(byAdding: .day, value: -30, to: now)
        }
    }
}
