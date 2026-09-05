import AppKit
import SwiftUI
import XCTest
@testable import StudyMateKit

final class SegmentListInteractionTests: XCTestCase {
    func testUserScrollTemporarilySuppressesPlaybackFollowing() {
        var state = SegmentListFollowState()
        XCTAssertTrue(state.shouldFollow)

        state.markUserScroll()
        XCTAssertTrue(state.followsPlayback)
        XCTAssertTrue(state.isUserScrollSuppressed)
        XCTAssertFalse(state.shouldFollow)

        state.resumeFollowing()
        XCTAssertTrue(state.shouldFollow)
    }

    func testManualToggleClearsSuppressionAndRequiresExplicitResume() {
        var state = SegmentListFollowState()
        state.markUserScroll()
        state.toggle()

        XCTAssertFalse(state.followsPlayback)
        XCTAssertFalse(state.isUserScrollSuppressed)
        XCTAssertFalse(state.shouldFollow)

        state.toggle()
        XCTAssertTrue(state.shouldFollow)
    }

    func testDisabledFollowingIgnoresUserScroll() {
        var state = SegmentListFollowState()
        state.toggle()
        state.markUserScroll()

        XCTAssertFalse(state.followsPlayback)
        XCTAssertFalse(state.isUserScrollSuppressed)
        XCTAssertFalse(state.shouldFollow)
    }

