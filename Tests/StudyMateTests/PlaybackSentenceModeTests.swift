import AppKit
import XCTest
import StudyMatePackage
@testable import StudyMateKit

final class PlaybackSentenceModeTests: XCTestCase {
    func testPlaybackInterfaceModeProperties() {
        let mode = PlaybackInterfaceMode.sentence
        XCTAssertEqual(mode.id, "sentence")
        XCTAssertEqual(mode.iconName, "text.quote")
        XCTAssertFalse(mode.localized().isEmpty)
    }

    @MainActor
    func testSentenceModeSegmentResolution() {
        let engine = PlaybackEngine()

        // 1. 无断句时返回空
        XCTAssertTrue(engine.segments.isEmpty)
        XCTAssertNil(engine.activeSegmentIndex)

        // 2. 注入测试句子
        let s1 = SentenceSegment(
            index: 1,
            startTime: 0.0,
            endTime: 3.5,
            text: "Hello world",
            translation: "你好，世界"
        )
        let s2 = SentenceSegment(
            index: 2,
            startTime: 3.5,
            endTime: 7.0,
            text: "This is sentence mode.",
            translation: "这是句子模式。"
        )
        engine.segments = [s1, s2]

        // 尚未开始播放时应默认选第 1 句
        let defaultSeg: SentenceSegment? = {
            if let index = engine.activeSegmentIndex,
               engine.segments.indices.contains(index) {
                return engine.segments[index]
            }
            return engine.segments.first
        }()
        XCTAssertEqual(defaultSeg?.id, s1.id)
        XCTAssertEqual(defaultSeg?.index, 1)

        // 播放推进到第 2 句（下标 1）时，准确定位到第 2 句
        engine.activeSegmentIndex = 1
        let activeSeg: SentenceSegment? = {
            if let index = engine.activeSegmentIndex,
               engine.segments.indices.contains(index) {
                return engine.segments[index]
            }
            return engine.segments.first
        }()
        XCTAssertEqual(activeSeg?.id, s2.id)
        XCTAssertEqual(activeSeg?.index, 2)
        XCTAssertEqual(activeSeg?.text, "This is sentence mode.")
        XCTAssertEqual(activeSeg?.translation, "这是句子模式。")
    }

    func testSentenceModeDisplayFields() {
        let seg = SentenceSegment(
            index: 54,
            startTime: 100.0,
            endTime: 105.0,
            text: "It's an album of pictures of the United States, the cities, the special places, and the people.",
            translation: "这是一本关于美国的相册、城市、特殊地点和人物。"
        )

        let orig = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trans = seg.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        let indexLabel = "#\(seg.index)"
        let inlineDisplay = "\(indexLabel) \(orig)"

        XCTAssertEqual(indexLabel, "#54")
        XCTAssertTrue(inlineDisplay.starts(with: "#54 "))
        XCTAssertTrue(inlineDisplay.contains("It's an album"))
        XCTAssertFalse(orig.isEmpty)
        XCTAssertFalse(trans.isEmpty)

        // 双语模式上下文例句正确拼合，支持划词查词
        let context = [orig, trans].filter { !$0.isEmpty }.joined(separator: "\n")
        XCTAssertTrue(context.contains("United States"))
        XCTAssertTrue(context.contains("相册"))
    }

    @MainActor
    func testModesHaveIndependentFontSettings() {
        let settings = VideoSubtitleSettings.shared

        // 记录初始状态
        let originalVideoSize = settings.fontSettings(for: .video).originalFontSize
        let originalListSize = settings.fontSettings(for: .list).originalFontSize
        let originalSentenceSize = settings.fontSettings(for: .sentence).originalFontSize
        let originalFullTextSize = settings.fontSettings(for: .fullText).originalFontSize

        // 仅修改 sentence 模式的原文字号
        settings.updateFontSettings(for: .sentence) {
            $0.originalFontSize = 42.0
            $0.originalBold = true
            $0.originalColorHex = "#FF00AA"
        }

        // 验证 sentence 模式生效
        let sentenceSettings = settings.fontSettings(for: .sentence)
        XCTAssertEqual(sentenceSettings.originalFontSize, 42.0)
        XCTAssertEqual(sentenceSettings.originalColorHex, "#FF00AA")
        XCTAssertEqual(settings.makeOriginalFont(for: .sentence).pointSize, 42.0)

        // 验证其他 3 种模式完全不受任何影响
        XCTAssertEqual(settings.fontSettings(for: .video).originalFontSize, originalVideoSize)
        XCTAssertEqual(settings.fontSettings(for: .list).originalFontSize, originalListSize)
        XCTAssertEqual(settings.fontSettings(for: .fullText).originalFontSize, originalFullTextSize)

        // 仅修改 list 模式的译文字号
        settings.updateFontSettings(for: .list) {
            $0.translationFontSize = 18.0
            $0.translationColorHex = "#123456"
        }
        XCTAssertEqual(settings.fontSettings(for: .list).translationFontSize, 18.0)
        XCTAssertEqual(settings.fontSettings(for: .list).translationColorHex, "#123456")
        XCTAssertEqual(settings.fontSettings(for: .sentence).originalFontSize, 42.0)
        XCTAssertEqual(settings.fontSettings(for: .video).originalFontSize, originalVideoSize)

        // 还原修改
        settings.updateFontSettings(for: .sentence) {
            $0.originalFontSize = originalSentenceSize
        }
        settings.updateFontSettings(for: .list) {
            $0.translationFontSize = originalListSize
        }
    }

