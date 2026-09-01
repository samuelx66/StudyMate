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
        let body = entries.map { entry -> String in
            let badgeHTML = entries.count > 1
                ? "<div class=\"dict-badge\">\(escapeHTML(entry.dictionaryTitle))</div>"
                : ""
            let contentHTML = formatEntryContent(
                entry.text,
                resourceRoot: entry.resourceRoot,
                dictionaryID: entry.dictionaryID
            )
            return """
            <div class="dict-entry" data-dict-id="\(escapeHTML(entry.dictionaryID))">
                \(badgeHTML)
                <div class="entry-body">
                    \(contentHTML)
                </div>
            </div>
            """
        }.joined(separator: "\n<hr class=\"dict-divider\">\n")
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

    /// MDD audio links are kept as a custom URL so WebKit can report both the
    /// dictionary package and the resource key. The old `sound:` callback only
    /// exposed the key, which caused the UI to read the filename aloud instead
    /// of playing the pronunciation stored in the dictionary.
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
                + "studymate-sound://\(encodedDictionaryID)/\(encodedKey)"
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
        let pattern = #"((?:src|href)\s*=\s*[\"'])([^\"']+)([\"'])"#
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
        return result
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
        webView.loadHTMLString(html, baseURL: baseURL)
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
            webView.loadHTMLString(html, baseURL: baseURL)
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
        webView.stopLoading()
    }

    public final class Coordinator: NSObject, WKNavigationDelegate {
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

        init(parent: DictionaryHTMLView) {
            self.parent = parent
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
                        webView.loadHTMLString(reloadHTML, baseURL: self.currentBaseURL)
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
                let audioResource = url.host ?? url.path
                let cleanAudio = audioResource.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                parent.onPlayAudio?(cleanAudio)
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

            if navigationAction.navigationType == .linkActivated && scheme != "file" && scheme != "about" {
                let candidate = url.lastPathComponent
                if !candidate.isEmpty {
                    parent.onLookupWord?(candidate)
                    decisionHandler(.cancel)
                    return
                }
            }

            decisionHandler(.allow)
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            hasLoadedDocument = true
        }
    }
}
