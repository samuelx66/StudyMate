import Foundation

public struct VocabularyNotebookDescriptor: Identifiable, Codable, Equatable, Hashable, Sendable {
    public static let formatIdentifier = "com.studymate.vocabulary-notebook"
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

    /// 默认生词本由应用自动创建并始终保留，不能被用户删除。
    public var isDefault: Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "默认生词本" || normalized == "default vocabulary"
    }
}

public struct VocabularyWordEntry: Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let word: String
    public let addedAt: Date
    public let exampleSentence: String
    public let source: String

    public init(
        id: UUID = UUID(),
        word: String,
        addedAt: Date = Date(),
        exampleSentence: String = "",
        source: String = ""
    ) {
        self.id = id
        self.word = word
        self.addedAt = addedAt
        self.exampleSentence = exampleSentence
        self.source = source
    }
}
