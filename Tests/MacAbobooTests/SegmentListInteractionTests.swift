import AppKit
import XCTest
@testable import MacAbobooKit

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
}
