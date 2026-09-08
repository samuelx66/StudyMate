import AppKit
import XCTest
@testable import StudyMateKit

@MainActor
final class WaveformInteractionTests: XCTestCase {
    func testStartBoundaryHitChoosesNearestLine() {
        let first = SentenceSegment(index: 1, startTime: 1.0, endTime: 2.0)
        let second = SentenceSegment(index: 2, startTime: 1.03, endTime: 2.03)
        let view = WaveformInteractionNSViewRepresentable.InteractiveWaveformNSView(
            frame: NSRect(x: 0, y: 0, width: 1_000, height: 80)
        )
        view.segments = [first, second]
        view.viewportStart = 0
        view.viewportEnd = 10

        // 起点分别在 101pt 和 104pt；103.5pt 在垂直线中间区域(y=40)，两条线均在 4pt 容差内，更靠近第二条。
        XCTAssertEqual(view.handle(at: NSPoint(x: 103.5, y: 40)), .start(id: second.id))
    }

    func testEndBoundaryHitChoosesNearestLine() {
        let first = SentenceSegment(index: 1, startTime: 0, endTime: 2.0)
        let second = SentenceSegment(index: 2, startTime: 0.03, endTime: 2.03)
        let view = WaveformInteractionNSViewRepresentable.InteractiveWaveformNSView(
            frame: NSRect(x: 0, y: 0, width: 1_000, height: 80)
        )
        view.segments = [first, second]
        view.viewportStart = 0
        view.viewportEnd = 10

        // 终点分别在 199pt 和 202pt；201.5pt 在垂直线中间区域(y=40)，两条线均在 4pt 容差内，更靠近第二条。
        XCTAssertEqual(view.handle(at: NSPoint(x: 201.5, y: 40)), .end(id: second.id))
    }

    func testBoundaryHitStrictlyOnVerticalLinesAndBadges() {
        let segment = SentenceSegment(index: 1, startTime: 1.0, endTime: 2.0)
        let view = WaveformInteractionNSViewRepresentable.InteractiveWaveformNSView(
            frame: NSRect(x: 0, y: 0, width: 1_000, height: 80)
        )
        view.segments = [segment]
        view.viewportStart = 0
        view.viewportEnd = 10

        // 起点标线在 101pt：在垂直标线上(x=103, y=40, 容差<=4pt)可拖移
        XCTAssertEqual(view.handle(at: NSPoint(x: 103, y: 40)), .start(id: segment.id))
        // 在绿色起始徽章 >S#1 上(x=122, y=11)可拖移
        XCTAssertEqual(view.handle(at: NSPoint(x: 122, y: 11)), .start(id: segment.id))
        // 偏离垂直标线且不在徽章上(x=116, y=40)不可拖移，返回 nil
        XCTAssertNil(view.handle(at: NSPoint(x: 116, y: 40)))

        // 终点标线在 199pt：在垂直标线上(x=198, y=40)可拖移
        XCTAssertEqual(view.handle(at: NSPoint(x: 198, y: 40)), .end(id: segment.id))
        // 在橙色结束徽章 E#1< 上(x=178, y=69)可拖移
        XCTAssertEqual(view.handle(at: NSPoint(x: 178, y: 69)), .end(id: segment.id))
        // 偏离终点标线且不在徽章上(x=178, y=40)不可拖移，返回 nil
        XCTAssertNil(view.handle(at: NSPoint(x: 178, y: 40)))
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
