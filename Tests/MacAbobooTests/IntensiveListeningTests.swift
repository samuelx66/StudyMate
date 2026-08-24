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

    func testNavigationBookmarkToggleIsIndependentFromDifficultyBookmark() {
        let engine = makeTestPlaybackEngine()
        let seg = SentenceSegment(index: 1, startTime: 0.0, endTime: 3.0)
        engine.segments = [seg]

        engine.toggleNavigationBookmark(for: seg.id)
        XCTAssertTrue(engine.segments[0].isNavigationBookmarked)
        XCTAssertFalse(engine.segments[0].isBookmarked)

        engine.toggleNavigationBookmark(for: seg.id)
        XCTAssertFalse(engine.segments[0].isNavigationBookmarked)
    }

    func testSplitKeepsOriginalAndTranslationInBothNewSegments() {
        let engine = makeTestPlaybackEngine()
        let original = "Please open your books."
        let translation = "请打开你们的书。"
        let segment = SentenceSegment(
            index: 1,
            startTime: 0.0,
            endTime: 6.0,
            text: original,
            translation: translation
        )
        engine.segments = [segment]

        engine.splitSegment(id: segment.id, at: 3.0)

        XCTAssertEqual(engine.segments.count, 2)
        XCTAssertEqual(engine.segments[0].text, original)
        XCTAssertEqual(engine.segments[1].text, original)
        XCTAssertEqual(engine.segments[0].translation, translation)
        XCTAssertEqual(engine.segments[1].translation, translation)
    }

    func testMergeConcatenatesOriginalAndTranslationSeparately() {
        let engine = makeTestPlaybackEngine()
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0.0, endTime: 3.0, text: "First", translation: "第一句"),
            SentenceSegment(index: 2, startTime: 3.0, endTime: 6.0, text: "Second", translation: "第二句")
        ]

        engine.mergeSegmentWithNext(at: 0)

        XCTAssertEqual(engine.segments.count, 1)
        XCTAssertEqual(engine.segments[0].text, "First Second")
        XCTAssertEqual(engine.segments[0].translation, "第一句 第二句")
    }

    func testMergeWithPreviousUsesTheSameMergeSemantics() {
        let engine = makeTestPlaybackEngine()
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0.0, endTime: 3.0, text: "First", translation: "第一句"),
            SentenceSegment(index: 2, startTime: 3.0, endTime: 6.0, text: "Second", translation: "第二句")
        ]

        engine.mergeSegmentWithPrevious(id: engine.segments[1].id)

        XCTAssertEqual(engine.segments.count, 1)
        XCTAssertEqual(engine.segments[0].text, "First Second")
        XCTAssertEqual(engine.segments[0].translation, "第一句 第二句")
    }
    
    func testRepeatCountConfiguration() {
        let engine = makeTestPlaybackEngine()
        engine.repeatCountLimit = 3
        XCTAssertEqual(engine.repeatCountLimit, 3)
        XCTAssertEqual(engine.currentRepeatCount, 1)
    }
}
