import AppKit
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
}
