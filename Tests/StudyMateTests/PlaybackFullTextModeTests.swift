import AppKit
import XCTest
import SwiftUI
@testable import StudyMateKit

final class PlaybackFullTextModeTests: XCTestCase {
    func testParagraphIDsStayStableAcrossRebuilds() {
        let segments = (0..<4).map {
            SentenceSegment(index: $0 + 1, startTime: Double($0), endTime: Double($0 + 1), text: "Sentence", speakerID: $0 % 2, speakerIDs: [$0 % 2])
        }
        XCTAssertEqual(FullTextParagraphBuilder.buildParagraphs(from: segments), FullTextParagraphBuilder.buildParagraphs(from: segments))
        let plain = [SentenceSegment(index: 1, startTime: 0, endTime: 1, text: "Plain")]
        XCTAssertEqual(FullTextParagraphBuilder.buildParagraphs(from: plain).first?.id, plain[0].id)
    }

    @MainActor
    func testFollowingScrollsWithinLongParagraphAndCanBeDisabledAndResumed() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 6000))
        let textView = FullTextFollowingTextView(frame: document.bounds)
        textView.textContainer?.containerSize = NSSize(width: 300, height: 100000)
        textView.textContainer?.widthTracksTextView = true
        textView.font = NSFont.systemFont(ofSize: 16)
        textView.string = String(repeating: "A long article sentence with many words. ", count: 150)
        document.addSubview(textView)
        scrollView.documentView = document
        let target = NSRange(location: 4000, length: 30)
        textView.updateFollowRange(target, contentChanged: true)
        textView.revealFollowedSentence()
        let visible = textView.visibleRect
        let layout = textView.layoutManager!
        let glyphs = layout.glyphRange(forCharacterRange: target, actualCharacterRange: nil)
        let targetRect = layout.boundingRect(forGlyphRange: glyphs, in: textView.textContainer!).offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        XCTAssertTrue(visible.intersects(targetRect))

        textView.updateFollowRange(nil, contentChanged: false)
        scrollView.contentView.scroll(to: .zero)
        let stoppedOrigin = scrollView.contentView.bounds.origin
        textView.revealFollowedSentence()
        XCTAssertEqual(scrollView.contentView.bounds.origin, stoppedOrigin)
        textView.updateFollowRange(target, contentChanged: false)
        textView.revealFollowedSentence()
        XCTAssertTrue(textView.visibleRect.intersects(targetRect))
        XCTAssertNotEqual(scrollView.contentView.bounds.origin, stoppedOrigin)
    }

    @MainActor
    func testFollowingInsideSwiftUIScrollView() async throws {
        let id = UUID()
        let text = String(repeating: "Long article sentence with words. ", count: 180)
        let range = NSRange(location: 4000, length: 25)
        let paragraph = FullTextParagraphTextView(
            text: text, font: NSFont.systemFont(ofSize: 16), color: .labelColor,
            ranges: [(id: id, range: range)], followSegmentID: id,
            contextText: nil, onSelect: nil, onDoubleClick: nil
        )
        let hosting = NSHostingView(rootView: ScrollView { paragraph.frame(maxWidth: .infinity) }.frame(width: 400, height: 240))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(400))
        func findText(_ view: NSView) -> FullTextNSTextView? {
            if let text = view as? FullTextNSTextView { return text }
            return view.subviews.compactMap { findText($0) }.first
        }
        let native = try XCTUnwrap(findText(hosting))
        let layout = try XCTUnwrap(native.layoutManager)
        let container = try XCTUnwrap(native.textContainer)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: native.textContainerOrigin.x, dy: native.textContainerOrigin.y)
        let inWindow = native.convert(rect, to: hosting)
        XCTAssertTrue(hosting.bounds.intersects(inWindow), "Sentence \(inWindow) remains outside viewport \(hosting.bounds); enclosing scroll: \(String(describing: native.enclosingScrollView))")
    }

    @MainActor
    func testCompleteFullTextViewFollowsPlaybackChanges() async throws {
        let engine = PlaybackEngine()
        engine.segments = (0..<180).map { SentenceSegment(index: $0 + 1, startTime: Double($0), endTime: Double($0 + 1), text: "Long article sentence with several words and a number \($0).", translation: "测试译文第\($0)句。") }
        let settings = VideoSubtitleSettings.shared
        let original = settings.showOriginal
        let translation = settings.showTranslation
        settings.showOriginal = true
        settings.showTranslation = false
        defer { settings.showOriginal = original; settings.showTranslation = translation }
        engine.activeSegmentIndex = 0
        let hosting = NSHostingView(rootView: PlaybackFullTextModeView(engine: engine, videoSubtitleSettings: settings).frame(width: 700, height: 400))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        engine.activeSegmentIndex = 130
        try await Task.sleep(for: .milliseconds(400))
        func findText(_ view: NSView) -> FullTextNSTextView? {
            if let text = view as? FullTextNSTextView, text.string.hasPrefix("Long") { return text }
            return view.subviews.compactMap { findText($0) }.first
        }
        let native = try XCTUnwrap(findText(hosting))
        let data = FullTextParagraphBuilder.concatenate(segments: engine.segments, useTranslation: false)
        let range = data.ranges[130].range
        let layout = try XCTUnwrap(native.layoutManager)
        let container = try XCTUnwrap(native.textContainer)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: native.textContainerOrigin.x, dy: native.textContainerOrigin.y)
        let inWindow = native.convert(rect, to: hosting)
        XCTAssertTrue(hosting.bounds.insetBy(dx: 0, dy: 45).intersects(inWindow), "Current sentence \(inWindow) is offscreen")
    }

    func testFullTextModeProperties() {
        let mode = PlaybackInterfaceMode.fullText
        XCTAssertEqual(mode.id, "fullText")
        XCTAssertEqual(mode.iconName, "doc.text")
        XCTAssertFalse(mode.localized().isEmpty)
    }

    func testParagraphBuildingWithoutRoles() {
        let s1 = SentenceSegment(
            index: 1,
            startTime: 0.0,
            endTime: 2.0,
            text: "First sentence.",
            translation: "第一句。"
        )
        let s2 = SentenceSegment(
            index: 2,
            startTime: 2.0,
            endTime: 4.0,
            text: "Second sentence.",
            translation: "第二句。"
        )
        let s3 = SentenceSegment(
            index: 3,
            startTime: 4.0,
            endTime: 6.0,
            text: "Third sentence.",
            translation: "第三句。"
        )

        let paragraphs = FullTextParagraphBuilder.buildParagraphs(from: [s1, s2, s3])
        // 无角色时，不按角色换行，整篇所有断句拼接为一个段落
        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertNil(paragraphs[0].speakerRole)
        XCTAssertEqual(paragraphs[0].segments.count, 3)
    }

    func testParagraphBuildingWithRolesBreaksAtRoleEnd() {
        // s1: 0, s2: 1
        let s1 = SentenceSegment(
            index: 1,
            startTime: 0.0,
            endTime: 2.0,
            text: "Hello from Alice.",
            translation: "爱丽丝打招呼。",
            speakerID: 0,
            speakerIDs: [0]
        )
        let s2 = SentenceSegment(
            index: 2,
            startTime: 2.0,
            endTime: 4.0,
            text: "Alice continuing her story.",
            translation: "爱丽丝继续讲她的故事。",
            speakerID: 0,
            speakerIDs: [0]
        )
        let s3 = SentenceSegment(
            index: 3,
            startTime: 4.0,
            endTime: 6.0,
            text: "Bob answers her.",
            translation: "鲍勃回答她。",
            speakerID: 1,
            speakerIDs: [1]
        )
        let s4 = SentenceSegment(
            index: 4,
            startTime: 6.0,
            endTime: 8.0,
            text: "Alice speaks again.",
            translation: "爱丽丝再次说话。",
            speakerID: 0,
            speakerIDs: [0]
        )

        let paragraphs = FullTextParagraphBuilder.buildParagraphs(from: [s1, s2, s3, s4])
        // s1(2句) -> s2(1句) -> s1(1句) 共 3 个换行段落
        XCTAssertEqual(paragraphs.count, 3)

        XCTAssertEqual(paragraphs[0].speakerRole, "s1")
        XCTAssertEqual(paragraphs[0].segments.map(\.index), [1, 2])

        XCTAssertEqual(paragraphs[1].speakerRole, "s2")
        XCTAssertEqual(paragraphs[1].segments.map(\.index), [3])

        XCTAssertEqual(paragraphs[2].speakerRole, "s1")
        XCTAssertEqual(paragraphs[2].segments.map(\.index), [4])
    }

    func testTextConcatenationAndRangeMapping() {
        let s1 = SentenceSegment(
            index: 1,
            startTime: 0.0,
            endTime: 2.0,
            text: "Good morning.",
            translation: "早上好。"
        )
        let s2 = SentenceSegment(
            index: 2,
            startTime: 2.0,
            endTime: 4.0,
            text: "Nice to meet you.",
            translation: "很高兴认识你。"
        )

        // 原文拼接
        let (origText, origRanges) = FullTextParagraphBuilder.concatenate(
            segments: [s1, s2],
            useTranslation: false
        )
        XCTAssertEqual(origText, "Good morning. Nice to meet you.")
        XCTAssertEqual(origRanges.count, 2)
        XCTAssertEqual(origRanges[0].id, s1.id)
        XCTAssertEqual(origRanges[0].range.location, 0)
        XCTAssertEqual(origRanges[0].range.length, 13) // "Good morning."
        XCTAssertEqual(origRanges[1].id, s2.id)
        XCTAssertEqual(origRanges[1].range.location, 14) // after space
        XCTAssertEqual(origRanges[1].range.length, 17) // "Nice to meet you."

        // 译文拼接
        let (transText, transRanges) = FullTextParagraphBuilder.concatenate(
            segments: [s1, s2],
            useTranslation: true
        )
        XCTAssertEqual(transText, "早上好。很高兴认识你。")
        XCTAssertEqual(transRanges.count, 2)
        XCTAssertEqual(transRanges[0].id, s1.id)
        XCTAssertEqual(transRanges[0].range.location, 0)
        XCTAssertEqual(transRanges[0].range.length, 4) // "早上好。"
        XCTAssertEqual(transRanges[1].id, s2.id)
        XCTAssertEqual(transRanges[1].range.location, 4)
        XCTAssertEqual(transRanges[1].range.length, 7) // "很高兴认识你。"
    }

    func testActiveSentenceUnderlineMatchesFontColor() {
        let s1 = SentenceSegment(
            index: 1,
            startTime: 0.0,
            endTime: 2.0,
            text: "Sentence 1.",
            translation: "句子1。"
        )
        let s2 = SentenceSegment(
            index: 2,
            startTime: 2.0,
            endTime: 4.0,
            text: "Sentence 2 is active.",
            translation: "句子2正在播放。"
        )

        let (text, ranges) = FullTextParagraphBuilder.concatenate(
            segments: [s1, s2],
            useTranslation: false
        )

        let font = NSFont.systemFont(ofSize: 16)
        let targetColor = NSColor.systemYellow

        // 当播放第 2 句时构建富文本
        let attr = FullTextParagraphBuilder.buildAttributedString(
            fullText: text,
            ranges: ranges,
            activeSegmentID: s2.id,
            font: font,
            color: targetColor
        )

        // 验证第 1 句范围无下划线
        var range1 = NSRange()
        let underline1 = attr.attribute(.underlineStyle, at: ranges[0].range.location, effectiveRange: &range1) as? Int
        XCTAssertNil(underline1)

        // 验证第 2 句范围具有下划线，且文字与下划线颜色跟随当前字体颜色
        var range2 = NSRange()
        let underline2 = attr.attribute(.underlineStyle, at: ranges[1].range.location, effectiveRange: &range2) as? Int
        let underlineColor = attr.attribute(.underlineColor, at: ranges[1].range.location, effectiveRange: &range2) as? NSColor

        XCTAssertEqual(underline2, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(underlineColor, NSColor.labelColor)
        XCTAssertEqual(attr.attribute(.foregroundColor, at: ranges[1].range.location, effectiveRange: nil) as? NSColor, NSColor.labelColor)
        XCTAssertEqual(attr.attribute(.foregroundColor, at: ranges[0].range.location, effectiveRange: nil) as? NSColor, targetColor)
    }
}
