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
        XCTAssertTrue(html.contains("sound://audio/cat.mp3#studymate-dictionary=fixture"))
    }

    func testScriptsAreDeferredUntilEntryMarkupExists() throws {
        let entry = StudyMateDictionaryLookup(
            key: "food",
            text: #"<script src="jquery.js"></script><script>window.fixtureReady = !!document.querySelector('.fixture-content');</script><div class="fixture-content">ready</div>"#,
            dictionaryID: "fixture",
            dictionaryTitle: "Fixture"
        )

        let body = DictionaryHTMLFormatter.composeBodyHTML(entries: [entry], isCompact: false)
        let contentEnd = try XCTUnwrap(body.range(of: "</div>", options: .backwards))
        let jquery = try XCTUnwrap(body.range(of: "jquery.js"))
        let inlineScript = try XCTUnwrap(body.range(of: "fixtureReady"))

        XCTAssertGreaterThan(jquery.lowerBound, contentEnd.lowerBound)
        XCTAssertGreaterThan(inlineScript.lowerBound, contentEnd.lowerBound)
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

    func testRelativeDictionaryLinksAreNotRewrittenAsResources() {
        let root = URL(fileURLWithPath: "/tmp/StudyMate Dictionary/resources", isDirectory: true)
        let entry = StudyMateDictionaryLookup(
            key: "test",
            text: #"<a href="another-word">another word</a><link href="theme.css" rel="stylesheet"><img src="icons/test.png">"#,
            dictionaryID: "fixture",
            dictionaryTitle: "Fixture",
            resourceRoot: root.path
        )

        let html = DictionaryHTMLFormatter.composeBodyHTML(entries: [entry], isCompact: false)

        XCTAssertTrue(html.contains(#"href="another-word""#))
        XCTAssertTrue(html.contains("file:///tmp/StudyMate%20Dictionary/resources/theme.css"))
        XCTAssertTrue(html.contains("file:///tmp/StudyMate%20Dictionary/resources/icons/test.png"))
        XCTAssertFalse(html.contains("resources/another-word"))
    }

    func testJavaScriptLinksAndDynamicResourceAttributesArePreserved() {
        let root = URL(fileURLWithPath: "/tmp/StudyMate Dictionary/resources", isDirectory: true)
        let entry = StudyMateDictionaryLookup(
            key: "test",
            text: #"<a href="javascript:toggleEntry()">toggle</a><div style="background-image:url('images/bg.png')"><img srcset="images/icon.png 1x, images/icon@2x.png 2x"></div>"#,
            dictionaryID: "fixture",
            dictionaryTitle: "Fixture",
            resourceRoot: root.path
        )

        let html = DictionaryHTMLFormatter.composeBodyHTML(entries: [entry], isCompact: false)

        XCTAssertTrue(html.contains(#"href="javascript:toggleEntry()""#))
        XCTAssertTrue(html.contains("file:///tmp/StudyMate%20Dictionary/resources/images/bg.png"))
        XCTAssertTrue(html.contains("file:///tmp/StudyMate%20Dictionary/resources/images/icon.png 1x"))
        XCTAssertTrue(html.contains("file:///tmp/StudyMate%20Dictionary/resources/images/icon@2x.png 2x"))
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
