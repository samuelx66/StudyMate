import SwiftUI
import AppKit
import WebKit

/// 帮助手册 HTML 渲染承载组件
public struct StudyMateHelpWebView: NSViewRepresentable {
    let htmlContent: String
    let baseURL: URL?

    public init(htmlContent: String, baseURL: URL?) {
        self.htmlContent = htmlContent
        self.baseURL = baseURL
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground") // 透明底色自适应窗口外观
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        // 当 HTML 内容发生实质变化时重载
        if context.coordinator.lastLoadedHTML != htmlContent {
            context.coordinator.lastLoadedHTML = htmlContent
            webView.loadHTMLString(htmlContent, baseURL: baseURL)
        }
    }

    public final class Coordinator: NSObject, WKNavigationDelegate {
        var lastLoadedHTML: String = ""

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // 若点击的是外部网络链接（http / https），直接呼起系统默认浏览器打开
            if url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }
    }
}

/// 帮助手册原生窗口视图
public struct StudyMateHelpView: View {
    @EnvironmentObject private var languageManager: LanguageManager
    @State private var previewLanguage: AppLanguage = .zh
    @State private var htmlContent: String = ""
    @State private var fileURL: URL? = nil
    @State private var isFileNotFound: Bool = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            if isFileNotFound {
                fileNotFoundView
            } else {
                StudyMateHelpWebView(htmlContent: htmlContent, baseURL: fileURL?.deletingLastPathComponent())
            }
        }
        .frame(minWidth: 620, minHeight: 480)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                // 语言切换控制项
                Picker(selection: $previewLanguage) {
                    Text("简体中文").tag(AppLanguage.zh)
                    Text("English").tag(AppLanguage.en)
                } label: {
                    Label(languageManager.text("文档语言", "Document Language"), systemImage: "globe")
                }
                .pickerStyle(.segmented)
                .help(languageManager.text("切换手册语言（默认与设置-界面语言同步）", "Switch manual language (defaults to UI language)"))

                // 重新加载按钮（支持热刷新本地编辑）
                Button(action: reloadContent) {
                    Image(systemName: "arrow.clockwise")
                }
                .help(languageManager.text("重新加载本地文档", "Reload local markdown document"))

                // 在 Finder 中显示
                Button(action: revealInFinder) {
                    Image(systemName: "folder")
                }
                .disabled(fileURL == nil)
                .help(languageManager.text("在访达中显示源文件", "Reveal markdown file in Finder"))

                // 在外部编辑器中打开
                Button(action: openInDefaultEditor) {
                    Image(systemName: "arrow.up.forward.app")
                }
                .disabled(fileURL == nil)
                .help(languageManager.text("在外部编辑器中打开源文件", "Open file in default editor"))
            }
        }
        .onAppear {
            previewLanguage = languageManager.currentLanguage
            loadDocument()
        }
        .onChange(of: languageManager.currentLanguage) { _, newLang in
            previewLanguage = newLang
            loadDocument()
        }
        .onChange(of: previewLanguage) { _, _ in
            loadDocument()
        }
    }

    private var fileNotFoundView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text(languageManager.text("未找到帮助文件", "Help Document Not Found"))
                .font(.headline)

            let expectedName = previewLanguage == .zh ? "zh_cn.md" : "en.md"
            Text(languageManager.text(
                "请确认本地已创建 ./Documents/\(expectedName)",
                "Please make sure ./Documents/\(expectedName) exists"
            ))
            .font(.callout)
            .foregroundColor(.secondary)

            Button(action: reloadContent) {
                Text(languageManager.text("重试检测", "Retry"))
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func loadDocument() {
        let (rawMarkdown, resolvedURL) = StudyMateHelpResolver.readHelpMarkdown(for: previewLanguage)
        fileURL = resolvedURL

        if resolvedURL == nil {
            isFileNotFound = true
            htmlContent = ""
            return
        }

        isFileNotFound = false
        var markdownToRender = rawMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if markdownToRender.isEmpty {
            markdownToRender = previewLanguage == .zh
                ? "# 学伴使用参考手册\n\n*(文档正在编写中，可编辑本地 `Documents/zh_cn.md` 并点击上方刷新)*"
                : "# StudyMate User Manual\n\n*(Documentation is in progress. Edit `Documents/en.md` and click reload above)*"
        }

        let title = previewLanguage == .zh ? "学伴使用参考手册" : "StudyMate User Manual"
        htmlContent = StudyMateMarkdownParser.toHTML(markdown: markdownToRender, title: title)
    }

    private func reloadContent() {
        loadDocument()
    }

    private func revealInFinder() {
        guard let url = fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func openInDefaultEditor() {
        guard let url = fileURL else { return }
        NSWorkspace.shared.open(url)
    }
}
