import Foundation

/// 帮助文档本地文件定位解析器
/// 严格限定帮助文件只位于工程根目录的 `./Documents`，
/// 打包后则从 App Bundle 内置的 `Contents/Resources/Documents` 获取。
public enum StudyMateHelpResolver {
    public static func resolveHelpMarkdownURL(for language: AppLanguage) -> URL? {
        let filename = language == .zh ? "zh_cn.md" : "en.md"

        // 1. 开发环境：当前工作目录下的 ./Documents
        let localDirURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Documents")
            .appendingPathComponent(filename)
            .standardizedFileURL
        if FileManager.default.fileExists(atPath: localDirURL.path) {
            return localDirURL
        }

        // 2. 打包运行环境：App Bundle 的 Contents/Resources/Documents
        if let resourceURL = Bundle.main.resourceURL {
            let bundledDocURL = resourceURL
                .appendingPathComponent("Documents")
                .appendingPathComponent(filename)
                .standardizedFileURL
            if FileManager.default.fileExists(atPath: bundledDocURL.path) {
                return bundledDocURL
            }
        }

        // 3. Bundle.main 标准资源查找
        let filenameWithoutExt = language == .zh ? "zh_cn" : "en"
        if let bundleURL = Bundle.main.url(forResource: filenameWithoutExt, withExtension: "md", subdirectory: "Documents") {
            return bundleURL
        }
        if let bundleURL = Bundle.main.url(forResource: filenameWithoutExt, withExtension: "md") {
            return bundleURL
        }

        return nil
    }

    public static func readHelpMarkdown(for language: AppLanguage) -> (content: String, fileURL: URL?) {
        guard let url = resolveHelpMarkdownURL(for: language) else {
            return ("", nil)
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            return (text, url)
        } catch {
            return ("", url)
        }
    }
}

/// 轻量、无三方依赖的 Markdown 转 HTML 渲染器
/// 生成符合 macOS 26 原生排版、自适应深浅色模式（Light/Dark Mode）的精美 HTML 文档。
public enum StudyMateMarkdownParser {

    public static func toHTML(markdown: String, title: String = "StudyMate Help") -> String {
        let bodyHTML = renderMarkdownToBodyHTML(markdown)
        return wrapInHTMLDocument(bodyHTML: bodyHTML, title: title)
    }

    // MARK: - Markdown Block Parsing

