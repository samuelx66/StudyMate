import AppKit
import XCTest
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
}
