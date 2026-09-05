import XCTest
@testable import StudyMateKit

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

    func testSpeakerRoleLabelFormatting() {
        // 无角色
        let noSpeaker = SentenceSegment(index: 0, startTime: 0, endTime: 1)
        XCTAssertEqual(noSpeaker.speakerRoleLabel, "")

        // 单说话人 s1 (speakerID: 0)
        let singleS1 = SentenceSegment(index: 1, startTime: 1, endTime: 2, speakerIDs: [0])
        XCTAssertEqual(singleS1.speakerRoleLabel, "s1")

        // 单说话人 s2 (speakerID: 1)
        let singleS2 = SentenceSegment(index: 2, startTime: 2, endTime: 3, speakerIDs: [1])
        XCTAssertEqual(singleS2.speakerRoleLabel, "s2")

        // 多说话人轮替 (s1→s2)
        let turnSpeakers = SentenceSegment(index: 3, startTime: 3, endTime: 4, speakerIDs: [0, 1], isSpeakerOverlap: false)
        XCTAssertEqual(turnSpeakers.speakerRoleLabel, "s1→s2")

        // 说话人重叠 (s1+s2)
        let overlapSpeakers = SentenceSegment(index: 4, startTime: 4, endTime: 5, speakerIDs: [0, 1], isSpeakerOverlap: true)
        XCTAssertEqual(overlapSpeakers.speakerRoleLabel, "s1+s2")
    }

    func testPlaybackInterfaceModeCases() {
        XCTAssertEqual(PlaybackInterfaceMode.allCases.count, 4)
        XCTAssertEqual(PlaybackInterfaceMode.video.rawValue, "video")
        XCTAssertEqual(PlaybackInterfaceMode.list.rawValue, "list")
        XCTAssertEqual(PlaybackInterfaceMode.fullText.rawValue, "fullText")
        XCTAssertEqual(PlaybackInterfaceMode.sentence.rawValue, "sentence")

        let lang = LanguageManager.shared
        XCTAssertFalse(PlaybackInterfaceMode.video.localized(with: lang).isEmpty)
        XCTAssertFalse(PlaybackInterfaceMode.list.localized(with: lang).isEmpty)
        XCTAssertFalse(PlaybackInterfaceMode.fullText.localized(with: lang).isEmpty)
        XCTAssertFalse(PlaybackInterfaceMode.sentence.localized(with: lang).isEmpty)
    }
}
