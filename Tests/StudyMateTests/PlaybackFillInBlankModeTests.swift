import AppKit
import SwiftUI
import XCTest
@testable import StudyMateKit

@MainActor
final class PlaybackFillInBlankModeTests: XCTestCase {
    // MARK: - Tokenizer 测试

    func testTokenizeEmptyAndWhitespaceString() {
        XCTAssertTrue(FillInBlankTokenizer.tokenize("").isEmpty)
        XCTAssertTrue(FillInBlankTokenizer.tokenize("   \n\t  ").isEmpty)
    }

    func testTokenizeSentenceWithPunctuationAndContractions() {
        let text = "Hello, world! It's 100% true—don't doubt it."
        let tokens = FillInBlankTokenizer.tokenize(text)

        // 提取所有被识别为单词槽的内容
        let words = tokens.filter { $0.isWord }.map { $0.text }
        XCTAssertEqual(words, ["Hello", "world", "It's", "100", "true", "don't", "doubt", "it"])

        // 验证标点符号被保留在非单词槽中
        let nonWords = tokens.filter { !$0.isWord }.map { $0.text }
        XCTAssertTrue(nonWords.contains(", "))
        XCTAssertTrue(nonWords.contains("! "))
        XCTAssertTrue(nonWords.contains("% "))
        XCTAssertTrue(nonWords.contains("."))

        // 验证 wordIndex 严格递增
        let wordIndices = tokens.compactMap { $0.wordIndex }
        XCTAssertEqual(wordIndices, Array(0..<words.count))
    }

    // MARK: - 词汇匹配测试（忽略大小写与缩写撇号兼容）

    func testWordMatchCaseInsensitive() {
        XCTAssertTrue(FillInBlankTokenizer.isMatch(input: "hello", target: "Hello"))
        XCTAssertTrue(FillInBlankTokenizer.isMatch(input: "HELLO", target: "hello"))
        XCTAssertTrue(FillInBlankTokenizer.isMatch(input: "  World  ", target: "world"))
        XCTAssertFalse(FillInBlankTokenizer.isMatch(input: "helo", target: "hello"))
        XCTAssertFalse(FillInBlankTokenizer.isMatch(input: "", target: "hello"))
    }

    func testWordMatchApostrophesAndContractions() {
        // 忽略标准撇号与弯引号差异
        XCTAssertTrue(FillInBlankTokenizer.isMatch(input: "don't", target: "don't"))
        XCTAssertTrue(FillInBlankTokenizer.isMatch(input: "don’t", target: "don't"))
        XCTAssertTrue(FillInBlankTokenizer.isMatch(input: "don't", target: "don’t"))

        // 允许省略撇号直接输入（如 "dont" 匹配 "don't"）
        XCTAssertTrue(FillInBlankTokenizer.isMatch(input: "dont", target: "don't"))
        XCTAssertTrue(FillInBlankTokenizer.isMatch(input: "DONT", target: "don't"))
        XCTAssertTrue(FillInBlankTokenizer.isMatch(input: "its", target: "it's"))
        XCTAssertTrue(FillInBlankTokenizer.isMatch(input: "im", target: "I'm"))
        XCTAssertTrue(FillInBlankTokenizer.isMatch(input: "well", target: "we'll"))
    }

    private func temporaryTestDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudyMate-FillInBlankTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - 播放引擎与填空停顿联动测试

    func testPauseAfterSegmentHoldsCurrentSegmentInFillInBlankMode() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("test.mp3")
        try Data("audio".utf8).write(to: mediaURL)

