import XCTest
@testable import MacAbobooKit

@MainActor
final class IntensiveListeningTests: XCTestCase {
    func testTimelineShift() {
        let engine = makeTestPlaybackEngine()
        engine.segments = [
            SentenceSegment(index: 1, startTime: 1.0, endTime: 4.0),
            SentenceSegment(index: 2, startTime: 4.5, endTime: 8.0)
        ]
        
        // 整体平移 +500ms
        engine.shiftAllTimeline(by: 0.5)
        
        XCTAssertEqual(engine.segments[0].startTime, 1.5, accuracy: 0.001)
        XCTAssertEqual(engine.segments[0].endTime, 4.5, accuracy: 0.001)
        XCTAssertEqual(engine.segments[1].startTime, 5.0, accuracy: 0.001)
        XCTAssertEqual(engine.segments[1].endTime, 8.5, accuracy: 0.001)
    }
    
    func testBookmarkToggle() {
        let engine = makeTestPlaybackEngine()
        let seg = SentenceSegment(index: 1, startTime: 0.0, endTime: 3.0)
        engine.segments = [seg]
        
        XCTAssertFalse(engine.segments[0].isBookmarked)
        
        engine.toggleBookmark(for: seg.id)
        XCTAssertTrue(engine.segments[0].isBookmarked)
        
        engine.toggleBookmark(for: seg.id)
        XCTAssertFalse(engine.segments[0].isBookmarked)
    }
    
    func testRepeatCountConfiguration() {
        let engine = makeTestPlaybackEngine()
        engine.repeatCountLimit = 3
        XCTAssertEqual(engine.repeatCountLimit, 3)
        XCTAssertEqual(engine.currentRepeatCount, 1)
    }
}