    @MainActor
    func testModeFontSettingsDefaults() {
        let settings = VideoSubtitleSettings.shared

        // 各模式字号设计规范校验
        let video = settings.fontSettings(for: .video)
        let list = settings.fontSettings(for: .list)
        let sentence = settings.fontSettings(for: .sentence)
        let fullText = settings.fontSettings(for: .fullText)

        XCTAssertGreaterThan(video.originalFontSize, list.originalFontSize)
        XCTAssertGreaterThan(sentence.originalFontSize, list.originalFontSize)
        XCTAssertGreaterThan(fullText.originalFontSize, list.originalFontSize)

        // 列表模式适合紧凑排版，默认字号在 12~16pt 之间
        XCTAssertTrue((12.0...16.0).contains(list.originalFontSize))
        XCTAssertTrue((11.0...15.0).contains(list.translationFontSize))

        // 句子模式适合专注精读，默认字号在 20~28pt 之间
        XCTAssertTrue((20.0...28.0).contains(sentence.originalFontSize))
    }

    func testDictionaryPopoverChoosesVisibleDirection() {
        let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let size = NSSize(width: 420, height: 560)

        XCTAssertEqual(
            DictionaryPopoverPlacement.direction(
                for: NSRect(x: 500, y: 30, width: 80, height: 24),
                in: screen,
                contentSize: size
            ),
            .above
        )
        XCTAssertEqual(
            DictionaryPopoverPlacement.direction(
                for: NSRect(x: 500, y: 846, width: 80, height: 24),
                in: screen,
                contentSize: size
            ),
            .below
        )

        let shortScreen = NSRect(x: 0, y: 0, width: 1_440, height: 500)
        XCTAssertEqual(
            DictionaryPopoverPlacement.direction(
                for: NSRect(x: 520, y: 238, width: 80, height: 24),
                in: shortScreen,
                contentSize: size
            ),
            .right
        )
        XCTAssertEqual(
            DictionaryPopoverPlacement.direction(
                for: NSRect(x: 1_330, y: 238, width: 80, height: 24),
                in: shortScreen,
                contentSize: size
            ),
            .left
        )
    }

    @MainActor
    func testNormalizedSegmentsPreservesWordTokensAndMetadata() {
        let engine = PlaybackEngine()
        let tokens = [
            StudyMatePackageWordToken(text: "from", startTime: 0.1, endTime: 0.4),
            StudyMatePackageWordToken(text: "New", startTime: 0.5, endTime: 0.8),
            StudyMatePackageWordToken(text: "York?", startTime: 0.9, endTime: 1.3)
        ]
        let vocab = [
            StudyMatePackageVocabularyCard(word: "York", phonetic: "/jɔːrk/", definition: "城市名")
        ]
        let seg = SentenceSegment(
            index: 1,
            originalIndex: 10,
            startTime: 5.0,
            endTime: 8.0,
            text: "from New York?",
            translation: "来自纽约吗？",
            note: "考点",
            isNavigationBookmarked: true,
            isBookmarked: true,
            speakerID: 2,
            speakerIDs: [2],
            isSpeakerOverlap: false,
            speakerRole: "Jim",
            phoneticText: "frʌm njuː jɔːrk?",
            associatedWords: vocab,
            wordTokens: tokens,
            contextBefore: "Are you",
            contextAfter: "Yes, I am."
        )

        // 通过 replaceSegmentsForUndo 调用 normalizedSegments
        engine.replaceSegmentsForUndo([seg])

        XCTAssertEqual(engine.segments.count, 1)
        guard let normalized = engine.segments.first else {
            XCTFail("Segment should exist")
            return
        }

        XCTAssertEqual(normalized.originalIndex, 10)
        XCTAssertEqual(normalized.speakerRole, "Jim")
        XCTAssertEqual(normalized.phoneticText, "frʌm njuː jɔːrk?")
        XCTAssertEqual(normalized.associatedWords?.count, 1)
        XCTAssertEqual(normalized.associatedWords?.first?.word, "York")
        XCTAssertEqual(normalized.wordTokens?.count, 3)
        XCTAssertEqual(normalized.wordTokens?[0].text, "from")
        XCTAssertEqual(normalized.wordTokens?[1].text, "New")
        XCTAssertEqual(normalized.wordTokens?[2].text, "York?")
        XCTAssertEqual(normalized.contextBefore, "Are you")
        XCTAssertEqual(normalized.contextAfter, "Yes, I am.")
    }

