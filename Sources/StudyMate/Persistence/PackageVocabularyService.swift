import Foundation
import NaturalLanguage
#if canImport(StudyMatePackage)
import StudyMatePackage
#endif

/// 句库与生词本的双向联动服务：
/// 1. 入库时自动比对本地生词本，捕获关联生词并封装离线词汇卡；
/// 2. 学习时提供单词命中检测与靶向挖空优先判定。
public final class PackageVocabularyService: @unchecked Sendable {
    public static let shared = PackageVocabularyService()

    private let notebookStore: VocabularyNotebookStore
    private let queue = DispatchQueue(label: "com.studymate.package.vocabulary-service", qos: .utility)

    public init(notebookStore: VocabularyNotebookStore = .shared) {
        self.notebookStore = notebookStore
    }

    /// 获取本地所有生词词汇集合（小写化，用于快速精准匹配）
    public func allKnownVocabularyWords() -> [String: VocabularyWordEntry] {
        queue.sync {
            let notebooks = notebookStore.listNotebooks()
            var wordsMap: [String: VocabularyWordEntry] = [:]
            for nb in notebooks {
                if let entries = try? notebookStore.entries(notebookID: nb.id) {
                    for entry in entries {
                        let lower = entry.word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        if !lower.isEmpty && wordsMap[lower] == nil {
                            wordsMap[lower] = entry
                        }
                    }
                }
            }
            return wordsMap
        }
    }

    /// 针对单句文本进行生词比对，返回该句包含的全部生词卡片
    public func findMatchingVocabulary(for sentenceText: String) -> [StudyMatePackageVocabularyCard] {
        matchVocabulary(in: sentenceText)
    }

    public func matchVocabulary(in sentenceText: String) -> [StudyMatePackageVocabularyCard] {
        let trimmed = sentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let knownWords = allKnownVocabularyWords()
        guard !knownWords.isEmpty else { return [] }

        let tagger = NLTagger(tagSchemes: [.tokenType])
        tagger.string = trimmed

        var matchedCards: [StudyMatePackageVocabularyCard] = []
        var seenWords: Set<String> = []

        tagger.enumerateTags(in: trimmed.startIndex..<trimmed.endIndex, unit: .word, scheme: .tokenType) { _, tokenRange in
            let rawWord = String(trimmed[tokenRange])
            let lower = rawWord.lowercased()

            // 1. 直接匹配原型
            if let entry = knownWords[lower], !seenWords.contains(lower) {
                seenWords.insert(lower)
                let definition = extractShortDefinition(from: entry.exampleSentence)
                matchedCards.append(StudyMatePackageVocabularyCard(
                    word: rawWord,
                    phonetic: nil,
                    definition: definition.isEmpty ? nil : definition,
                    isInNotebook: true
                ))
            } else if let lemma = StudyMateLemmatizer.lemma(for: rawWord),
                      let entry = knownWords[lemma.lowercased()],
                      !seenWords.contains(lemma.lowercased()) {
                // 2. 词形还原匹配 (例如 running -> run)
                seenWords.insert(lemma.lowercased())
                let definition = extractShortDefinition(from: entry.exampleSentence)
                matchedCards.append(StudyMatePackageVocabularyCard(
                    word: rawWord,
                    phonetic: nil,
                    definition: definition.isEmpty ? nil : definition,
                    isInNotebook: true
                ))
            }
            return true
        }

        return matchedCards
    }

    /// 从例句字段中提取简短释义或例句译文作为词义描述
    private func extractShortDefinition(from exampleSentence: String) -> String {
        let parsed = VocabularyExportFormatter.parseExampleSentence(exampleSentence)
        return parsed.translation.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