    private static func renderMarkdownToBodyHTML(_ markdown: String) -> String {
        let rawLines = markdown.components(separatedBy: .newlines)
        var html: [String] = []

        var inCodeBlock = false
        var codeBlockLang = ""
        var codeBlockLines: [String] = []

        var inTable = false
        var tableHeader: [String] = []
        var tableAlignments: [String] = []
        var tableRows: [[String]] = []

        var inList = false
        var isOrderedList = false
        var listItems: [String] = []

        var inBlockquote = false
        var blockquoteLines: [String] = []

        var paragraphLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let text = paragraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                html.append("<p>\(parseInline(text))</p>")
            }
            paragraphLines.removeAll()
        }

        func flushList() {
            guard inList, !listItems.isEmpty else {
                inList = false
                listItems.removeAll()
                return
            }
            let tag = isOrderedList ? "ol" : "ul"
            var listHTML = "<\(tag)>"
            for item in listItems {
                listHTML += "<li>\(parseInline(item))</li>"
            }
            listHTML += "</\(tag)>"
            html.append(listHTML)
            inList = false
            listItems.removeAll()
        }

        func flushBlockquote() {
            guard inBlockquote, !blockquoteLines.isEmpty else {
                inBlockquote = false
                blockquoteLines.removeAll()
                return
            }
            let quoteText = blockquoteLines.joined(separator: "<br/>")
            html.append("<blockquote><p>\(parseInline(quoteText))</p></blockquote>")
            inBlockquote = false
            blockquoteLines.removeAll()
        }

        func flushTable() {
            guard inTable, !tableHeader.isEmpty else {
                inTable = false
                tableHeader.removeAll()
                tableAlignments.removeAll()
                tableRows.removeAll()
                return
            }

            var tableHTML = "<table><thead><tr>"
            for (idx, th) in tableHeader.enumerated() {
                let align = tableAlignments.indices.contains(idx) ? tableAlignments[idx] : "left"
                tableHTML += "<th style=\"text-align: \(align);\">\(parseInline(th))</th>"
            }
            tableHTML += "</tr></thead><tbody>"

            for row in tableRows {
                tableHTML += "<tr>"
                for (idx, cell) in row.enumerated() {
                    let align = tableAlignments.indices.contains(idx) ? tableAlignments[idx] : "left"
                    tableHTML += "<td style=\"text-align: \(align);\">\(parseInline(cell))</td>"
                }
                tableHTML += "</tr>"
            }

            tableHTML += "</tbody></table>"
            html.append(tableHTML)
            inTable = false
            tableHeader.removeAll()
            tableAlignments.removeAll()
            tableRows.removeAll()
        }

        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 1. 代码块处理
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if inCodeBlock {
                    // 代码块结束
                    let codeContent = escapeHTML(codeBlockLines.joined(separator: "\n"))
                    let langClass = codeBlockLang.isEmpty ? "" : " class=\"language-\(escapeHTML(codeBlockLang))\""
                    html.append("<pre><code\(langClass)>\(codeContent)</code></pre>")
                    inCodeBlock = false
                    codeBlockLang = ""
                    codeBlockLines.removeAll()
                } else {
                    // 代码块开始
                    flushParagraph()
                    flushList()
                    flushBlockquote()
                    flushTable()
                    inCodeBlock = true
                    codeBlockLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }

            if inCodeBlock {
                codeBlockLines.append(line)
                continue
            }

            // 2. 空行
            if trimmed.isEmpty {
                flushParagraph()
                flushList()
                flushBlockquote()
                flushTable()
                continue
            }

            // 3. 表格检测
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.contains("|") {
                flushParagraph()
                flushList()
                flushBlockquote()

                let cells = trimmed
                    .split(separator: "|", omittingEmptySubsequences: false)
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }

                if !inTable {
                    // 表头行
                    inTable = true
                    tableHeader = cells
                } else if tableAlignments.isEmpty {
                    // 分隔行（如 |:---|---:|:---:|）
                    tableAlignments = cells.map { cell in
                        let hasLeft = cell.hasPrefix(":")
                        let hasRight = cell.hasSuffix(":")
                        if hasLeft && hasRight { return "center" }
                        if hasRight { return "right" }
                        return "left"
                    }
                } else {
                    // 数据行
                    tableRows.append(cells)
                }
                continue
            } else if inTable {
                flushTable()
            }

            // 4. 水平分割线 (---, ***, ___)
            if trimmed == "---" || trimmed == "***" || trimmed == "___" || trimmed == "- - -" {
                flushParagraph()
                flushList()
                flushBlockquote()
                html.append("<hr />")
                continue
            }

            // 5. 标题 (#, ##, ...)
            if trimmed.hasPrefix("#") {
                flushParagraph()
                flushList()
                flushBlockquote()

                var level = 0
                for char in trimmed {
                    if char == "#" { level += 1 } else { break }
                }
                if level >= 1 && level <= 6 {
                    let headerText = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                    let slug = headerText.lowercased().replacingOccurrences(of: " ", with: "-")
                    html.append("<h\(level) id=\"\(escapeHTML(slug))\">\(parseInline(headerText))</h\(level)>")
                    continue
                }
            }

            // 6. 引用块 (> quote)
            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                inBlockquote = true
                let quoteText = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                blockquoteLines.append(quoteText)
                continue
            } else if inBlockquote {
                flushBlockquote()
            }

            // 7. 列表项
            // 无序列表
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                let itemText = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !inList || isOrderedList {
                    flushList()
                    inList = true
                    isOrderedList = false
                }
                // 支持复选框任务列表
                if itemText.hasPrefix("[ ] ") {
                    listItems.append("<input type=\"checkbox\" disabled /> " + String(itemText.dropFirst(4)))
                } else if itemText.hasPrefix("[x] ") || itemText.hasPrefix("[X] ") {
                    listItems.append("<input type=\"checkbox\" checked disabled /> " + String(itemText.dropFirst(4)))
                } else {
                    listItems.append(itemText)
                }
                continue
            }

            // 有序列表 (如 1. 2. )
            if let regex = try? NSRegularExpression(pattern: #"^\d+\.\s+(.*)$"#),
               let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.utf16.count)) {
                flushParagraph()
                if !inList || !isOrderedList {
                    flushList()
                    inList = true
                    isOrderedList = true
                }
                if let range = Range(match.range(at: 1), in: trimmed) {
                    listItems.append(String(trimmed[range]))
                }
                continue
            } else if inList {
                flushList()
            }

            // 8. 普通段落行
            paragraphLines.append(trimmed)
        }

        // 循环结束清空所有暂存块
        flushParagraph()
        flushList()
        flushBlockquote()
        flushTable()

        if inCodeBlock {
            let codeContent = escapeHTML(codeBlockLines.joined(separator: "\n"))
            html.append("<pre><code>\(codeContent)</code></pre>")
        }

        return html.joined(separator: "\n")
    }

    // MARK: - Inline Parsing (Bold, Italic, Code, Links, Images)

    private static func parseInline(_ text: String) -> String {
        var str = text

        // 1. 行内代码保护 (临时用占位符替代，避免后续被加粗/斜体正则误伤)
        var codeSnippets: [String] = []
        let codePattern = #"`([^`]+)`"#
        if let codeRegex = try? NSRegularExpression(pattern: codePattern) {
            let matches = codeRegex.matches(in: str, range: NSRange(location: 0, length: str.utf16.count))
            for match in matches.reversed() {
                if let fullRange = Range(match.range, in: str),
                   let codeRange = Range(match.range(at: 1), in: str) {
                    let codeText = String(str[codeRange])
                    let placeholder = "§§CODE_\(codeSnippets.count)§§"
                    codeSnippets.append("<code>\(escapeHTML(codeText))</code>")
                    str.replaceSubrange(fullRange, with: placeholder)
                }
            }
        }

        // 2. 图片: ![alt](url)
        let imgPattern = #"!\[([^\]]*)\]\(([^)]+)\)"#
        if let imgRegex = try? NSRegularExpression(pattern: imgPattern) {
            str = imgRegex.stringByReplacingMatches(
                in: str,
                range: NSRange(location: 0, length: str.utf16.count),
                withTemplate: #"<img src="$2" alt="$1" loading="lazy" />"#
            )
        }

        // 3. 超链接: [text](url)
        let linkPattern = #"\[([^\]]+)\]\(([^)]+)\)"#
        if let linkRegex = try? NSRegularExpression(pattern: linkPattern) {
            str = linkRegex.stringByReplacingMatches(
                in: str,
                range: NSRange(location: 0, length: str.utf16.count),
                withTemplate: #"<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>"#
            )
        }

        // 4. 粗斜体: ***text***
        let boldItalicPattern = #"\*\*\*([^*]+)\*\*\*"#
        if let biRegex = try? NSRegularExpression(pattern: boldItalicPattern) {
            str = biRegex.stringByReplacingMatches(
                in: str,
                range: NSRange(location: 0, length: str.utf16.count),
                withTemplate: #"<strong><em>$1</em></strong>"#
            )
        }

        // 5. 粗体: **text** 或 __text__
        let boldPattern = #"\*\*([^*]+)\*\*|__([^_]+)__"#
        if let boldRegex = try? NSRegularExpression(pattern: boldPattern) {
            str = boldRegex.stringByReplacingMatches(
                in: str,
                range: NSRange(location: 0, length: str.utf16.count),
                withTemplate: #"<strong>$1$2</strong>"#
            )
        }

        // 6. 斜体: *text* 或 _text_
        let italicPattern = #"\*([^*]+)\*|_([^_]+)_"#
        if let italicRegex = try? NSRegularExpression(pattern: italicPattern) {
            str = italicRegex.stringByReplacingMatches(
                in: str,
                range: NSRange(location: 0, length: str.utf16.count),
                withTemplate: #"<em>$1$2</em>"#
            )
        }

        // 7. 删除线: ~~text~~
        let strikePattern = #"~~([^~]+)~~"#
        if let strikeRegex = try? NSRegularExpression(pattern: strikePattern) {
            str = strikeRegex.stringByReplacingMatches(
                in: str,
                range: NSRange(location: 0, length: str.utf16.count),
                withTemplate: #"<del>$1</del>"#
            )
        }

        // 8. 快捷键微格式: [[Key]] -> <kbd>Key</kbd>
        let kbdPattern = #"\[\[([^\]]+)\]\]"#
        if let kbdRegex = try? NSRegularExpression(pattern: kbdPattern) {
            str = kbdRegex.stringByReplacingMatches(
                in: str,
                range: NSRange(location: 0, length: str.utf16.count),
                withTemplate: #"<kbd>$1</kbd>"#
            )
        }

        // 9. 还原代码片段
        for (idx, snippet) in codeSnippets.enumerated() {
            str = str.replacingOccurrences(of: "§§CODE_\(idx)§§", with: snippet)
        }

        return str
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: - HTML Template with macOS 26 Typography & Dark Mode CSS

    private static func wrapInHTMLDocument(bodyHTML: String, title: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>\(escapeHTML(title))</title>
        <style>
        :root {
          --bg-color: #ffffff;
          --text-color: #1d1d1f;
          --text-secondary: #6e6e73;
          --border-color: rgba(0, 0, 0, 0.08);
          --table-border: #e5e5e7;
          --table-stripe: #fbfbfd;
          --code-bg: #f5f5f7;
          --code-border: rgba(0, 0, 0, 0.06);
          --accent-color: #0071e3;
          --accent-hover: #0077ed;
          --blockquote-bg: rgba(0, 113, 227, 0.05);
          --blockquote-border: #0071e3;
          --kbd-bg: #f5f5f7;
          --kbd-border: #d2d2d7;
          --hr-color: #e5e5e7;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg-color: #1e1e1e;
            --text-color: #f5f5f7;
            --text-secondary: #a1a1a6;
            --border-color: rgba(255, 255, 255, 0.1);
            --table-border: #38383a;
            --table-stripe: #252528;
            --code-bg: #28282c;
            --code-border: rgba(255, 255, 255, 0.08);
            --accent-color: #2997ff;
            --accent-hover: #47a6ff;
            --blockquote-bg: rgba(41, 151, 255, 0.08);
            --blockquote-border: #2997ff;
            --kbd-bg: #2c2c2e;
            --kbd-border: #48484a;
            --hr-color: #38383a;
          }
        }
        body {
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
          font-size: 14.5px;
          line-height: 1.68;
          color: var(--text-color);
          background-color: var(--bg-color);
          margin: 0;
          padding: 36px 44px;
          max-width: 860px;
          margin-left: auto;
          margin-right: auto;
          word-wrap: break-word;
          -webkit-font-smoothing: antialiased;
        }
        h1, h2, h3, h4, h5, h6 {
          color: var(--text-color);
          font-weight: 600;
          margin-top: 1.5em;
          margin-bottom: 0.6em;
          line-height: 1.3;
        }
        h1 {
          font-size: 26px;
          border-bottom: 1px solid var(--hr-color);
          padding-bottom: 0.3em;
          margin-top: 0.2em;
        }
        h2 {
          font-size: 20px;
          border-bottom: 1px solid var(--border-color);
          padding-bottom: 0.25em;
        }
        h3 { font-size: 16.5px; }
        h4 { font-size: 15px; }
        p { margin-top: 0; margin-bottom: 1em; }
        a {
          color: var(--accent-color);
          text-decoration: none;
        }
        a:hover {
          color: var(--accent-hover);
          text-decoration: underline;
        }
        code {
          font-family: "SF Mono", Menlo, Monaco, Consolas, monospace;
          font-size: 0.88em;
          background-color: var(--code-bg);
          padding: 0.2em 0.4em;
          border-radius: 4px;
          border: 1px solid var(--code-border);
        }
        pre {
          background-color: var(--code-bg);
          border: 1px solid var(--code-border);
          border-radius: 8px;
          padding: 14px 18px;
          overflow-x: auto;
          line-height: 1.5;
          margin: 1em 0;
        }
        pre code {
          background: none;
          border: none;
          padding: 0;
          font-size: 13px;
        }
        blockquote {
          margin: 1em 0;
          padding: 10px 18px;
          border-left: 4px solid var(--blockquote-border);
          background-color: var(--blockquote-bg);
          border-radius: 0 6px 6px 0;
          color: var(--text-color);
        }
        blockquote p:last-child { margin-bottom: 0; }
        table {
          border-collapse: collapse;
          width: 100%;
          margin: 1.2em 0;
          font-size: 13.5px;
        }
        th, td {
          border: 1px solid var(--table-border);
          padding: 8px 14px;
          text-align: left;
        }
        th {
          background-color: var(--code-bg);
          font-weight: 600;
        }
        tr:nth-child(even) {
          background-color: var(--table-stripe);
        }
        ul, ol {
          padding-left: 24px;
          margin: 0.6em 0 1em 0;
        }
        li { margin-bottom: 0.3em; }
        hr {
          border: none;
          border-top: 1px solid var(--hr-color);
          margin: 2em 0;
        }
        kbd {
          display: inline-block;
          padding: 2px 5px;
          font-size: 11px;
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
          line-height: 1.2;
          color: var(--text-color);
          background-color: var(--kbd-bg);
          border: 1px solid var(--kbd-border);
          border-radius: 4px;
          box-shadow: inset 0 -1px 0 var(--kbd-border);
        }
        img {
          max-width: 100%;
          height: auto;
          border-radius: 6px;
          box-shadow: 0 2px 8px rgba(0, 0, 0, 0.12);
          margin: 1em 0;
        }
        input[type="checkbox"] {
          margin-right: 6px;
          vertical-align: middle;
        }
        </style>
        </head>
        <body>
        \(bodyHTML)
        </body>
        </html>
        """
    }
}
