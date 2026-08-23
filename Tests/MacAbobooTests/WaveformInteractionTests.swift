import AppKit
import XCTest
@testable import MacAbobooKit

@MainActor
final class WaveformInteractionTests: XCTestCase {
    func testTopBoundaryHitChoosesNearestStartMarker() {
        let first = SentenceSegment(index: 1, startTime: 1.0, endTime: 2.0)
        let second = SentenceSegment(index: 2, startTime: 1.2, endTime: 2.2)
        let view = WaveformInteractionNSViewRepresentable.InteractiveWaveformNSView(
            frame: NSRect(x: 0, y: 0, width: 1_000, height: 80)
        )
        view.segments = [first, second]
        view.viewportStart = 0
        view.viewportEnd = 10

        // 起点分别在 101pt 和 121pt；118pt 同时命中两条线，但更靠近第二条。
        XCTAssertEqual(view.handle(at: NSPoint(x: 118, y: 10)), .start(id: second.id))
    }

    func testBottomBoundaryHitChoosesNearestEndMarker() {
        let first = SentenceSegment(index: 1, startTime: 0, endTime: 2.0)
        let second = SentenceSegment(index: 2, startTime: 0.2, endTime: 2.2)
        let view = WaveformInteractionNSViewRepresentable.InteractiveWaveformNSView(
            frame: NSRect(x: 0, y: 0, width: 1_000, height: 80)
        )
        view.segments = [first, second]
        view.viewportStart = 0
        view.viewportEnd = 10

        // 终点分别在 199pt 和 219pt；216pt 必须命中距离更近的第二条。
        XCTAssertEqual(view.handle(at: NSPoint(x: 216, y: 70)), .end(id: second.id))
    }
}