    func testFollowControlUsesValidMacOSSymbols() {
        XCTAssertNotNil(NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: nil))
        XCTAssertNotNil(NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: nil))
    }

    func testSentenceFiltersCombineAllEnabledConditions() {
        let matching = SentenceSegment(
            index: 1,
            startTime: 0,
            endTime: 6,
            text: "Please open your books",
            translation: "请打开书",
            isBookmarked: true
        )
        let missingTranslation = SentenceSegment(
            index: 2,
            startTime: 0,
            endTime: 6,
            text: "Please open your books",
            translation: "",
            isBookmarked: true
        )

        var criteria = SegmentListFilterCriteria()
        criteria.requiresOriginal = true
        criteria.requiresTranslation = true
        criteria.requiresMinimumDuration = true
        criteria.minimumDurationText = "5"
        criteria.requiresWord = true
        criteria.wordText = "open"
        criteria.requiresBookmark = true

        XCTAssertTrue(criteria.matches(matching))
        XCTAssertFalse(criteria.matches(missingTranslation))
    }

    func testSentenceFiltersUseStrictDurationAndWholeWordMatching() {
        let exactlyFiveSeconds = SentenceSegment(
            index: 1,
            startTime: 0,
            endTime: 5,
            text: "the shell"
        )
        let longer = SentenceSegment(
            index: 2,
            startTime: 0,
            endTime: 5.1,
            text: "the shell"
        )

        var criteria = SegmentListFilterCriteria()
        criteria.requiresMinimumDuration = true
        criteria.minimumDurationText = "5"
        criteria.requiresWord = true
        criteria.wordText = "he"
        XCTAssertFalse(criteria.matches(exactlyFiveSeconds))

        criteria.wordText = "shell"
        XCTAssertFalse(criteria.matches(exactlyFiveSeconds))
        XCTAssertTrue(criteria.matches(longer))
    }

    func testSentenceFiltersIgnoreEmptyFilterValues() {
        let segment = SentenceSegment(
            index: 1,
            startTime: 0,
            endTime: 1,
            text: "Hello"
        )
        var criteria = SegmentListFilterCriteria()
        criteria.requiresMinimumDuration = true
        criteria.minimumDurationText = ""
        criteria.requiresWord = true
        criteria.wordText = "   "

        XCTAssertTrue(criteria.matches(segment))
    }

    func testSentenceFiltersSupportInclusiveIndexRange() {
        var criteria = SegmentListFilterCriteria()
        criteria.requiresIndexRange = true
        criteria.startIndexText = "5"
        criteria.endIndexText = "3"

        XCTAssertFalse(criteria.matches(SentenceSegment(index: 2, startTime: 0, endTime: 1)))
        XCTAssertTrue(criteria.matches(SentenceSegment(index: 3, startTime: 0, endTime: 1)))
        XCTAssertTrue(criteria.matches(SentenceSegment(index: 4, startTime: 0, endTime: 1)))
        XCTAssertTrue(criteria.matches(SentenceSegment(index: 5, startTime: 0, endTime: 1)))
        XCTAssertFalse(criteria.matches(SentenceSegment(index: 6, startTime: 0, endTime: 1)))
    }

    /// Regression guard for the large-list filtering path.  The view now takes
    /// a value snapshot and performs this same pure predicate work off the main
    /// actor; keeping a measured baseline here makes accidental O(N²) changes
    /// visible during CI performance runs.
    func testLargeTranscriptFilteringPerformanceBaseline() {
        let segments = (1...10_000).map { index in
            SentenceSegment(
                index: index,
                startTime: Double(index),
                endTime: Double(index) + (index.isMultiple(of: 3) ? 6 : 2),
                text: index.isMultiple(of: 10) ? "Please open the workbook" : "A short practice sentence",
                translation: index.isMultiple(of: 10) ? "请打开练习册" : "短练习句子",
                isBookmarked: index.isMultiple(of: 25)
            )
        }
        var criteria = SegmentListFilterCriteria()
        criteria.requiresMinimumDuration = true
        criteria.minimumDurationText = "5"
        criteria.requiresWord = true
        criteria.wordText = "open"
        criteria.requiresBookmark = true

        measure {
            _ = segments.filter { criteria.matches($0) }
        }
    }

    func testDictionarySelectableTextCoordinatorUpdatesCallbacksDynamically() {
        var clickedSegmentIndex: Int?
        var doubleClicked = false
        let coordinator = DictionarySelectableText.Coordinator(
            onSingleClick: { clickedSegmentIndex = 0 },
            onDoubleClick: { doubleClicked = true },
            onHoverChanged: nil
        )

        // Initial callback
        coordinator.onSingleClick?()
        XCTAssertEqual(clickedSegmentIndex, 0)

        // Updated callback for subsequent segment
        coordinator.onSingleClick = { clickedSegmentIndex = 5 }
        coordinator.onSingleClick?()
        XCTAssertEqual(clickedSegmentIndex, 5)

        coordinator.onDoubleClick?()
        XCTAssertTrue(doubleClicked)
    }

    @MainActor
    func testVideoSubtitleSelectionPausesPlayingMediaAndResumesAfterDismissal() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudyMate-DictionaryInteractionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("lookup-pause.mp4")
        try Data("media".utf8).write(to: mediaURL)

        let engine = makeTestPlaybackEngine()
        engine.loadMedia(from: mediaURL)
        engine.play()

        let coordinator = DictionaryInteractionCoordinator.shared
        coordinator.clearSelectionAndDeselect()
        coordinator.bindPlaybackEngine(engine)
        coordinator.pausePlaybackForVideoSubtitleSelection()

        XCTAssertFalse(engine.isPlaying)

        coordinator.updateSelection(text: "pause")
        coordinator.clearSelectionAndDeselect()

        XCTAssertTrue(engine.isPlaying)

        engine.pause()
        coordinator.clearSelectionAndDeselect()
    }

    @MainActor
    func testVideoSubtitleSelectionDoesNotResumeMediaThatWasAlreadyPaused() {
        let engine = makeTestPlaybackEngine()
        let coordinator = DictionaryInteractionCoordinator.shared
        coordinator.clearSelectionAndDeselect()
        coordinator.bindPlaybackEngine(engine)
        coordinator.pausePlaybackForVideoSubtitleSelection()
        coordinator.updateSelection(text: "pause")
        coordinator.clearSelectionAndDeselect()

        XCTAssertFalse(engine.isPlaying)
    }

    @MainActor
    func testVideoSubtitleSettingsPositionResets() {
        let settings = VideoSubtitleSettings.shared
        settings.originalPositionX = 0.2
        settings.originalPositionY = 0.3
        settings.translationPositionX = 0.8
        settings.translationPositionY = 0.9

        settings.resetPositions()
        XCTAssertEqual(settings.originalPositionX, 0.5, accuracy: 0.001)
        XCTAssertEqual(settings.originalPositionY, 0.76, accuracy: 0.001)
        XCTAssertEqual(settings.translationPositionX, 0.5, accuracy: 0.001)
        XCTAssertEqual(settings.translationPositionY, 0.86, accuracy: 0.001)
    }

    @MainActor
    func testDictionaryInteractionCoordinatorAnchorRectTrackingAndDeselection() {
        let coordinator = DictionaryInteractionCoordinator.shared
        let sampleRect = NSRect(x: 100, y: 200, width: 60, height: 20)

        coordinator.updateSelection(
            text: "wonderful",
            context: "A wonderful test sentence",
            screenRect: sampleRect
        )

        XCTAssertEqual(coordinator.selectedText, "wonderful")
        XCTAssertEqual(coordinator.contextText, "A wonderful test sentence")
        XCTAssertEqual(coordinator.anchorScreenRect, sampleRect)
        XCTAssertEqual(coordinator.anchorScreenPoint?.x, sampleRect.midX)
        XCTAssertEqual(coordinator.anchorScreenPoint?.y, sampleRect.midY)

        coordinator.clearSelectionAndDeselect()
        XCTAssertNil(coordinator.selectedText)
        XCTAssertNil(coordinator.contextText)
        XCTAssertNil(coordinator.anchorScreenRect)
        XCTAssertNil(coordinator.anchorScreenPoint)
    }

    func testCompiledVocabularyFilterMatchesWordsAccurately() {
        let words: Set<String> = ["blender", "return", "look up", "搅拌机", "don't"]
        let filter = CompiledVocabularyFilter(words: words)

        // 1. 英文单词完全匹配
        let s1 = SentenceSegment(index: 1, startTime: 0, endTime: 1, text: "She decided to return the blender.")
        XCTAssertTrue(filter.matches(segment: s1))

        // 2. 单词不匹配（避免“cat”命中“caterpillar”等子串误判）
        let filterCat = CompiledVocabularyFilter(words: ["cat"])
        let sCatWrong = SentenceSegment(index: 2, startTime: 0, endTime: 1, text: "The caterpillar is climbing.")
        XCTAssertFalse(filterCat.matches(segment: sCatWrong))
        let sCatRight = SentenceSegment(index: 3, startTime: 0, endTime: 1, text: "The cat is climbing.")
        XCTAssertTrue(filterCat.matches(segment: sCatRight))

        // 3. 中文生词匹配
        let sChinese = SentenceSegment(index: 4, startTime: 0, endTime: 1, text: "She bought a machine", translation: "她买了搅拌机")
        XCTAssertTrue(filter.matches(segment: sChinese))

        // 4. 短语匹配
        let sPhrase = SentenceSegment(index: 5, startTime: 0, endTime: 1, text: "Please look up the word.")
        XCTAssertTrue(filter.matches(segment: sPhrase))

        // 5. 标点与缩写词
        let sApostrophe = SentenceSegment(index: 6, startTime: 0, endTime: 1, text: "I don't know.")
        XCTAssertTrue(filter.matches(segment: sApostrophe))

        // 6. 空生词过滤器不匹配任何内容
        let emptyFilter = CompiledVocabularyFilter(words: [])
        XCTAssertFalse(emptyFilter.matches(segment: s1))
    }

    func testSentenceFiltersMatchVocabularyNotebook() {
        let matchingSegment = SentenceSegment(
            index: 1,
            startTime: 0,
            endTime: 5,
            text: "she decided to return the blender she",
            translation: "她决定把半年前买的搅拌机退掉"
        )
        let nonMatchingSegment = SentenceSegment(
            index: 2,
            startTime: 0,
            endTime: 5,
            text: "the weather is great today",
            translation: "今天天气很好"
        )

        var criteria = SegmentListFilterCriteria()
        criteria.requiresVocabularyNotebook = true
        criteria.compiledVocabularyFilter = CompiledVocabularyFilter(words: ["blender", "apple"])

        XCTAssertTrue(criteria.matches(matchingSegment))
        XCTAssertFalse(criteria.matches(nonMatchingSegment))

        // 与其它筛选条件组合
        criteria.requiresBookmark = true
        XCTAssertFalse(criteria.matches(matchingSegment)) // 未加星标

        let bookmarked = SentenceSegment(
            index: 1,
            startTime: 0,
            endTime: 5,
            text: "she decided to return the blender she",
            isBookmarked: true
        )
        XCTAssertTrue(criteria.matches(bookmarked))
    }

    func testDictionarySelectableTextSizeThatFitsCalculatesMultilineHeight() {
        let longSentence = "It's an album of pictures of the United States, the cities, the special places, and the people."
        let font = NSFont.systemFont(ofSize: 14)

        // 宽屏单行
        let wideSize = DictionarySelectableText.calculateFittingSize(
            text: longSentence,
            font: font,
            proposedWidth: 1200
        )

        // 窄屏自动换行（2-3行）
        let narrowSize = DictionarySelectableText.calculateFittingSize(
            text: longSentence,
            font: font,
            proposedWidth: 250
        )

        // 自动换行后的高度必须严格大于单行高度，确保保留足够的行高不发生遮挡
        XCTAssertGreaterThan(narrowSize.height, wideSize.height)
        XCTAssertGreaterThanOrEqual(narrowSize.height, wideSize.height * 1.8)

        // 空文本返回安全单行高度
        let emptySize = DictionarySelectableText.calculateFittingSize(
            text: "",
            font: font,
            proposedWidth: 300
        )
        XCTAssertGreaterThan(emptySize.height, 0)
    }
}

