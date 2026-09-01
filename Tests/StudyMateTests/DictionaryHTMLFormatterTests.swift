import XCTest
@testable import StudyMateKit

final class DictionaryHTMLFormatterTests: XCTestCase {
    func testDetailMarkupKeepsAndRewritesScriptSources() {
        let root = URL(fileURLWithPath: "/tmp/StudyMate Dictionary/resources", isDirectory: true)
        let entry = StudyMateDictionaryLookup(
            key: "cat",
            text: #"<div><script src="dict.js"></script><img src="images/cat.png"><a href="sound://audio/cat.mp3">play</a></div>"#,
            dictionaryID: "fixture",
            dictionaryTitle: "Fixture",
            resourceRoot: root.path
        )

        let html = DictionaryHTMLFormatter.composeBodyHTML(entries: [entry], isCompact: false)

        XCTAssertTrue(html.contains("<script src="))
        XCTAssertTrue(html.contains("file:///tmp/StudyMate%20Dictionary/resources/dict.js"))
        XCTAssertTrue(html.contains("file:///tmp/StudyMate%20Dictionary/resources/images/cat.png"))
        XCTAssertTrue(html.contains("studymate-sound://fixture/audio/cat.mp3"))
    }

    func testLocalResourcesPreserveQueriesFragmentsAndExplicitSchemes() {
        let root = URL(fileURLWithPath: "/tmp/StudyMate Dictionary/resources", isDirectory: true)
        let entry = StudyMateDictionaryLookup(
            key: "test",
            text: #"<script src="scripts\dict.js?v=2"></script><img src="images/icon.svg#speaker"><a href="entry://next">next</a><img src="//cdn.example.com/icon.png">"#,
            dictionaryID: "fixture",
            dictionaryTitle: "Fixture",
            css: #"@font-face { src: url('fonts/test.woff2?#iefix'); }"#,
            resourceRoot: root.path
        )

        let html = DictionaryHTMLFormatter.composeHTML(entries: [entry], isCompact: false)

        XCTAssertTrue(html.contains("file:///tmp/StudyMate%20Dictionary/resources/scripts/dict.js?v=2"))
        XCTAssertTrue(html.contains("file:///tmp/StudyMate%20Dictionary/resources/images/icon.svg#speaker"))
        XCTAssertTrue(html.contains("file:///tmp/StudyMate%20Dictionary/resources/fonts/test.woff2?#iefix"))
        XCTAssertTrue(html.contains("entry://next"))
        XCTAssertTrue(html.contains("//cdn.example.com/icon.png"))
        XCTAssertFalse(html.contains("dict.js%3Fv=2"))
        XCTAssertFalse(html.contains("icon.svg%23speaker"))
    }

    func testFontScaleMatchesToolbarRange() throws {
        func numericSize(_ value: String) throws -> Double {
            let raw = value.hasSuffix("px") ? String(value.dropLast(2)) : value
            return try XCTUnwrap(Double(raw))
        }

        XCTAssertEqual(
            try numericSize(DictionaryHTMLFormatter.scaledFontSize(isCompact: false, textScale: 0.7)),
            14.5 * 0.7,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try numericSize(DictionaryHTMLFormatter.scaledFontSize(isCompact: false, textScale: 1.8)),
            14.5 * 1.8,
            accuracy: 0.000_001
        )
    }
}