        let native = TestMediaPlayerBackend(duration: 20)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)

        engine.loopMode = .pauseAfterSegment
        engine.pauseAfterSegmentHoldsCurrentSegment = true
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 3),
            SentenceSegment(index: 2, startTime: 5, endTime: 8)
        ]
        engine.activeSegmentIndex = 0
        engine.play()
        XCTAssertTrue(engine.isPlaying)

        // 句1播完到末尾 3.0s
        native.emitTime(3.0)
        await Task.yield()

        // 在填空模式下：播放暂停，但保持在当前句0，且重定位回当前句起点0.0s供重新播放
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.activeSegmentIndex, 0)
        XCTAssertEqual(native.currentTime, 0.0, accuracy: 0.01)
    }

    func testAdvanceToNextSentenceAfterCompletionAdvancesAndPlays() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("test.mp3")
        try Data("audio".utf8).write(to: mediaURL)

        let native = TestMediaPlayerBackend(duration: 20)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)

        engine.loopMode = .pauseAfterSegment
        engine.pauseAfterSegmentHoldsCurrentSegment = true
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 3),
            SentenceSegment(index: 2, startTime: 5, endTime: 8)
        ]
        engine.activeSegmentIndex = 0

        // 模拟句1完成，调用 advanceToNextSentenceAfterCompletion
        let hasNext = engine.advanceToNextSentenceAfterCompletion()
        XCTAssertTrue(hasNext)
        await Task.yield()
        XCTAssertEqual(engine.activeSegmentIndex, 1)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(native.currentTime, 5.0, accuracy: 0.01)

        // 模拟句2（末句）完成
        let hasNextAgain = engine.advanceToNextSentenceAfterCompletion()
        XCTAssertFalse(hasNextAgain)
        await Task.yield()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(native.currentTime, 8.0, accuracy: 0.01)
    }

    func testNextSentenceHoldsOnNextSentenceAfterPlaying() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("test.mp3")
        try Data("audio".utf8).write(to: mediaURL)

        let native = TestMediaPlayerBackend(duration: 20)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)

        engine.loopMode = .pauseAfterSegment
        engine.pauseAfterSegmentHoldsCurrentSegment = true
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 3),
            SentenceSegment(index: 2, startTime: 5, endTime: 8)
        ]
        engine.activeSegmentIndex = 0

        // 句1完成并切到句2起播
        let hasNext = engine.advanceToNextSentenceAfterCompletion()
        XCTAssertTrue(hasNext)
        await Task.yield()
        XCTAssertEqual(engine.activeSegmentIndex, 1)
        XCTAssertTrue(engine.isPlaying)

        // 句2播完到 8.0s 边界
        native.emitTime(8.0)
        await Task.yield()

        // 验证句2播完后暂停，并且保持在句2（索引 1），且回到句2起点 5.0s，绝不乱切
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.activeSegmentIndex, 1)
        XCTAssertEqual(native.currentTime, 5.0, accuracy: 0.01)
    }

    // MARK: - 模式属性与译文默认隐藏测试

    func testPlaybackInterfaceModeFillInBlankProperties() {
        let mode = PlaybackInterfaceMode.fillInBlank
        XCTAssertEqual(mode.id, "fillInBlank")
        XCTAssertEqual(mode.iconName, "character.textbox")
        XCTAssertEqual(mode.localized(with: .shared), "填空模式")
    }

    func testFillInBlankTranslationHiddenByDefaultAndToggleable() {
        let settings = VideoSubtitleSettings.shared
        let originalFillVal = settings.showTranslationInFillInBlank
        defer { settings.showTranslationInFillInBlank = originalFillVal }

        // 默认情况下，填空模式译文应该处于隐藏状态（false），而其他常规模式处于开启（true）
        settings.showTranslationInFillInBlank = false
        XCTAssertFalse(settings.isTranslationVisible(for: .fillInBlank))
        XCTAssertEqual(settings.isTranslationVisible(for: .video), settings.showTranslation)
        XCTAssertEqual(settings.isTranslationVisible(for: .list), settings.showTranslation)
        XCTAssertEqual(settings.isTranslationVisible(for: .sentence), settings.showTranslation)
        XCTAssertEqual(settings.isTranslationVisible(for: .fullText), settings.showTranslation)

        // 切换填空模式译文
        settings.toggleTranslation(for: .fillInBlank)
        XCTAssertTrue(settings.showTranslationInFillInBlank)
        XCTAssertTrue(settings.isTranslationVisible(for: .fillInBlank))

        // 再次切换
        settings.toggleTranslation(for: .fillInBlank)
        XCTAssertFalse(settings.showTranslationInFillInBlank)
        XCTAssertFalse(settings.isTranslationVisible(for: .fillInBlank))
    }

    func testFillInBlankOriginalHiddenByDefaultAndToggleableWithAutoHide() {
        let settings = VideoSubtitleSettings.shared
        let originalVal = settings.showOriginalInFillInBlank
        defer { settings.showOriginalInFillInBlank = originalVal }

        // 默认情况下，填空模式原文处于隐藏状态（false），而常规模式处于开启（true）
        settings.showOriginalInFillInBlank = false
        XCTAssertFalse(settings.isOriginalVisible(for: .fillInBlank))
        XCTAssertEqual(settings.isOriginalVisible(for: .video), settings.showOriginal)

        // 切换填空模式原文：显示原文
        settings.toggleOriginal(for: .fillInBlank)
        XCTAssertTrue(settings.showOriginalInFillInBlank)
        XCTAssertTrue(settings.isOriginalVisible(for: .fillInBlank))

        // 再次切换：手动隐藏原文
        settings.toggleOriginal(for: .fillInBlank)
        XCTAssertFalse(settings.showOriginalInFillInBlank)
        XCTAssertFalse(settings.isOriginalVisible(for: .fillInBlank))

        // 显示原文后调用 hideOriginalPeekInFillInBlank（如切句或退出视图）
        settings.toggleOriginal(for: .fillInBlank)
        XCTAssertTrue(settings.showOriginalInFillInBlank)
        settings.hideOriginalPeekInFillInBlank()
        XCTAssertFalse(settings.showOriginalInFillInBlank)
    }

    func testRepeatCurrentSegmentReplaysCurrentSentenceFromStart() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("test.mp3")
        try Data("audio".utf8).write(to: mediaURL)

        let native = TestMediaPlayerBackend(duration: 20)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)

        engine.loopMode = .pauseAfterSegment
        engine.pauseAfterSegmentHoldsCurrentSegment = true
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 3),
            SentenceSegment(index: 2, startTime: 5, endTime: 8)
        ]
        engine.activeSegmentIndex = 1
        native.emitTime(7.0)
        await Task.yield()

        // 点击重听当前句（⌘R）
        engine.repeatCurrentSegment()
        await Task.yield()

        // 验证精确定位回当前句2起点 5.0s 且开始播放
        XCTAssertEqual(engine.activeSegmentIndex, 1)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(native.currentTime, 5.0, accuracy: 0.01)
    }

    func testFillInBlankWordSlotFieldSpaceHintAndReplayShortcut() {
        var inputResult = ""
        var replayed = false

        let field = FillInBlankWordSlotField(
            wordIndex: 0,
            targetWord: "Awesome",
            font: .systemFont(ofSize: 20),
            textColor: .white,
            isCompleted: false,
            isFocused: true,
            onInputChanged: { inputResult = $0 },
            onBecameFocused: {},
            onTab: {},
            onBacktab: {},
            onReplayAudio: { replayed = true }
        )

        let coordinator = field.makeCoordinator()
        let tf = WordSlotNSTextField()
        tf.stringValue = ""
        tf.textColor = NSColor.white
        tf.delegate = coordinator
        coordinator.textField = tf

        // 1. 测试空格禁止输入
        let tv = NSTextView()
        let allowSpace = coordinator.textView(tv, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: " ")
        XCTAssertFalse(allowSpace, "下划线槽位应完全拒绝空格输入")

        // 2. 模拟用户输入部分文本 "Awe"
        tf.stringValue = "Awe"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: tf))
        XCTAssertEqual(inputResult, "Awe")

        // 3. 模拟按住空格键（KeyDown）-> 提示键功能：显示目标单词并变橙色
        let spaceDownEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        )!

        let handledDown = coordinator.handleKeyEvent(spaceDownEvent)
        XCTAssertNil(handledDown, "空格按下事件应被拦截消费（返回 nil）")
        // 验证处于提示状态：槽内显示完整目标词 "Awesome"，且颜色为 systemOrange
        XCTAssertTrue(coordinator.isHinting)
        XCTAssertEqual(tf.stringValue, "Awesome")
        XCTAssertEqual(tf.textColor, NSColor.systemOrange)

        // 提示期间禁止修改文本
        let allowEditDuringHint = coordinator.textView(tv, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: "x")
        XCTAssertFalse(allowEditDuringHint, "提示期间不允许修改文本")

        // 4. 模拟松开空格键（KeyUp）-> 恢复用户先前输入并退出提示
        let spaceUpEvent = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        )!
        let handledUp = coordinator.handleKeyEvent(spaceUpEvent)
        XCTAssertNil(handledUp, "空格松开事件应被拦截消费（返回 nil）")

        XCTAssertFalse(coordinator.isHinting)
        XCTAssertEqual(tf.stringValue, "Awe", "松开空格键后必须恢复用户此前输入内容")
        XCTAssertEqual(tf.textColor, NSColor.white, "松开空格键后恢复正常文本颜色")

        // 5. 测试 ⌘R 重听当前句快捷键拦截
        let cmdREvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "r",
            charactersIgnoringModifiers: "r",
            isARepeat: false,
            keyCode: 15
        )!
        let handledCmdR = coordinator.handleKeyEvent(cmdREvent)
        XCTAssertNil(handledCmdR, "⌘R 按下事件应被拦截消费（返回 nil）")
        XCTAssertTrue(replayed, "按下 ⌘R 必须触发 onReplayAudio 回调")
    }

    func testCommonComponentsInstantiation() {
        let engine = PlaybackEngine()
        var isScrubbing = false
        var isVolumeScrubbing = false

        let bottomBar = PlaybackModeBottomBar(
            engine: engine,
            isScrubbing: Binding(get: { isScrubbing }, set: { isScrubbing = $0 }),
            isVolumeScrubbing: Binding(get: { isVolumeScrubbing }, set: { isVolumeScrubbing = $0 })
        )
        XCTAssertNotNil(bottomBar)

        let container = PlaybackWorkspaceContainer(
            engine: engine,
            isWaveformsVisible: true,
            isSubtitleEditVisible: true
        ) {
            Text("Workspace Content")
        }
        XCTAssertNotNil(container)
    }
}

