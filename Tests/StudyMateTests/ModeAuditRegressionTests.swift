import AppKit
import SwiftUI
import XCTest
@testable import StudyMateKit

@MainActor
final class ModeAuditRegressionTests: XCTestCase {
    private func fields(in view: NSView) -> [WordSlotNSTextField] {
        let found = (view as? WordSlotNSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
        return found.sorted { ($0.identifier?.rawValue ?? "") < ($1.identifier?.rawValue ?? "") }
    }

    private func enter(_ value: String, into field: WordSlotNSTextField) {
        field.currentEditor()?.string = value
        field.stringValue = value
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private func card(_ segment: SentenceSegment, peek: Bool = false, replay: Int = 0,
                      completion: @escaping () -> Void = {}) -> FillInBlankCardView {
        FillInBlankCardView(seg: segment, showOriginal: peek, showTranslation: false,
                            originalFont: .systemFont(ofSize: 20), originalColor: .labelColor,
                            translationFont: .systemFont(ofSize: 18), translationColor: .labelColor,
                            language: .en, replayRevision: replay, onReplayAudio: {}, onSentenceCompleted: completion)
    }

    private func host<V: View>(_ content: V) -> (NSHostingView<V>, NSWindow) {
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        return (hosting, window)
    }

    func testPeekRetainsDraftAndEditedSentenceUsesNewAnswer() async throws {
        var segment = SentenceSegment(index: 1, startTime: 0, endTime: 2, text: "Hello world")
        var completed = 0
        let (hosting, window) = host(card(segment, completion: { completed += 1 }))
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        enter("Hel", into: try XCTUnwrap(fields(in: hosting).first))
        try await Task.sleep(for: .milliseconds(50))
        hosting.rootView = card(segment, peek: true, completion: { completed += 1 })
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(fields(in: hosting).isEmpty)
        hosting.rootView = card(segment, completion: { completed += 1 })
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fields(in: hosting).first?.stringValue, "Hel")
        segment.text = "Goodbye"
        hosting.rootView = card(segment, completion: { completed += 1 })
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fields(in: hosting).count, 1)
        let field = try XCTUnwrap(fields(in: hosting).first)
        XCTAssertEqual(field.stringValue, "")
        enter("Hello", into: field)
        XCTAssertEqual(completed, 0)
        enter("Goodbye", into: field)
        XCTAssertEqual(completed, 1)
        hosting.rootView = card(segment, replay: 1, completion: { completed += 1 })
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(try XCTUnwrap(fields(in: hosting).first).isEditable)
        XCTAssertEqual(fields(in: hosting).first?.stringValue, "")
    }

    func testOrdinaryUpdateDoesNotStealExternalInputFocus() async throws {
        let segment = SentenceSegment(index: 1, startTime: 0, endTime: 2, text: "Hello world")
        let (hosting, window) = host(card(segment))
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        let external = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        hosting.addSubview(external)
        window.makeFirstResponder(external)
        let editor = window.firstResponder
        hosting.rootView = card(segment, replay: 1)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(window.firstResponder === editor)
    }

    func testReplayInvalidatesPendingCompletionInFullModeView() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.mp3")
        try Data("audio".utf8).write(to: url)
        let backend = TestMediaPlayerBackend(duration: 20)
        let engine = PlaybackEngine(nativeBackend: backend, mpvBackend: TestMediaPlayerBackend(duration: 20),
                                    projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects")))
        engine.setDecoderMode(.system)
        engine.loadMedia(from: url)
        try await Task.sleep(for: .milliseconds(50))
        engine.segments = [SentenceSegment(index: 1, startTime: 0, endTime: 5, text: "Hello"),
                           SentenceSegment(index: 2, startTime: 5, endTime: 10, text: "World")]
        engine.activeSegmentIndex = 0
        let settings = VideoSubtitleSettings.shared
        let oldPeek = settings.showOriginalInFillInBlank
        settings.showOriginalInFillInBlank = false
        defer { settings.showOriginalInFillInBlank = oldPeek }
        let (hosting, window) = host(PlaybackFillInBlankModeView(engine: engine, videoSubtitleSettings: settings))
        defer { window.orderOut(nil); engine.pause() }
        try await Task.sleep(for: .milliseconds(150))
        enter("Hello", into: try XCTUnwrap(fields(in: hosting).first))
        try await Task.sleep(for: .milliseconds(100))
        // The toolbar button and global command both call this engine entry point.
        engine.repeatCurrentSegment()
        try await Task.sleep(for: .milliseconds(1150))
        XCTAssertEqual(engine.activeSegmentIndex, 0)
        XCTAssertTrue(try XCTUnwrap(fields(in: hosting).first).isEditable)
    }

