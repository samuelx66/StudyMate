import SwiftUI
import WebKit
import AppKit

/// Formats MDX dictionary lookup entries into clean, adaptive HTML documents
/// tailored for either compact popover presentation or full-window reading.
public enum DictionaryHTMLFormatter {
    public static func composeHTML(
        entries: [StudyMateDictionaryLookup],
        isCompact: Bool
    ) -> String {
        let fontSize = isCompact ? "13px" : "14.5px"
        let lineHeight = isCompact ? "1.45" : "1.6"
        let entrySpacing = isCompact ? "14px" : "22px"
        let padding = isCompact ? "4px 8px 12px 8px" : "16px 20px"

        let entriesHTML = entries.map { entry -> String in
            let badgeHTML = entries.count > 1
                ? "<div class=\"dict-badge\">\(escapeHTML(entry.dictionaryTitle))</div>"
                : ""
            let contentHTML = formatEntryContent(entry.text)
            return """
            <div class="dict-entry">
                \(badgeHTML)
                <div class="entry-body">
                    \(contentHTML)
                </div>
            </div>
            """
        }.joined(separator: "\n<hr class=\"dict-divider\">\n")

        return """
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
            --example-color: #555555;
            --phonetic-color: #8e8e93;
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
                --example-color: #b0b0b5;
                --phonetic-color: #a1a1a6;
                --selection-bg: rgba(10, 132, 255, 0.35);
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
            font-size: \(fontSize);
            line-height: \(lineHeight);
            color: var(--text-color);
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
        .entry-body {
            color: var(--text-color);
        }
        a {
            color: var(--link-color);
            text-decoration: none;
        }
        a:hover {
            text-decoration: underline;
        }
        img {
            max-width: 100%;
            height: auto;
            border-radius: 4px;
        }
        table {
            border-collapse: collapse;
            max-width: 100%;
            margin: 6px 0;
        }
        th, td {
            padding: 4px 8px;
            border: 1px solid var(--divider-color);
        }
        p {
            margin: 0.4em 0;
        }
        ul, ol {
            margin: 0.4em 0;
            padding-left: 1.4em;
        }
        li {
            margin-bottom: 0.25em;
        }
        ::selection {
            background: var(--selection-bg);
        }
        </style>
        </head>
        <body>
        \(entriesHTML)
        </body>
        </html>
        """
    }

    private static func formatEntryContent(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // If the entry already contains standard HTML tags, return it directly
        if trimmed.contains("<") && trimmed.contains(">") {
            return trimmed
        }
        // Plain text format: convert double line breaks to paragraphs
        let paragraphs = trimmed.components(separatedBy: "\n\n")
        if paragraphs.count > 1 {
            return paragraphs.map { "<p>\(escapeHTML($0).replacingOccurrences(of: "\n", with: "<br>"))</p>" }.joined()
        } else {
            return "<p>\(escapeHTML(trimmed).replacingOccurrences(of: "\n", with: "<br>"))</p>"
        }
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
    public let isCompact: Bool
    public var onLookupWord: ((String) -> Void)?
    public var onPlayAudio: ((String) -> Void)?

    public init(
        html: String,
        isCompact: Bool = false,
        onLookupWord: ((String) -> Void)? = nil,
        onPlayAudio: ((String) -> Void)? = nil
    ) {
        self.html = html
        self.isCompact = isCompact
        self.onLookupWord = onLookupWord
        self.onPlayAudio = onPlayAudio
    }

    public init(
        entries: [StudyMateDictionaryLookup],
        isCompact: Bool = false,
        onLookupWord: ((String) -> Void)? = nil,
        onPlayAudio: ((String) -> Void)? = nil
    ) {
        self.html = DictionaryHTMLFormatter.composeHTML(entries: entries, isCompact: isCompact)
        self.isCompact = isCompact
        self.onLookupWord = onLookupWord
        self.onPlayAudio = onPlayAudio
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = .clear
        }
        context.coordinator.currentHTML = html
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.currentHTML != html {
            context.coordinator.currentHTML = html
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    public static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    public final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: DictionaryHTMLView
        var currentHTML: String = ""

        init(parent: DictionaryHTMLView) {
            self.parent = parent
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

            if scheme == "entry" {
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

            decisionHandler(.allow)
        }
    }
}
