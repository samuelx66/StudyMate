import XCTest
@testable import StudyMateKit

final class SubtitleParserTests: XCTestCase {
    func testSRTParsing() {
        let srtContent = """
        1
        00:00:01,000 --> 00:00:04,500
        Hello, welcome to StudyMate!
        你好，欢迎使用 StudyMate！
        
        2
        00:00:05,200 --> 00:00:08,800
        This is an intensive listening tool.
        这是一个精听学习工具。
        """
        
        let items = SubtitleParser.shared.parseSRT(content: srtContent)
        XCTAssertEqual(items.count, 2)
        
        XCTAssertEqual(items[0].index, 1)
        XCTAssertEqual(items[0].startTime, 1.0, accuracy: 0.001)
        XCTAssertEqual(items[0].endTime, 4.5, accuracy: 0.001)
        XCTAssertEqual(items[0].text, "Hello, welcome to StudyMate!")
        XCTAssertEqual(items[0].translation, "你好，欢迎使用 StudyMate！")
        
        XCTAssertEqual(items[1].index, 2)
        XCTAssertEqual(items[1].startTime, 5.2, accuracy: 0.001)
        XCTAssertEqual(items[1].endTime, 8.8, accuracy: 0.001)
    }
    
    func testLRCParsing() {
        let lrcContent = """
        [ti:Sample Song]
        [ar:Singer]
        [00:02.50]First line of the song
        [00:06.80]Second line of the song
        [00:12.345]Third line of the song
        """
        
        let items = SubtitleParser.shared.parseLRC(content: lrcContent)
        XCTAssertEqual(items.count, 3)
        
        XCTAssertEqual(items[0].index, 1)
        XCTAssertEqual(items[0].startTime, 2.5, accuracy: 0.01)
        XCTAssertEqual(items[0].text, "First line of the song")
        XCTAssertEqual(items[0].endTime, 6.8, accuracy: 0.01)
        
        XCTAssertEqual(items[1].startTime, 6.8, accuracy: 0.01)
        XCTAssertEqual(items[1].endTime, 12.345, accuracy: 0.01)
    }

    func testBilingualLRCGroupsMatchingTimestamps() {
        let content = """
        [00:01.00]Good morning.
        [00:01.00]早上好。
        [00:03.50]How are you?
        [00:03.50]你好吗？
        """

        let items = SubtitleParser.shared.parseLRC(content: content)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].startTime, 1, accuracy: 0.001)
        XCTAssertEqual(items[0].endTime, 3.5, accuracy: 0.001)
        XCTAssertEqual(items[0].text, "Good morning.")
        XCTAssertEqual(items[0].translation, "早上好。")
        XCTAssertEqual(items[1].text, "How are you?")
        XCTAssertEqual(items[1].translation, "你好吗？")
    }
    
    func testTimestampParsing() {
        XCTAssertEqual(SubtitleParser.shared.parseTimestamp("01:23.456") ?? 0, 83.456, accuracy: 0.001)
        XCTAssertEqual(SubtitleParser.shared.parseTimestamp("01:02:03,456") ?? 0, 3723.456, accuracy: 0.001)
        XCTAssertNil(SubtitleParser.shared.parseTimestamp("00:00:61.000"))
        XCTAssertNil(SubtitleParser.shared.parseTimestamp("garbage"))
        XCTAssertNil(SubtitleParser.shared.parseTimestamp("-1.0"))
    }

    func testWebVTTSettingsAndMarkup() {
        let content = """
        WEBVTT

        cue-1
        00:01.000 --> 00:04.000 align:start position:10%
        <v Speaker>Hello &amp; welcome</v>
        """
        let items = SubtitleParser.shared.parseVTT(content: content)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].startTime, 1, accuracy: 0.001)
        XCTAssertEqual(items[0].endTime, 4, accuracy: 0.001)
        XCTAssertEqual(items[0].text, "Hello & welcome")
    }

    func testSameLanguageMultilineCueIsPreserved() {
        let content = """
        1
        00:00:01,000 --> 00:00:03,000
        This is one long subtitle
        wrapped across two lines.
        """
        let items = SubtitleParser.shared.parseSRT(content: content)
        XCTAssertEqual(items.first?.text, "This is one long subtitle\nwrapped across two lines.")
        XCTAssertEqual(items.first?.translation, "")
    }

    func testWrappedBilingualCueSplitsAtLanguageBoundary() {
        let content = """
        1
        00:00:01,000 --> 00:00:04,000
        This original subtitle wraps
        across two lines.
        这条译文也会换行，
        并完整保留。
        """
        let items = SubtitleParser.shared.parseSRT(content: content)
        XCTAssertEqual(items.first?.text, "This original subtitle wraps\nacross two lines.")
        XCTAssertEqual(items.first?.translation, "这条译文也会换行，\n并完整保留。")
    }

    func testExplicitImportTargetMovesAllTextIntoChosenField() {
        let item = ParsedSubtitleItem(
            index: 1,
            startTime: 1,
            endTime: 2,
            text: "Original",
            translation: "译文"
        )

        let original = SubtitleImportTarget.original.apply(to: [item])[0]
        XCTAssertEqual(original.text, "Original\n译文")
        XCTAssertEqual(original.translation, "")

        let translation = SubtitleImportTarget.translation.apply(to: [item])[0]
        XCTAssertEqual(translation.text, "")
        XCTAssertEqual(translation.translation, "Original\n译文")

        XCTAssertEqual(SubtitleImportTarget.automatic.apply(to: [item]), [item])
    }

    func testUTF16SubtitleFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudyMate-UTF16-\(UUID().uuidString).srt")
        defer { try? FileManager.default.removeItem(at: url) }
        let content = "1\n00:00:01,000 --> 00:00:02,000\n你好\n"
        try XCTUnwrap(content.data(using: .utf16)).write(to: url)
        let items = try SubtitleParser.shared.parse(from: url)
        XCTAssertEqual(items.first?.text, "你好")
    }

    func testASSParsing() {
        let assContent = """
        [Script Info]
        Title: Sample ASS
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.25,0:00:04.80,Default,,0,0,0,,{\\pos(192,200)}Hello World!\\N你好世界！
        Dialogue: 0,0:00:05.10,0:00:07.50,Default,,0,0,0,,Second line
        """
        let items = SubtitleParser.shared.parseASS(content: assContent)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].startTime, 1.25, accuracy: 0.001)
        XCTAssertEqual(items[0].endTime, 4.80, accuracy: 0.001)
        XCTAssertEqual(items[0].text, "Hello World!")
        XCTAssertEqual(items[0].translation, "你好世界！")
        XCTAssertEqual(items[1].text, "Second line")
    }

    func testArbitraryPrecisionTimestamp() {
        XCTAssertEqual(SubtitleParser.shared.parseTimestamp("00:01:23.456789") ?? 0, 83.456789, accuracy: 0.000001)
        XCTAssertEqual(SubtitleParser.shared.parseTimestamp("01:23.4") ?? 0, 83.4, accuracy: 0.001)
    }

    func testBilingualChineseTopEnglishBottomProperlyMapped() {
        let content = """
        1
        00:00:01,000 --> 00:00:04,000
        你好世界
        Hello world
        """
        let items = SubtitleParser.shared.parseSRT(content: content)
        XCTAssertEqual(items.first?.text, "Hello world")
        XCTAssertEqual(items.first?.translation, "你好世界")
    }
}