    func testBilingualArticleIsLazyAndFollowsOffscreenSentence() async throws {
        let engine = PlaybackEngine()
        engine.segments = (0..<180).map { SentenceSegment(index: $0 + 1, startTime: Double($0), endTime: Double($0 + 1), text: "Sentence number \($0) with some words.", translation: "这是第\($0)句的译文。") }
        engine.activeSegmentIndex = 0
        let settings = VideoSubtitleSettings.shared
        let original = settings.showOriginal
        let translation = settings.showTranslation
        settings.showOriginal = true; settings.showTranslation = true
        defer { settings.showOriginal = original; settings.showTranslation = translation }
        let (hosting, window) = host(PlaybackFullTextModeView(engine: engine, videoSubtitleSettings: settings))
        defer { window.orderOut(nil) }
        func texts(_ view: NSView) -> [FullTextNSTextView] {
            (view as? FullTextNSTextView).map { [$0] } ?? view.subviews.flatMap { texts($0) }
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertLessThan(texts(hosting).count, 180)
        engine.activeSegmentIndex = 130
        try await Task.sleep(for: .milliseconds(500))
        let active = try XCTUnwrap(texts(hosting).first { $0.string == engine.segments[130].text })
        XCTAssertTrue(hosting.bounds.insetBy(dx: 0, dy: 45).intersects(active.convert(active.bounds, to: hosting)))
    }

    func testReadingDefaultsAdaptButVideoAndCustomColorsStayIntact() {
        for mode in [PlaybackInterfaceMode.list, .sentence, .fullText, .fillInBlank] {
            XCTAssertEqual(VideoSubtitleSettings.readingColor(hex: "#FFFFFF", mode: mode), .labelColor)
            XCTAssertEqual(VideoSubtitleSettings.readingColor(hex: "#FFE36E", mode: mode), .labelColor)
            XCTAssertNotEqual(VideoSubtitleSettings.readingColor(hex: "#123456", mode: mode), .labelColor)
        }
        XCTAssertNotEqual(VideoSubtitleSettings.readingColor(hex: "#FFFFFF", mode: .video), .labelColor)
    }

    func testMuteRestoresLastNonzeroVolume() {
        let engine = PlaybackEngine()
        engine.volume = 0.2
        engine.toggleMute()
        XCTAssertEqual(engine.volume, 0)
        engine.toggleMute()
        XCTAssertEqual(engine.volume, 0.2, accuracy: 0.001)
        engine.volume = 0.6
        engine.volume = 0
        engine.toggleMute()
        XCTAssertEqual(engine.volume, 0.6, accuracy: 0.001)
    }

    func testHighlightChangesKeepStorageCharactersAndSelection() {
        let view = NSTextView()
        let renderer = FullTextTextRenderer()
        let text = "First sentence. Second sentence."
        let first = NSRange(location: 0, length: 15)
        let second = NSRange(location: 16, length: 16)
        XCTAssertTrue(renderer.update(view, text: text, font: .systemFont(ofSize: 16), color: .systemRed, lineSpacing: 6, activeRange: first))
        view.setSelectedRange(NSRange(location: 2, length: 4))
        var characterEdits = 0
        let token = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: view.textStorage, queue: .main) { note in
            if let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) { characterEdits += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        XCTAssertFalse(renderer.update(view, text: text, font: .systemFont(ofSize: 16), color: .systemRed, lineSpacing: 6, activeRange: second))
        XCTAssertEqual(characterEdits, 0)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 4))
        XCTAssertNil(view.textStorage?.attribute(.underlineStyle, at: first.location, effectiveRange: nil))
        XCTAssertEqual(view.textStorage?.attribute(.foregroundColor, at: first.location, effectiveRange: nil) as? NSColor, .systemRed)
        XCTAssertEqual(view.textStorage?.attribute(.foregroundColor, at: second.location, effectiveRange: nil) as? NSColor, .labelColor)
    }
}
