import XCTest
@testable import MacAbobooKit

final class SubtitleParserTests: XCTestCase {
    func testSRTParsing() {
        let srtContent = """
        1
        00:00:01,000 --> 00:00:04,500
        Hello, welcome to MacAboboo!
        你好，欢迎使用 MacAboboo！
        
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
        XCTAssertEqual(items[0].text, "Hello, welcome to MacAboboo!")
        XCTAssertEqual(items[0].translation, "你好，欢迎使用 MacAboboo！")
        
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

    func testUTF16SubtitleFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-UTF16-\(UUID().uuidString).srt")
        defer { try? FileManager.default.removeItem(at: url) }
        let content = "1\n00:00:01,000 --> 00:00:02,000\n你好\n"
        try XCTUnwrap(content.data(using: .utf16)).write(to: url)
        let items = try SubtitleParser.shared.parse(from: url)
        XCTAssertEqual(items.first?.text, "你好")
    }
}
