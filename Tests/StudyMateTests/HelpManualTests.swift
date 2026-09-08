import XCTest
@testable import StudyMateKit

final class HelpManualTests: XCTestCase {

    func testHelpResolverFindsLocalDocuments() {
        // 中文帮助手册解析
        let (zhText, zhURL) = StudyMateHelpResolver.readHelpMarkdown(for: .zh)
        XCTAssertNotNil(zhURL, "Should resolve zh_cn.md URL")
        XCTAssertTrue(zhURL?.lastPathComponent == "zh_cn.md")
        XCTAssertFalse(zhText.isEmpty, "zh_cn.md content should not be empty")
        XCTAssertTrue(zhText.contains("学伴使用参考手册"))

        // 英文帮助手册解析
        let (_, enURL) = StudyMateHelpResolver.readHelpMarkdown(for: .en)
        XCTAssertNotNil(enURL, "Should resolve en.md URL")
        XCTAssertTrue(enURL?.lastPathComponent == "en.md")
    }

    func testMarkdownParserConvertsHeadings() {
        let md = """
        # Main Title
        ## Subtitle Two
        ### Section Three
        """
        let html = StudyMateMarkdownParser.toHTML(markdown: md, title: "Test")
        XCTAssertTrue(html.contains("<h1 id=\"main-title\">Main Title</h1>"))
        XCTAssertTrue(html.contains("<h2 id=\"subtitle-two\">Subtitle Two</h2>"))
        XCTAssertTrue(html.contains("<h3 id=\"section-three\">Section Three</h3>"))
    }

    func testMarkdownParserConvertsCodeBlocksAndInline() {
        let md = """
        Here is `inline code`.

        ```swift
        func study() {
            print("mate")
        }
        ```
        """
        let html = StudyMateMarkdownParser.toHTML(markdown: md, title: "Test")
        XCTAssertTrue(html.contains("<code>inline code</code>"))
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">func study() {\n    print(&quot;mate&quot;)\n}</code></pre>"))
    }

    func testMarkdownParserConvertsTables() {
        let md = """
        | 功能 | 快捷键 |
        | :--- | ---: |
        | 播放 | 空格 |
        | 复读 | ⌘R |
        """
        let html = StudyMateMarkdownParser.toHTML(markdown: md, title: "Test")
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<th style=\"text-align: left;\">功能</th>"))
        XCTAssertTrue(html.contains("<th style=\"text-align: right;\">快捷键</th>"))
        XCTAssertTrue(html.contains("<td style=\"text-align: left;\">播放</td>"))
        XCTAssertTrue(html.contains("<td style=\"text-align: right;\">空格</td>"))
    }

    func testMarkdownParserConvertsInlineStylesAndLinks() {
        let md = """
        This is **bold**, *italic*, ~~deleted~~, and [Apple](https://apple.com).
        """
        let html = StudyMateMarkdownParser.toHTML(markdown: md, title: "Test")
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<em>italic</em>"))
        XCTAssertTrue(html.contains("<del>deleted</del>"))
        XCTAssertTrue(html.contains("<a href=\"https://apple.com\" target=\"_blank\" rel=\"noopener noreferrer\">Apple</a>"))
    }

    func testMarkdownParserConvertsListsAndBlockquotes() {
        let md = """
        > Important notice
        > Second line

        - Item 1
        - Item 2
        """
        let html = StudyMateMarkdownParser.toHTML(markdown: md, title: "Test")
        XCTAssertTrue(html.contains("<blockquote><p>Important notice<br/>Second line</p></blockquote>"))
        XCTAssertTrue(html.contains("<ul><li>Item 1</li><li>Item 2</li></ul>"))
    }

    func testMarkdownParserGeneratesCompleteHTMLDocument() {
        let md = "# Hello"
        let html = StudyMateMarkdownParser.toHTML(markdown: md, title: "My Title")
        XCTAssertTrue(html.contains("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("<title>My Title</title>"))
        XCTAssertTrue(html.contains("prefers-color-scheme: dark"))
        XCTAssertTrue(html.contains("</body>"))
    }
}
