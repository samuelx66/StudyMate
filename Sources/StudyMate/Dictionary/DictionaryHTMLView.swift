import SwiftUI
import Foundation
import WebKit
import AppKit

/// Formats MDX dictionary lookup entries into clean, adaptive HTML documents
/// tailored for either compact popover presentation or full-window reading.
public enum DictionaryHTMLFormatter {
    private static let bodyCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 32
        return cache
    }()
    private static let documentCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 16
        return cache
    }()

    public static func composeHTML(
        entries: [StudyMateDictionaryLookup],
        isCompact: Bool,
        textScale: CGFloat = 1.0
    ) -> String {
        let cacheKey = markupCacheKey(entries: entries, isCompact: isCompact, textScale: textScale)
        if let cached = documentCache.object(forKey: cacheKey as NSString) {
            return cached as String
        }
        let fontSize = scaledFontSize(isCompact: isCompact, textScale: textScale)
        let lineHeight = isCompact ? "1.45" : "1.6"
        let entrySpacing = isCompact ? "14px" : "22px"
        let padding = isCompact ? "4px 8px 12px 8px" : "16px 20px"

        var customCSSBlocks: [String] = []
        for entry in entries {
            if let css = entry.css, !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !customCSSBlocks.contains(css) {
                customCSSBlocks.append(rewriteCSSResourceReferences(css, resourceRoot: entry.resourceRoot))
            }
        }
        let customCSSText = customCSSBlocks.joined(separator: "\n\n")
        let entriesHTML = composeBodyHTML(entries: entries, isCompact: isCompact)

        let document = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
        :root {
            --bg-color: transparent;
            --text-color: #1c1c1e;
            --secondary-text: #6e6e73;
            --link-color: #0066cc;
            --badge-bg: rgba(0, 0, 0, 0.06);
            --badge-text: #48484a;
            --divider-color: rgba(0, 0, 0, 0.08);
            --selection-bg: rgba(0, 122, 255, 0.25);
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --text-color: #f2f2f7;
                --secondary-text: #98989d;
                --link-color: #2997ff;
                --badge-bg: rgba(255, 255, 255, 0.1);
                --badge-text: #d1d1d6;
                --divider-color: rgba(255, 255, 255, 0.12);
                --selection-bg: rgba(10, 132, 255, 0.35);
            }
            body {
                color: var(--text-color);
            }
        }
        * {
            box-sizing: border-box;
        }
        html, body {
            margin: 0;
            padding: 0;
            background-color: transparent !important;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro", "PingFang SC", "Hiragino Sans GB", "Helvetica Neue", sans-serif;
            font-size: var(--studymate-font-size, \(fontSize));
            line-height: \(lineHeight);
            word-wrap: break-word;
            overflow-wrap: break-word;
            -webkit-user-select: text;
            user-select: text;
            -webkit-text-size-adjust: 100%;
        }
        body {
            padding: \(padding);
        }
        .dict-entry {
            margin-bottom: \(entrySpacing);
        }
        .dict-badge {
            display: inline-block;
            font-size: 11px;
            font-weight: 600;
            color: var(--badge-text);
            background: var(--badge-bg);
            padding: 2px 7px;
            border-radius: 4px;
            margin-bottom: 8px;
            letter-spacing: 0.2px;
        }
        .dict-divider {
            border: none;
            border-top: 1px solid var(--divider-color);
            margin: \(entrySpacing) 0;
        }
        ::selection {
            background: var(--selection-bg);
        }
        </style>
        \(customCSSText.isEmpty ? "" : "<style type=\"text/css\">\n/* MDX Native CSS */\n\(customCSSText)\n</style>")
        </head>
        <body>
        \(entriesHTML)
        </body>
        </html>
        """
        documentCache.setObject(document as NSString, forKey: cacheKey as NSString)
        return document
    }

    public static func scaledFontSize(isCompact: Bool, textScale: CGFloat) -> String {
        // Keep the formatter in sync with the native toolbar controls. The UI
        // exposes 70%...180%; clamping more narrowly made several button
        // presses appear broken at both ends of the range.
        let scale = min(max(textScale, 0.7), 1.8)
        let baseFontSize = isCompact ? 13.0 : 14.5
        return "\(baseFontSize * scale)px"
    }

    /// Stable-in-process signature for the document shell. Body text is not
    /// included, so selecting another key can update only the body.
    public static func shellSignature(
        entries: [StudyMateDictionaryLookup],
        isCompact: Bool
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(isCompact)
        hasher.combine(isCompact ? "1.45" : "1.6")
        hasher.combine(isCompact ? "14px" : "22px")
        hasher.combine(isCompact ? "4px 8px 12px 8px" : "16px 20px")
        for css in entries.compactMap(\.css) {
            hasher.combine(css)
        }
        return hasher.finalize()
    }

    /// Body-only markup used for fast selection changes. The document shell
    /// and dictionary CSS can stay loaded in WebKit while only this fragment
    /// is replaced.
    public static func composeBodyHTML(
        entries: [StudyMateDictionaryLookup],
        isCompact: Bool
    ) -> String {
        let cacheKey = markupCacheKey(entries: entries, isCompact: isCompact, textScale: 1.0)
        if let cached = bodyCache.object(forKey: cacheKey as NSString) {
            return cached as String
        }
        var deferredScripts: [String] = []
        let bodyEntries = entries.map { entry -> String in
            let badgeHTML = entries.count > 1
                ? "<div class=\"dict-badge\">\(escapeHTML(entry.dictionaryTitle))</div>"
                : ""
            let formattedContent = formatEntryContent(
                entry.text,
                resourceRoot: entry.resourceRoot,
                dictionaryID: entry.dictionaryID
            )
            // MDX entries commonly put jQuery and the dictionary controller
            // before the actual entry markup. Executing those tags in-place
            // makes initialization race the HTML parser: LM5Switch.js runs
            // while `.lm5ppbody` and its foldable sections do not exist yet.
            // Keep the vendor-provided script order, but execute all scripts
            // after every selected entry has been parsed.
            let extracted = extractScriptTags(from: formattedContent)
            deferredScripts.append(contentsOf: extracted.scripts)
            return """
            <div class="dict-entry" data-dict-id="\(escapeHTML(entry.dictionaryID))">
                \(badgeHTML)
                <div class="entry-body">
                    \(extracted.html)
                </div>
            </div>
            """
        }.joined(separator: "\n<hr class=\"dict-divider\">\n")
        let body = bodyEntries + deferredScripts.joined()
        bodyCache.setObject(body as NSString, forKey: cacheKey as NSString)
        return body
    }

    private static func markupCacheKey(
        entries: [StudyMateDictionaryLookup],
        isCompact: Bool,
        textScale: CGFloat
    ) -> String {
        var hasher = Hasher()
        hasher.combine(isCompact)
        hasher.combine(Double(textScale))
        for entry in entries {
            hasher.combine(entry.key)
            hasher.combine(entry.text)
            hasher.combine(entry.dictionaryID)
            hasher.combine(entry.dictionaryTitle)
            hasher.combine(entry.css)
            hasher.combine(entry.resourceRoot)
        }
        return String(hasher.finalize())
    }

    private static func formatEntryContent(
        _ raw: String,
        resourceRoot: String?,
        dictionaryID: String?
    ) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("<") && trimmed.contains(">") {
            let withAudio = rewriteSoundReferences(trimmed, dictionaryID: dictionaryID)
            return rewriteResourceReferences(withAudio, resourceRoot: resourceRoot)
        }
        let paragraphs = trimmed.components(separatedBy: "\n\n")
        if paragraphs.count > 1 {
            return paragraphs.map { "<p>\(escapeHTML($0).replacingOccurrences(of: "\n", with: "<br>"))</p>" }.joined()
        } else {
            return "<p>\(escapeHTML(trimmed).replacingOccurrences(of: "\n", with: "<br>"))</p>"
        }
    }

    private struct ScriptExtraction {
        let html: String
        let scripts: [String]
    }

    /// Remove executable script elements from their original MDX position
    /// and return them in source order. A script at the beginning of an MDX
    /// record otherwise executes before the rest of that record has been
    /// parsed into the DOM. Appending the untouched elements to the complete
    /// body preserves vendor code and dependency order while making the DOM
    /// available to initialization code.
    private static func extractScriptTags(from html: String) -> ScriptExtraction {
        let pattern = #"(?is)<script\b[^>]*>.*?</script\s*>|<script\b[^>]*/\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return ScriptExtraction(html: html, scripts: [])
        }
        let source = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else {
            return ScriptExtraction(html: html, scripts: [])
        }

        var content = html
        var scripts: [String] = []
        for match in matches.reversed() {
            scripts.insert(source.substring(with: match.range), at: 0)
            guard let range = Range(match.range, in: content) else { continue }
            content.removeSubrange(range)
        }
        return ScriptExtraction(html: content, scripts: scripts)
    }

    /// Keep the standard `sound://` shape because MDX scripts commonly read
    /// the href, strip that prefix, and call `new Audio(relativePath)`. The
    /// dictionary ID is carried in a fragment, which is ignored by the audio
    /// loader but lets the native navigation callback select the right MDD.
    /// Using a new scheme here would make those scripts turn
    /// `studymate-sound://...` into an invalid relative path.
    private static func rewriteSoundReferences(_ html: String, dictionaryID: String?) -> String {
        guard let dictionaryID, !dictionaryID.isEmpty else { return html }
        let encodedDictionaryID = dictionaryID.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? dictionaryID
        let pattern = #"((?:href|src)\s*=\s*[\"'])(sound:(?://)?)([^\"']+)([\"'])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return html }
        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        var result = html
        for match in matches.reversed() {
            guard match.numberOfRanges == 5 else { continue }
            let key = nsHTML.substring(with: match.range(at: 3))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !key.isEmpty else { continue }
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
            let replacement = nsHTML.substring(with: match.range(at: 1))
                + "sound://\(encodedKey)#studymate-dictionary=\(encodedDictionaryID)"
                + nsHTML.substring(with: match.range(at: 4))
            if let swiftRange = Range(match.range, in: result) {
                result.replaceSubrange(swiftRange, with: replacement)
            }
        }
        return result
    }

    /// MDD records can come from several packages in one result. Rewriting
    /// relative resource attributes here gives each record its own resource
    /// root instead of relying on one global WebKit baseURL.
    private static func rewriteResourceReferences(_ html: String, resourceRoot: String?) -> String {
        guard let resourceRoot else { return html }
        // URL.absoluteString already percent-escapes spaces and unicode path
        // components. Encoding it a second time would turn `%20` into
        // `%2520`, breaking resources whose dictionary path contains spaces.
        let rootURL = URL(fileURLWithPath: resourceRoot).absoluteString
        let prefix = rootURL.hasSuffix("/") ? rootURL : rootURL + "/"
        // Only rewrite attributes that point to embedded resources. A normal
        // `<a href="another-word">` is a dictionary navigation link, not a
        // file, and must remain available to the WebKit navigation delegate.
        let pattern = #"(<(?:img|audio|video|source|script|iframe|embed|object|link|track)\b[^>]*?\b(?:src|href)\s*=\s*[\"'])([^\"']+)([\"'])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return html }
        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        var result = html
        for match in matches.reversed() {
            guard match.numberOfRanges == 4 else { continue }
            let value = nsHTML.substring(with: match.range(at: 2))
            guard shouldRewriteResource(value) else { continue }
            let replacement = nsHTML.substring(with: match.range(at: 1))
                + localResourceURL(value, prefix: prefix)
                + nsHTML.substring(with: match.range(at: 3))
            if let swiftRange = Range(match.range, in: result) {
                result.replaceSubrange(swiftRange, with: replacement)
            }
        }

        // A number of MDX entries attach images or backgrounds at runtime via
        // an inline style attribute. Because the entry is injected as an
        // inline document, those relative URLs otherwise resolve against the
        // generated page instead of the dictionary resource directory.
        let stylePattern = #"(\bstyle\s*=\s*)([\"'])(.*?)(\2)"#
        if let styleRegex = try? NSRegularExpression(pattern: stylePattern, options: [.caseInsensitive]) {
            let styledHTML = result as NSString
            let styleMatches = styleRegex.matches(in: result, range: NSRange(location: 0, length: styledHTML.length))
            for match in styleMatches.reversed() {
                guard match.numberOfRanges == 5 else { continue }
                let value = styledHTML.substring(with: match.range(at: 3))
                let rewritten = rewriteCSSResourceReferences(value, resourceRoot: resourceRoot)
                guard rewritten != value, let swiftRange = Range(match.range, in: result) else { continue }
                let replacement = styledHTML.substring(with: match.range(at: 1))
                    + styledHTML.substring(with: match.range(at: 2))
                    + rewritten
                    + styledHTML.substring(with: match.range(at: 4))
                result.replaceSubrange(swiftRange, with: replacement)
            }
        }

        // Responsive dictionary images commonly use srcset instead of src.
        // Rewrite only the URL token and preserve density/width descriptors.
        let srcSetPattern = #"(<(?:img|source|video)\b[^>]*?\bsrcset\s*=\s*[\"'])([^\"']+)([\"'])"#
        if let srcSetRegex = try? NSRegularExpression(pattern: srcSetPattern, options: [.caseInsensitive]) {
            let srcSetHTML = result as NSString
            let srcSetMatches = srcSetRegex.matches(in: result, range: NSRange(location: 0, length: srcSetHTML.length))
            for match in srcSetMatches.reversed() {
                guard match.numberOfRanges == 4 else { continue }
                let value = srcSetHTML.substring(with: match.range(at: 2))
                let rewritten = rewriteSrcSet(value, prefix: prefix)
                guard rewritten != value, let swiftRange = Range(match.range, in: result) else { continue }
                let replacement = srcSetHTML.substring(with: match.range(at: 1))
                    + rewritten
                    + srcSetHTML.substring(with: match.range(at: 3))
                result.replaceSubrange(swiftRange, with: replacement)
            }
        }
        return result
    }

    private static func rewriteSrcSet(_ value: String, prefix: String) -> String {
        value
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { candidate in
                let parts = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
                guard let first = parts.first else { return String(candidate) }
                let resource = String(first)
                guard shouldRewriteResource(resource) else { return String(candidate) }
                let rewritten = localResourceURL(resource, prefix: prefix)
                if parts.count == 1 { return rewritten }
                return rewritten + " " + String(parts[1])
            }
            .joined(separator: ", ")
    }

    private static func rewriteCSSResourceReferences(_ css: String, resourceRoot: String?) -> String {
        guard let resourceRoot else { return css }
        let rootURL = URL(fileURLWithPath: resourceRoot).absoluteString
        let prefix = rootURL.hasSuffix("/") ? rootURL : rootURL + "/"
        let pattern = #"(url\(\s*[\"']?)([^\)\"']+)([\"']?\s*\))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return css }
        let nsCSS = css as NSString
        let matches = regex.matches(in: css, range: NSRange(location: 0, length: nsCSS.length))
        var result = css
        for match in matches.reversed() {
            let value = nsCSS.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard shouldRewriteResource(value) else { continue }
            let replacement = nsCSS.substring(with: match.range(at: 1))
                + localResourceURL(value, prefix: prefix)
                + nsCSS.substring(with: match.range(at: 3))
            if let swiftRange = Range(match.range, in: result) {
                result.replaceSubrange(swiftRange, with: replacement)
            }
        }
        return result
    }

    private static func shouldRewriteResource(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard !lower.isEmpty, !lower.hasPrefix("#"), !lower.hasPrefix("//") else { return false }

        // Preserve every explicit URL scheme (entry:, sound:, javascript:,
        // mailto:, data:, and vendor-specific schemes). Only relative file
        // references belong under the imported dictionary resource root.
        if let colon = lower.firstIndex(of: ":") {
            let scheme = lower[..<colon]
            let validScheme = !scheme.isEmpty && scheme.enumerated().allSatisfy { index, character in
                if index == 0 { return character.isLetter }
                return character.isLetter || character.isNumber || character == "+" || character == "-" || character == "."
            }
            if validScheme { return false }
        }
        return true
    }

    /// Percent-encode only the local path portion. Cache-busting queries and
    /// SVG fragments must stay URL delimiters; encoding `?`/`#` into the file
    /// name makes otherwise valid MDX resources fail to load.
    private static func localResourceURL(_ value: String, prefix: String) -> String {
        let splitIndex = value.firstIndex { $0 == "?" || $0 == "#" }
        let pathEnd = splitIndex ?? value.endIndex
        var path = String(value[..<pathEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        while path.hasPrefix("/") { path.removeFirst() }
        let suffix = splitIndex.map { String(value[$0...]) } ?? ""
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return prefix + encodedPath + suffix
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// A lightweight, transparent AppKit WebKit view wrapper designed for smooth
/// and responsive dictionary entry rendering in both popovers and full windows.
public struct DictionaryHTMLView: NSViewRepresentable {
    public let html: String
    public let bodyHTML: String
    public let bodySignature: Int
    public let shellSignature: Int
    public let baseURL: URL?
    public let isCompact: Bool
    /// MDX scripts are enabled only for the full dictionary detail pane. The
    /// lookup popover deliberately keeps content JavaScript disabled.
    public let allowsJavaScript: Bool
    public let textScale: CGFloat
    public var onLookupWord: ((String) -> Void)?
    public var onPlayAudio: ((String) -> Void)?
    public var onPlayDictionaryAudio: ((String, String) -> Void)?

    public init(
        html: String,
        baseURL: URL? = nil,
        isCompact: Bool = false,
        allowsJavaScript: Bool = false,
        textScale: CGFloat = 1.0,
        onLookupWord: ((String) -> Void)? = nil,
        onPlayAudio: ((String) -> Void)? = nil,
        onPlayDictionaryAudio: ((String, String) -> Void)? = nil
    ) {
        self.html = html
        self.bodyHTML = DictionaryHTMLView.extractBodyHTML(from: html)
        self.bodySignature = DictionaryHTMLView.signature(self.bodyHTML)
        self.shellSignature = DictionaryHTMLView.signature(DictionaryHTMLView.extractDocumentShell(from: html))
        self.baseURL = baseURL
        self.isCompact = isCompact
        self.allowsJavaScript = allowsJavaScript
        self.textScale = textScale
        self.onLookupWord = onLookupWord
        self.onPlayAudio = onPlayAudio
        self.onPlayDictionaryAudio = onPlayDictionaryAudio
    }

    public init(
        entries: [StudyMateDictionaryLookup],
        baseURL: URL? = nil,
        isCompact: Bool = false,
        allowsJavaScript: Bool = false,
        textScale: CGFloat = 1.0,
        onLookupWord: ((String) -> Void)? = nil,
        onPlayAudio: ((String) -> Void)? = nil,
        onPlayDictionaryAudio: ((String, String) -> Void)? = nil
    ) {
        let resolvedBaseURL = baseURL ?? entries.first.flatMap { entry in
            if let root = entry.resourceRoot {
                return URL(fileURLWithPath: root, isDirectory: true)
            }
            return DictionaryEngine.shared.resourcesURL(for: entry.dictionaryID)
        }
        self.bodyHTML = DictionaryHTMLFormatter.composeBodyHTML(entries: entries, isCompact: isCompact)
        self.html = DictionaryHTMLFormatter.composeHTML(entries: entries, isCompact: isCompact, textScale: textScale)
        self.bodySignature = DictionaryHTMLView.signature(self.bodyHTML)
        self.shellSignature = DictionaryHTMLFormatter.shellSignature(entries: entries, isCompact: isCompact)
        self.baseURL = resolvedBaseURL
        self.isCompact = isCompact
        self.allowsJavaScript = allowsJavaScript
        self.textScale = textScale
        self.onLookupWord = onLookupWord
        self.onPlayAudio = onPlayAudio
        self.onPlayDictionaryAudio = onPlayDictionaryAudio
    }

    private static func extractBodyHTML(from html: String) -> String {
        guard
            let startRange = html.range(of: "<body", options: .caseInsensitive),
            let start = html.range(of: ">", range: startRange.upperBound..<html.endIndex),
            let end = html.range(of: "</body>", options: .caseInsensitive, range: start.upperBound..<html.endIndex)
        else {
            return html
        }
        return String(html[start.upperBound..<end.lowerBound])
    }

    private static func signature(_ value: String) -> Int {
        var hasher = Hasher()
        hasher.combine(value)
        return hasher.finalize()
    }

    /// Returns the document shell with body contents removed. This lets the
    /// coordinator distinguish a cheap result-row update from a real shell
    /// change, such as a definition carrying different MDX CSS.
    private static func extractDocumentShell(from html: String) -> String {
        guard
            let startRange = html.range(of: "<body", options: .caseInsensitive),
            let start = html.range(of: ">", range: startRange.upperBound..<html.endIndex),
            let end = html.range(of: "</body>", options: .caseInsensitive, range: start.upperBound..<html.endIndex)
        else {
            return html
        }
        return String(html[..<start.upperBound]) + String(html[end.lowerBound...])
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = allowsJavaScript
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        context.coordinator.currentHTML = html
        context.coordinator.currentBodyHTML = bodyHTML
        context.coordinator.currentShellSignature = shellSignature
        context.coordinator.currentBodySignature = bodySignature
        context.coordinator.currentBaseURL = baseURL
        context.coordinator.currentAllowsJavaScript = allowsJavaScript
        context.coordinator.currentTextScale = textScale
        context.coordinator.hasLoadedDocument = false
        context.coordinator.loadDocument(in: webView, html: html, baseURL: baseURL)
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        let baseURLChanged = context.coordinator.currentBaseURL != baseURL
        let bodyChanged = context.coordinator.currentBodySignature != bodySignature
        let scaleChanged = context.coordinator.currentTextScale != textScale
        let shellChanged = context.coordinator.currentShellSignature != shellSignature
        let javaScriptPolicyChanged = context.coordinator.currentAllowsJavaScript != allowsJavaScript

        if baseURLChanged || shellChanged || javaScriptPolicyChanged ||
            (!context.coordinator.hasLoadedDocument && context.coordinator.currentHTML != html) ||
            (allowsJavaScript && bodyChanged) {
            context.coordinator.updateRevision &+= 1
            context.coordinator.currentHTML = html
            context.coordinator.currentBodyHTML = bodyHTML
            context.coordinator.currentShellSignature = shellSignature
            context.coordinator.currentBodySignature = bodySignature
            context.coordinator.currentBaseURL = baseURL
            context.coordinator.currentAllowsJavaScript = allowsJavaScript
            context.coordinator.currentTextScale = textScale
            context.coordinator.hasLoadedDocument = false
            context.coordinator.loadDocument(in: webView, html: html, baseURL: baseURL)
        } else if bodyChanged || scaleChanged {
            context.coordinator.currentHTML = html
            context.coordinator.currentBodyHTML = bodyHTML
            context.coordinator.currentShellSignature = shellSignature
            context.coordinator.currentBodySignature = bodySignature
            context.coordinator.currentTextScale = textScale
            context.coordinator.currentAllowsJavaScript = allowsJavaScript
            context.coordinator.updateRevision &+= 1
            if allowsJavaScript {
                // Body changes in script-enabled definitions are handled by
                // the full reload branch above. A scale-only change should
                // preserve scroll position and script state.
                context.coordinator.updateTextScale(
                    in: webView,
                    fontSize: DictionaryHTMLFormatter.scaledFontSize(
                        isCompact: isCompact,
                        textScale: textScale
                    )
                )
            } else {
                context.coordinator.updateDocument(
                    in: webView,
                    bodyHTML: bodyHTML,
                    fontSize: DictionaryHTMLFormatter.scaledFontSize(isCompact: isCompact, textScale: textScale),
                    reloadHTML: html,
                    revision: context.coordinator.updateRevision
                )
            }
        }
    }

    public static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        coordinator.removeRenderedDocument()
    }

    public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: DictionaryHTMLView
        var currentHTML: String = ""
        var currentBodyHTML: String = ""
        var currentShellSignature: Int = 0
        var currentBodySignature: Int = 0
        var currentBaseURL: URL?
        var currentAllowsJavaScript = false
        var currentTextScale: CGFloat = 1.0
        var hasLoadedDocument = false
        var updateRevision: UInt64 = 0
        private var renderedDocumentURL: URL?

        init(parent: DictionaryHTMLView) {
            self.parent = parent
        }

        deinit {
            removeRenderedDocument()
        }

        /// Load dictionary HTML as a real local file instead of an in-memory
        /// HTML string. `loadHTMLString(_:baseURL:)` resolves the page URL,
        /// but it does not reliably grant the WebKit content process read
        /// access to sibling local `script`/`link` resources in a sandboxed
        /// macOS app. CSS that is already inlined can therefore look correct
        /// while the dictionary controller JavaScript never loads.
        ///
        /// The generated file is kept in a private sibling directory of the
        /// imported dictionaries. `loadFileURL` then receives only that
        /// dictionaries directory as its read scope, so local MDX resources
        /// work without exposing an unrestricted filesystem scope.
        func loadDocument(
            in webView: WKWebView,
            html: String,
            baseURL: URL?
        ) {
            guard let baseURL, baseURL.isFileURL else {
                webView.loadHTMLString(html, baseURL: baseURL)
                return
            }

            let resourceDirectory = baseURL.standardizedFileURL
            let accessDirectory = resourceDirectory
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let renderDirectory = accessDirectory.appendingPathComponent(
                ".studymate-web",
                isDirectory: true
            )

            do {
                try FileManager.default.createDirectory(
                    at: renderDirectory,
                    withIntermediateDirectories: true
                )
                let documentURL = renderDirectory.appendingPathComponent(
                    "dictionary-\(UUID().uuidString).html"
                )
                let documentHTML = htmlWithBaseURL(html, baseURL: resourceDirectory)
                try documentHTML.write(to: documentURL, atomically: true, encoding: .utf8)

                let previousDocumentURL = renderedDocumentURL
                renderedDocumentURL = documentURL
                if let previousDocumentURL {
                    try? FileManager.default.removeItem(at: previousDocumentURL)
                }

                webView.loadFileURL(
                    documentURL,
                    allowingReadAccessTo: accessDirectory
                )
            } catch {
                // Keep the existing in-memory path as a defensive fallback
                // for read-only or unusual custom resource locations.
                webView.loadHTMLString(html, baseURL: baseURL)
            }
        }

        private func htmlWithBaseURL(_ html: String, baseURL: URL) -> String {
            if html.range(of: "<base\\b", options: .regularExpression) != nil {
                return html
            }
            let href = (baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/")
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            let baseTag = "<base href=\"\(href)\">\n"
            guard let headStart = html.range(of: "<head", options: .caseInsensitive),
                  let headEnd = html.range(of: ">", range: headStart.upperBound..<html.endIndex)
            else {
                return html
            }
            return String(html[..<headEnd.upperBound]) + "\n" + baseTag + String(html[headEnd.upperBound...])
        }

        func removeRenderedDocument() {
            guard let renderedDocumentURL else { return }
            try? FileManager.default.removeItem(at: renderedDocumentURL)
            self.renderedDocumentURL = nil
        }

        func updateDocument(
            in webView: WKWebView,
            bodyHTML: String,
            fontSize: String,
            reloadHTML: String,
            revision: UInt64
        ) {
            let script = """
            if (document.body) { document.body.innerHTML = bodyHTML; }
            document.documentElement.style.setProperty('--studymate-font-size', fontSize);
            true;
            """
            // Pass the fragment as a WebKit argument rather than base64
            // encoding it into a new JavaScript source string. This avoids a
            // second full-sized copy and keeps the main thread responsive for
            // large HTML dictionary records.
            webView.callAsyncJavaScript(
                script,
                arguments: ["bodyHTML": bodyHTML, "fontSize": fontSize],
                in: nil,
                in: .page
            ) { [weak self, weak webView] result in
                guard let self, let webView else { return }
                if case .failure = result {
                    DispatchQueue.main.async {
                        guard self.updateRevision == revision else { return }
                        self.hasLoadedDocument = false
                        self.loadDocument(in: webView, html: reloadHTML, baseURL: self.currentBaseURL)
                    }
                }
            }
        }

        func updateTextScale(in webView: WKWebView, fontSize: String) {
            webView.callAsyncJavaScript(
                "document.documentElement.style.setProperty('--studymate-font-size', fontSize); true;",
                arguments: ["fontSize": fontSize],
                in: nil,
                in: .page
            )
        }

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let scheme = url.scheme?.lowercased() ?? ""

            if scheme == "sound" {
                // `sound://audio/cat.mp3` stores `audio` in host and the
                // remainder in path. Joining both is required for WebKit
                // navigation and also matches the path used by MDX scripts.
                let audioResource = (url.host ?? "") + url.path
                let cleanAudio = audioResource.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if let fragment = url.fragment,
                   fragment.hasPrefix("studymate-dictionary=") {
                    let dictionaryID = String(fragment.dropFirst("studymate-dictionary=".count))
                        .removingPercentEncoding ?? String(fragment.dropFirst("studymate-dictionary=".count))
                    if !dictionaryID.isEmpty, !cleanAudio.isEmpty {
                        if let onPlayDictionaryAudio = parent.onPlayDictionaryAudio {
                            onPlayDictionaryAudio(dictionaryID, cleanAudio)
                        } else {
                            DictionaryInteractionCoordinator.shared.playDictionaryAudio(
                                dictionaryID: dictionaryID,
                                key: cleanAudio
                            )
                        }
                    }
                } else {
                    parent.onPlayAudio?(cleanAudio)
                }
                decisionHandler(.cancel)
                return
            }

            if scheme == "studymate-sound" {
                let dictionaryID = url.host ?? ""
                let cleanAudio = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    .removingPercentEncoding ?? url.path
                if !dictionaryID.isEmpty, !cleanAudio.isEmpty {
                    if let onPlayDictionaryAudio = parent.onPlayDictionaryAudio {
                        onPlayDictionaryAudio(dictionaryID, cleanAudio)
                    } else {
                        DictionaryInteractionCoordinator.shared.playDictionaryAudio(
                            dictionaryID: dictionaryID,
                            key: cleanAudio
                        )
                    }
                }
                decisionHandler(.cancel)
                return
            }

            if scheme == "entry" || scheme == "lookup" {
                let word = url.host ?? url.path
                let cleanWord = word.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if let decoded = cleanWord.removingPercentEncoding, !decoded.isEmpty {
                    parent.onLookupWord?(decoded)
                } else if !cleanWord.isEmpty {
                    parent.onLookupWord?(cleanWord)
                }
                decisionHandler(.cancel)
                return
            }

            if scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            // MDX controls often use javascript: links for expand/collapse,
            // pronunciation and view switching. Let WebKit execute these
            // actions instead of misinterpreting the script text as a lookup
            // candidate in the generic link branch below.
            if scheme == "javascript" || scheme == "data" || scheme == "blob" || scheme == "about" {
                decisionHandler(.allow)
                return
            }

            let isLocalDictionaryLink: Bool
            if scheme == "file", let baseURL = parent.baseURL {
                let basePath = baseURL.standardizedFileURL.path
                isLocalDictionaryLink = url.standardizedFileURL.path.hasPrefix(
                    basePath.hasSuffix("/") ? basePath : basePath + "/"
                )
            } else {
                isLocalDictionaryLink = false
            }

            if navigationAction.navigationType == .linkActivated,
               isLocalDictionaryLink {
                let candidate = url.lastPathComponent
                if let decoded = candidate.removingPercentEncoding, !decoded.isEmpty {
                    parent.onLookupWord?(decoded)
                    decisionHandler(.cancel)
                    return
                }
            }

            decisionHandler(.allow)
        }

        // Native MDX scripts occasionally call alert/confirm/prompt. Without
        // a UI delegate WebKit silently drops these dialogs, which can leave
        // a dictionary control waiting for a result. Bridge them to the
        // normal macOS alert presentation while keeping the dictionary page
        // itself in WebKit.
        public func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "好")
            present(alert, in: webView) { _ in completionHandler() }
        }

        public func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "确定")
            alert.addButton(withTitle: "取消")
            present(alert, in: webView) { response in
                completionHandler(response == .alertFirstButtonReturn)
            }
        }

        public func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = prompt
            alert.addButton(withTitle: "确定")
            alert.addButton(withTitle: "取消")
            let input = NSTextField(string: defaultText ?? "")
            input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
            alert.accessoryView = input
            present(alert, in: webView) { response in
                completionHandler(response == .alertFirstButtonReturn ? input.stringValue : nil)
            }
        }

        public func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // Keep popup windows from escaping the dictionary window. Links
            // opened by a user gesture still receive the same lookup/audio or
            // external-link handling as the main WebKit view.
            guard let url = navigationAction.request.url else { return nil }
            handleNewWindowURL(url)
            return nil
        }

        private func present(
            _ alert: NSAlert,
            in webView: WKWebView,
            completion: @escaping (NSApplication.ModalResponse) -> Void
        ) {
            guard let window = webView.window else {
                completion(alert.runModal())
                return
            }
            alert.beginSheetModal(for: window, completionHandler: completion)
        }

        private func handleNewWindowURL(_ url: URL) {
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
                return
            }
            if scheme == "entry" || scheme == "lookup" {
                let word = (url.host ?? url.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if let decoded = word.removingPercentEncoding, !decoded.isEmpty {
                    parent.onLookupWord?(decoded)
                }
                return
            }
            if scheme == "file", let baseURL = parent.baseURL {
                let basePath = baseURL.standardizedFileURL.path
                let isLocal = url.standardizedFileURL.path.hasPrefix(
                    basePath.hasSuffix("/") ? basePath : basePath + "/"
                )
                if isLocal {
                    let candidate = url.lastPathComponent
                    if let decoded = candidate.removingPercentEncoding, !decoded.isEmpty {
                        parent.onLookupWord?(decoded)
                    }
                }
            }
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            hasLoadedDocument = true
        }
    }
}
