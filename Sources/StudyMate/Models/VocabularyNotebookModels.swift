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

/// 生词本导出纯文本格式化工具。
/// 将生词记录导出为纯文本文件（.txt），每条记录占一行：
/// 单词\t原文例句\t译文例句\t来源
public enum VocabularyExportFormatter {
    /// 清理字段中的换行和制表符，避免破坏 TSV 单行结构
    public static func sanitizeField(_ text: String) -> String {
        text.components(separatedBy: CharacterSet.newlines)
            .joined(separator: " ")
            .components(separatedBy: "\t")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 解析例句字段。在生词入库时，若包含译文，通常以换行符分隔（第一行为原文例句，后续为译文例句）
    public static func parseExampleSentence(_ text: String) -> (original: String, translation: String) {
        let lines = text
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if lines.isEmpty {
            return ("", "")
        } else if lines.count == 1 {
            return (sanitizeField(lines[0]), "")
        } else {
            let orig = sanitizeField(lines[0])
            let trans = sanitizeField(lines.dropFirst().joined(separator: " "))
            return (orig, trans)
        }
    }

    /// 将一条生词记录格式化为一行：单词\t原文例句\t译文例句\t来源
    public static func formatRecord(
        entry: VocabularyWordEntry,
        source: String? = nil
    ) -> String {
        let word = sanitizeField(entry.word)
        let (originalExample, translatedExample) = parseExampleSentence(entry.exampleSentence)
        let sourceField = sanitizeField(source ?? entry.source)
        return "\(word)\t\(originalExample)\t\(translatedExample)\t\(sourceField)"
    }

    /// 将多条生词记录格式化为纯文本内容，每条记录占一行
    public static func formatPlainText(
        entries: [VocabularyWordEntry],
        sourceResolver: ((String) -> String)? = nil
    ) -> String {
        entries.map { entry in
            formatRecord(entry: entry, source: sourceResolver?(entry.source))
        }.joined(separator: "\n")
    }
}

