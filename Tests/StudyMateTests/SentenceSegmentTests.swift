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
        XCTAssertEqual(PlaybackInterfaceMode.allCases.count, 6)
        XCTAssertEqual(PlaybackInterfaceMode.video.rawValue, "video")
        XCTAssertEqual(PlaybackInterfaceMode.list.rawValue, "list")
        XCTAssertEqual(PlaybackInterfaceMode.fullText.rawValue, "fullText")
        XCTAssertEqual(PlaybackInterfaceMode.sentence.rawValue, "sentence")
        XCTAssertEqual(PlaybackInterfaceMode.fillInBlank.rawValue, "fillInBlank")
        XCTAssertEqual(PlaybackInterfaceMode.reverseTranslation.rawValue, "reverseTranslation")
        XCTAssertTrue(PlaybackInterfaceMode.fillInBlank.isFillInBlankStyle)
        XCTAssertTrue(PlaybackInterfaceMode.reverseTranslation.isFillInBlankStyle)

        let lang = LanguageManager.shared
        XCTAssertFalse(PlaybackInterfaceMode.video.localized(with: lang).isEmpty)
        XCTAssertFalse(PlaybackInterfaceMode.list.localized(with: lang).isEmpty)
        XCTAssertFalse(PlaybackInterfaceMode.fullText.localized(with: lang).isEmpty)
        XCTAssertFalse(PlaybackInterfaceMode.sentence.localized(with: lang).isEmpty)
        XCTAssertFalse(PlaybackInterfaceMode.fillInBlank.localized(with: lang).isEmpty)
        XCTAssertFalse(PlaybackInterfaceMode.reverseTranslation.localized(with: lang).isEmpty)
    }

    func testFormatCoordinateTime() {
        XCTAssertEqual(SentenceSegment.formatCoordinateTime(0.0), "00:00:00")
        XCTAssertEqual(SentenceSegment.formatCoordinateTime(923.45), "00:15:23")
        XCTAssertEqual(SentenceSegment.formatCoordinateTime(3665.0), "01:01:05")
    }

    func testFormattedCoordinate() {
        // 1. 完整坐标：来源 + 原片序号 + 时间戳
        let segFull = SentenceSegment(
            index: 1,
            originalIndex: 88,
            startTime: 0.0,
            endTime: 5.0,
            text: "Life is like a box of chocolates.",
            sourceMediaName: "阿甘正传.mp4",
            sourceStartTime: 923.0
        )
        XCTAssertEqual(segFull.formattedCoordinate(language: .zh), "来源：阿甘正传.mp4 · 原#88 (00:15:23)")
        XCTAssertEqual(segFull.formattedCoordinate(language: .en), "Source: 阿甘正传.mp4 · #88 (00:15:23)")

        // 2. 来源 + 时间戳（无原序号）
        let segNoIdx = SentenceSegment(
            index: 2,
            startTime: 0.0,
            endTime: 3.0,
            text: "Hello",
            sourceMediaName: "阿甘正传.mp4",
            sourceStartTime: 125.0
        )
        XCTAssertEqual(segNoIdx.formattedCoordinate(language: .zh), "来源：阿甘正传.mp4 (00:02:05)")
        XCTAssertEqual(segNoIdx.formattedCoordinate(language: .en), "Source: 阿甘正传.mp4 (00:02:05)")

        // 3. 原序号 + 时间戳（无来源名称）
        let segNoMedia = SentenceSegment(
            index: 3,
            originalIndex: 88,
            startTime: 923.0,
            endTime: 928.0,
            text: "Hello"
        )
        XCTAssertEqual(segNoMedia.formattedCoordinate(language: .zh), "原片 #88 (00:15:23)")
        XCTAssertEqual(segNoMedia.formattedCoordinate(language: .en), "Orig #88 (00:15:23)")

        // 4. 两者皆无：返回 nil
        let segPlain = SentenceSegment(
            index: 4,
            startTime: 10.0,
            endTime: 15.0,
            text: "Plain"
        )
        XCTAssertNil(segPlain.formattedCoordinate(language: .zh))
    }
}