    @MainActor
    func testSplitAndMergeSegmentsPreservesWordTokens() {
        let engine = PlaybackEngine()
        let tokens = [
            StudyMatePackageWordToken(text: "Good", startTime: 0.1, endTime: 0.5),
            StudyMatePackageWordToken(text: "morning", startTime: 0.6, endTime: 1.2),
            StudyMatePackageWordToken(text: "everyone", startTime: 1.5, endTime: 2.2)
        ]
        let initialSeg = SentenceSegment(
            index: 1,
            startTime: 10.0,
            endTime: 13.0,
            text: "Good morning everyone",
            translation: "大家早上好",
            speakerRole: "Alice",
            wordTokens: tokens
        )
        engine.segments = [initialSeg]
        engine.activeSegmentIndex = 0

        // 1. 在 11.4 秒处切分 (offset 1.4s: 包含了 Good 和 morning，未包含 everyone)
        engine.splitSegment(at: 11.4)
        XCTAssertEqual(engine.segments.count, 2)
        let seg1 = engine.segments[0]
        let seg2 = engine.segments[1]

        XCTAssertEqual(seg1.speakerRole, "Alice")
        XCTAssertEqual(seg2.speakerRole, "Alice")
        XCTAssertEqual(seg1.wordTokens?.count, 2)
        XCTAssertEqual(seg1.wordTokens?[0].text, "Good")
        XCTAssertEqual(seg1.wordTokens?[1].text, "morning")
        XCTAssertEqual(seg2.wordTokens?.count, 1)
        XCTAssertEqual(seg2.wordTokens?[0].text, "everyone")
        XCTAssertEqual(seg2.wordTokens?[0].startTime ?? -1, 1.5 - 1.4, accuracy: 0.01)

        // 2. 重新合并两句
        engine.mergeSegmentWithNext(at: 0)
        XCTAssertEqual(engine.segments.count, 1)
        guard let merged = engine.segments.first else {
            XCTFail("Merged segment missing")
            return
        }
        XCTAssertEqual(merged.speakerRole, "Alice")
        XCTAssertEqual(merged.wordTokens?.count, 3)
        XCTAssertEqual(merged.wordTokens?[0].text, "Good")
        XCTAssertEqual(merged.wordTokens?[1].text, "morning")
        XCTAssertEqual(merged.wordTokens?[2].text, "everyone")
    }

    func testRecognizedOriginalTextsAndTokensSingleSentenceAndTolerance() {
        let target = SentenceSegment(
            index: 1,
            startTime: 5.0,
            endTime: 8.0,
            text: ""
        )
        // 模拟 Whisper 返回了一个略早于 5.0s 的 token (例如 4.95s) 和一个略晚于 8.0s 的 token (例如 8.05s)
        let tokens = [
            SpeechToken(text: "from", startTime: 4.95, endTime: 5.4, confidence: 0.95),
            SpeechToken(text: "New", startTime: 5.5, endTime: 6.2, confidence: 0.98),
            SpeechToken(text: "York?", startTime: 6.3, endTime: 8.05, confidence: 0.92)
        ]

        let result = PlaybackEngine.recognizedOriginalTextsAndTokens(
            for: [target],
            tokens: tokens
        )

        let targetTokens = result.wordTokens[target.id]
        XCTAssertNotNil(targetTokens)
        XCTAssertEqual(targetTokens?.count, 3)
        XCTAssertEqual(targetTokens?[0].text, "from")
        XCTAssertEqual(targetTokens?[0].startTime ?? -1, 0.0, accuracy: 0.001) // 4.95 - 5.0 钳制为 0
        XCTAssertEqual(targetTokens?[1].text, "New")
        XCTAssertEqual(targetTokens?[2].text, "York?")
    }

