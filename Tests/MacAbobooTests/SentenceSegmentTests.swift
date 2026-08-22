import XCTest
@testable import MacAbobooKit

final class SentenceSegmentTests: XCTestCase {
    func testSegmentCreationAndDuration() {
        let seg = SentenceSegment(
            index: 1,
            startTime: 2.500,
            endTime: 5.800,
            text: "Hello world"
        )
        
        XCTAssertEqual(seg.index, 1)
        XCTAssertEqual(seg.startTime, 2.500)
        XCTAssertEqual(seg.endTime, 5.800)
        XCTAssertEqual(seg.duration, 3.300, accuracy: 0.001)
        XCTAssertEqual(seg.text, "Hello world")
    }
    
    func testContainsTime() {
        let seg = SentenceSegment(
            index: 2,
            startTime: 10.0,
            endTime: 15.0
        )
        
        XCTAssertTrue(seg.contains(time: 10.0))
        XCTAssertTrue(seg.contains(time: 12.5))
        XCTAssertFalse(seg.contains(time: 9.999))
        XCTAssertFalse(seg.contains(time: 15.0))
        XCTAssertFalse(seg.contains(time: 20.0))
    }
    
    func testTimecodeFormatting() {
        XCTAssertEqual(SentenceSegment.formatTimecode(0.0), "00:00.000")
        XCTAssertEqual(SentenceSegment.formatTimecode(65.123), "01:05.123")
        XCTAssertEqual(SentenceSegment.formatTimecode(3665.456), "01:01:05.456")
        XCTAssertEqual(SentenceSegment.formatTimecode(59.9996), "01:00.000")
    }

    func testInvalidTimesAreSanitized() {
        let segment = SentenceSegment(index: 1, startTime: -10, endTime: -5)
        XCTAssertEqual(segment.startTime, 0)
        XCTAssertGreaterThanOrEqual(segment.endTime, 0.05)
    }
}
