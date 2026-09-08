import AppKit
import XCTest
@testable import StudyMateKit

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

    func testMiddleBoundaryHitAllowsSmallTrackpadOffset() {
        let segment = SentenceSegment(index: 1, startTime: 1.0, endTime: 2.0)
        let view = WaveformInteractionNSViewRepresentable.InteractiveWaveformNSView(
            frame: NSRect(x: 0, y: 0, width: 1_000, height: 80)
        )
        view.segments = [segment]
        view.viewportStart = 0
        view.viewportEnd = 10

        // 起点在 101pt；中间区域允许触控板有约 15pt 的横向偏差，
        // 仍应抓到同一条绿线，而不是退化成普通点击选句。
        XCTAssertEqual(view.handle(at: NSPoint(x: 116, y: 40)), .start(id: segment.id))
    }

    func testInteractiveWaveformNSViewZoomDeltaCallback() {
        let view = WaveformInteractionNSViewRepresentable.InteractiveWaveformNSView(
            frame: NSRect(x: 0, y: 0, width: 1_000, height: 80)
        )
        var receivedDelta: Double?
        var receivedLoc: CGPoint?
        view.onZoomDelta = { delta, loc in
            receivedDelta = delta
            receivedLoc = loc
        }

        view.onZoomDelta?(0.15, CGPoint(x: 200, y: 40))
        XCTAssertEqual(receivedDelta, 0.15)
        XCTAssertEqual(receivedLoc, CGPoint(x: 200, y: 40))
    }

    func testPrimaryViewportAnchorZoom() {
        let engine = PlaybackEngine.shared
        engine.duration = 60.0
        // 设置初始视口 [10.0, 25.0] (span = 15.0，对应 1.0x 缩放)
        engine.setPrimaryViewport(start: 10.0, end: 25.0)

        // 以时间点 17.5 为锚点放大到 2.0x (newSpan = 15.0 / 2.0 = 7.5)
        // 17.5 原本在视口 50% 处，缩放后应该仍在视口 50% 处：[13.75, 21.25]
        engine.setPrimaryViewportZoom(zoomLevel: 2.0, anchorTime: 17.5)
        XCTAssertEqual(engine.primaryViewport.start, 13.75, accuracy: 0.001)
        XCTAssertEqual(engine.primaryViewport.end, 21.25, accuracy: 0.001)

        // 恢复 1.0x
        engine.setPrimaryViewportZoom(zoomLevel: 1.0)
        XCTAssertEqual(engine.primaryViewport.end - engine.primaryViewport.start, 15.0, accuracy: 0.001)
    }

    func testShortcutCatalogContainsToggleSecondaryWaveform() {
        let descriptor = StudyMateShortcutCatalog.all.first { $0.id == .toggleSecondaryWaveform }
        XCTAssertNotNil(descriptor)
        XCTAssertEqual(descriptor?.keyDisplay, "⌥⇧W")
        XCTAssertEqual(descriptor?.chineseName, "显示或隐藏次波形图")
    }
}
