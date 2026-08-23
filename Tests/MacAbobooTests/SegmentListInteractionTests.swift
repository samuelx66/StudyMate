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
}