    func testPlaybackSentenceCardActiveTokenIndexAndEquatability() {
        let tokens = [
            StudyMatePackageWordToken(text: "Good", startTime: 0.1, endTime: 0.5),
            StudyMatePackageWordToken(text: "morning", startTime: 0.6, endTime: 1.2),
            StudyMatePackageWordToken(text: "everyone", startTime: 1.4, endTime: 2.0)
        ]
        let baseTime = 10.0

        // 1. 在段落开始前 (time = 9.8s): 无高亮
        XCTAssertNil(PlaybackSentenceCardView.activeTokenIndex(for: tokens, baseTime: baseTime, time: 9.8))

        // 2. 在第一个词内 (time = 10.3s): 命中第 0 词
        XCTAssertEqual(PlaybackSentenceCardView.activeTokenIndex(for: tokens, baseTime: baseTime, time: 10.3), 0)

        // 3. 在第 0 词与第 1 词之间的短微间隙 (0.5s ~ 0.6s, gap=0.1s, time = 10.55s): 平滑维持第 0 词
        XCTAssertEqual(PlaybackSentenceCardView.activeTokenIndex(for: tokens, baseTime: baseTime, time: 10.55), 0)

        // 4. 进入第 1 词 (time = 10.8s): 命中第 1 词
        XCTAssertEqual(PlaybackSentenceCardView.activeTokenIndex(for: tokens, baseTime: baseTime, time: 10.8), 1)

        // 5. 进入第 2 词 (time = 11.6s): 命中第 2 词
        XCTAssertEqual(PlaybackSentenceCardView.activeTokenIndex(for: tokens, baseTime: baseTime, time: 11.6), 2)

        // 6. 超过最后词的平滑延展期 (time = 12.5s): 恢复无高亮
        XCTAssertNil(PlaybackSentenceCardView.activeTokenIndex(for: tokens, baseTime: baseTime, time: 12.5))

        // 7. 测试 PlaybackSentenceCardView.== 防抖与高亮触发:
        let seg = SentenceSegment(
            index: 1,
            startTime: baseTime,
            endTime: 13.0,
            text: "Good morning everyone",
            wordTokens: tokens
        )
        let font = NSFont.systemFont(ofSize: 14)
        let color = NSColor.textColor

        let card1 = PlaybackSentenceCardView(
            seg: seg,
            currentTime: 10.2, // word 0
            showOriginal: true,
            showTranslation: false,
            showPhonetics: false,
            originalFont: font,
            originalColor: color,
            translationFont: font,
            translationColor: color,
            language: .en,
            onToggleBookmark: {},
            onSeekToToken: { _ in },
            onRegenerateTokens: {},
            onRenameSpeaker: nil,
            onSelect: {},
            onDoubleClick: {}
        )
        let card2 = PlaybackSentenceCardView(
            seg: seg,
            currentTime: 10.4, // still word 0
            showOriginal: true,
            showTranslation: false,
            showPhonetics: false,
            originalFont: font,
            originalColor: color,
            translationFont: font,
            translationColor: color,
            language: .en,
            onToggleBookmark: {},
            onSeekToToken: { _ in },
            onRegenerateTokens: {},
            onRenameSpeaker: nil,
            onSelect: {},
            onDoubleClick: {}
        )
        let card3 = PlaybackSentenceCardView(
            seg: seg,
            currentTime: 10.8, // word 1!
            showOriginal: true,
            showTranslation: false,
            showPhonetics: false,
            originalFont: font,
            originalColor: color,
            translationFont: font,
            translationColor: color,
            language: .en,
            onToggleBookmark: {},
            onSeekToToken: { _ in },
            onRegenerateTokens: {},
            onRenameSpeaker: nil,
            onSelect: {},
            onDoubleClick: {}
        )

        // 在同一词内播放时保持相等（防抖，不重绘）
        XCTAssertTrue(card1 == card2)
        // 跨越至新单词时打破相等（立即重绘点亮新单词）
        XCTAssertFalse(card1 == card3)
    }
}
