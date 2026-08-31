import SwiftUI
import AppKit
import AVFoundation

/// 统一管理字幕取词状态。这个对象负责选区、浮动操作条和词典弹窗，
/// 仅通过播放器的弱引用在取词期间暂时暂停/恢复，不参与句子选中状态，
/// 因此点击句子仍然保持原有的播放逻辑。
@MainActor
public final class DictionaryInteractionCoordinator: ObservableObject {
    public static let shared = DictionaryInteractionCoordinator()

    @Published public private(set) var selectedText: String?
    @Published public private(set) var contextText: String?
    @Published public private(set) var anchorScreenPoint: NSPoint?
    @Published public private(set) var isLookupPresented = false
    @Published public var isVideoSelectionMode = false

    private weak var playbackEngine: PlaybackEngine?
    private var pausedPlaybackForLookup = false
    private var shouldResumePlaybackAfterLookup = false
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var selectionObserver: NSObjectProtocol?
    private var mouseUpMonitor: Any?

    private init() {
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.selectionChanged(notification.object as? NSTextView)
            }
        }

        // SwiftUI 的 Text 选择最终由 NSTextView 承载。鼠标松开时再次读取
        // 选区，可以覆盖跨行拖选及系统菜单弹出时通知顺序不同的情况。
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
                self.selectionChanged(textView, screenPoint: event.locationInWindow)
            }
            return event
        }
    }

    deinit {
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
    }

    /// 将媒体播放器绑定到取词协调器。协调器只保存弱引用，避免把播放器
    /// 生命周期耦合到词典窗口；这样视频字幕取词时可以安全地暂停/恢复。
    public func bindPlaybackEngine(_ engine: PlaybackEngine) {
        playbackEngine = engine
    }

    /// 切换视频字幕选词模式。进入模式时暂停正在播放的媒体，退出模式时
    /// 恢复进入模式前的播放状态；原本处于暂停状态的媒体不会被强行播放。
    public func toggleVideoSelectionMode(using engine: PlaybackEngine) {
        bindPlaybackEngine(engine)
        if isVideoSelectionMode {
            isVideoSelectionMode = false
            if !isLookupPresented {
                resumePlaybackIfNeeded()
            }
        } else {
            isVideoSelectionMode = true
            pausePlaybackIfNeeded()
        }
    }

    public func updateSelection(
        text: String,
        context: String? = nil,
        screenPoint: NSPoint? = nil
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            clearSelection()
            return
        }
        selectedText = value
        contextText = context?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let screenPoint {
            anchorScreenPoint = screenPoint
        } else {
            anchorScreenPoint = NSEvent.mouseLocation
        }
    }

    public func clearSelection() {
        selectedText = nil
        contextText = nil
        anchorScreenPoint = nil
        isLookupPresented = false
        resumePlaybackIfNeeded()
    }

    public func lookupSelected() {
        guard let selectedText else { return }
        pausePlaybackIfNeeded()
        isLookupPresented = true
        DictionaryEngine.shared.clearSearch()
        DictionaryEngine.shared.search(query: selectedText)
    }

    /// Control-Command-D 的统一入口：优先使用选区，没有选区时取光标所在单词。
    public func lookupCurrentSelectionOrWord() {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else {
            return
        }
        let range = textView.selectedRange()
        let value: String?
        if range.length > 0 {
            value = (textView.string as NSString).substring(with: range)
        } else {
            value = Self.wordAtCaret(in: textView)
        }
        guard let value else { return }
        updateSelection(text: value, screenPoint: NSEvent.mouseLocation)
        lookupSelected()
    }

    public func speakSelected() {
        guard let selectedText, !selectedText.isEmpty else { return }
        speechSynthesizer.stopSpeaking(at: .immediate)
        speechSynthesizer.speak(AVSpeechUtterance(string: selectedText))
    }

    public func copySelected() {
        guard let selectedText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedText, forType: .string)
    }

    public func copyDefinition(_ entries: [StudyMateDictionaryLookup]) {
        let value = entries.map { "\($0.key)\n\(Self.plainText($0.text))" }.joined(separator: "\n\n")
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    public func openDictionaryWindow() {
        guard let selectedText else { return }
        DictionaryEngine.shared.requestLookup(selectedText)
        NotificationCenter.default.post(name: .studyMateOpenDictionaryWindow, object: nil)
        isLookupPresented = false
        resumePlaybackIfNeeded()
    }

    private func pausePlaybackIfNeeded() {
        guard let playbackEngine else { return }
        if !pausedPlaybackForLookup {
            shouldResumePlaybackAfterLookup = playbackEngine.isPlaying
            pausedPlaybackForLookup = true
        }
        guard playbackEngine.isPlaying else { return }
        playbackEngine.pause()
    }

    private func resumePlaybackIfNeeded() {
        guard pausedPlaybackForLookup else { return }
        let shouldResume = shouldResumePlaybackAfterLookup
        pausedPlaybackForLookup = false
        shouldResumePlaybackAfterLookup = false
        guard shouldResume, playbackEngine?.currentMedia != nil else { return }
        playbackEngine?.play()
    }

    private func selectionChanged(_ textView: NSTextView?, screenPoint: NSPoint? = nil) {
        guard let textView, textView.window?.isKeyWindow == true else { return }
        let range = textView.selectedRange()
        guard range.length > 0, range.location != NSNotFound,
              range.location + range.length <= (textView.string as NSString).length else {
            // NSTextView 会在点击其它控件时发出空选区通知；仅当当前取词层已打开
            // 时清空，避免普通播放点击造成无意义的状态变化。
            if isLookupPresented || selectedText != nil { clearSelection() }
            return
        }
        updateSelection(
            text: (textView.string as NSString).substring(with: range),
            screenPoint: screenPoint.flatMap { textView.window?.convertPoint(toScreen: $0) }
                ?? NSEvent.mouseLocation
        )
    }

    private static func wordAtCaret(in textView: NSTextView) -> String? {
        let string = textView.string as NSString
        guard string.length > 0 else { return nil }
        let caret = min(textView.selectedRange().location, string.length)
        let characterSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'_"))
        var start = caret
        var end = caret
        while start > 0 {
            let scalar = string.character(at: start - 1)
            guard let unicode = UnicodeScalar(scalar), characterSet.contains(unicode) else { break }
            start -= 1
        }
        while end < string.length {
            let scalar = string.character(at: end)
            guard let unicode = UnicodeScalar(scalar), characterSet.contains(unicode) else { break }
            end += 1
        }
        guard end > start else { return nil }
        return string.substring(with: NSRange(location: start, length: end - start))
    }

    private static func plainText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

/// 供媒体窗口和词典窗口共同使用的通知，避免 DictionaryEngine 依赖 SwiftUI 场景。
public extension Notification.Name {
    static let studyMateOpenDictionaryWindow = Notification.Name("StudyMate.OpenDictionaryWindow")
}

/// 可选择的字幕文本。
///
/// 这里使用原生 NSTextView，但不再自定义 NSTextView 子类或调用带有
/// textContainer 参数的初始化器。这样可以保留 AppKit 自带的双击选词、
/// 拖动选短语和选区通知，同时避免 macOS 26 上自定义文本视图初始化时的
/// AppKit 断言。单击回调只负责句子播放，不会阻止文本选区。
public struct DictionarySelectableText: NSViewRepresentable {
    public let text: String
    public let font: NSFont
    public let color: NSColor
    public let context: String?
    public let onSingleClick: (() -> Void)?

    public init(
        text: String,
        font: NSFont = .systemFont(ofSize: 13),
        color: NSColor = .labelColor,
        context: String? = nil,
        onSingleClick: (() -> Void)? = nil
    ) {
        self.text = text
        self.font = font
        self.color = color
        self.context = context
        self.onSingleClick = onSingleClick
    }

    public final class Coordinator: NSObject {
        let onSingleClick: (() -> Void)?

        init(onSingleClick: (() -> Void)?) {
            self.onSingleClick = onSingleClick
        }

        @objc func handleSingleClick(_ recognizer: NSClickGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onSingleClick?()
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onSingleClick: onSingleClick)
    }

    public func makeNSView(context: Context) -> NSTextView {
        // Use only NSTextView(frame:), which lets AppKit create its standard
        // text container safely on all supported macOS versions.
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleClick(_:))
        )
        textView.addGestureRecognizer(click)

        return textView
    }

    public func updateNSView(_ textView: NSTextView, context: Context) {
        if textView.string != text {
            textView.string = text
        }
        textView.font = font
        textView.textColor = color
        textView.alignment = .left
        textView.toolTip = text
        textView.menu = contextMenu(for: textView)
    }

    private func contextMenu(for textView: NSTextView) -> NSMenu {
        let menu = NSMenu()
        let lookup = NSMenuItem(
            title: "查询“\(text)”",
            action: #selector(ContextMenuTarget.lookup(_:)),
            keyEquivalent: ""
        )
        let copy = NSMenuItem(
            title: "复制",
            action: #selector(ContextMenuTarget.copy(_:)),
            keyEquivalent: ""
        )
        let target = ContextMenuTarget(text: text, context: context, textView: textView)
        lookup.target = target
        copy.target = target
        // NSTextView menus retain their target while the view is alive.
        objc_setAssociatedObject(
            textView,
            &ContextMenuTarget.associationKey,
            target,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        menu.addItem(lookup)
        menu.addItem(copy)
        return menu
    }

    @MainActor
    private final class ContextMenuTarget: NSObject {
        static var associationKey = 0
        let text: String
        let context: String?
        weak var textView: NSTextView?

        init(text: String, context: String?, textView: NSTextView?) {
            self.text = text
            self.context = context
            self.textView = textView
        }

        private var selectedValue: String {
            guard let textView else { return text }
            let range = textView.selectedRange()
            guard range.length > 0,
                  range.location != NSNotFound,
                  range.location + range.length <= (textView.string as NSString).length else {
                return text
            }
            return (textView.string as NSString).substring(with: range)
        }

        @objc func lookup(_ sender: Any?) {
            let coordinator = DictionaryInteractionCoordinator.shared
            coordinator.updateSelection(text: selectedValue, context: context, screenPoint: NSEvent.mouseLocation)
            coordinator.lookupSelected()
        }

        @objc func copy(_ sender: Any?) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selectedValue, forType: .string)
        }
    }
}

/// 选中文字后的轻量操作条。
public struct DictionarySelectionActionBar: View {
    private let playbackEngine: PlaybackEngine
    @ObservedObject private var coordinator = DictionaryInteractionCoordinator.shared
    @ObservedObject private var lang = LanguageManager.shared

    public init(playbackEngine: PlaybackEngine) {
        self.playbackEngine = playbackEngine
    }

    public var body: some View {
        HStack(spacing: 2) {
            Button {
                coordinator.bindPlaybackEngine(playbackEngine)
                coordinator.lookupSelected()
            } label: {
                Label(lang.text("查词", "Look up"), systemImage: "book")
            }
            Button { coordinator.speakSelected() } label: {
                Label(lang.text("播放发音", "Pronounce"), systemImage: "speaker.wave.2")
            }
            Button { coordinator.copySelected() } label: {
                Label(lang.text("复制", "Copy"), systemImage: "doc.on.doc")
            }
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        .contextMenu {
            Button(lang.text("查询“\(coordinator.selectedText ?? "")”", "Look up “\(coordinator.selectedText ?? "")”")) {
                coordinator.lookupSelected()
            }
        }
    }
}

/// 主媒体窗口中的选区操作条和词典结果 Popover 宿主。
public struct DictionaryLookupOverlay: View {
    private let playbackEngine: PlaybackEngine
    @ObservedObject private var coordinator = DictionaryInteractionCoordinator.shared
    @ObservedObject private var engine = DictionaryEngine.shared
    @Environment(\.openWindow) private var openWindow

    public init(engine: PlaybackEngine) {
        self.playbackEngine = engine
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.clear.allowsHitTesting(false)
                if coordinator.isLookupPresented, let query = coordinator.selectedText {
                    // 使用 SwiftUI 的原生 popover，而不是把结果面板画在媒体内容
                    // 上；这样箭头、阴影、Esc 关闭和窗口层级都由 macOS 管理。
                    Color.clear
                        .frame(width: 1, height: 1)
                        .position(anchor(in: geometry.size, yOffset: 150))
                        .popover(
                            isPresented: Binding(
                                get: { coordinator.isLookupPresented },
                                set: { if !$0 { coordinator.clearSelection() } }
                            ),
                            attachmentAnchor: .point(.center),
                            arrowEdge: .bottom
                        ) {
                            DictionaryLookupPopoverContent(
                                query: query,
                                context: coordinator.contextText,
                                entries: engine.searchResults,
                                onPronounce: { coordinator.speakSelected() },
                                onCopy: { coordinator.copyDefinition(engine.searchResults) },
                                onOpenDictionary: {
                                    coordinator.openDictionaryWindow()
                                    openWindow(id: "dictionary")
                                },
                                onDismiss: { coordinator.clearSelection() }
                            )
                            .frame(width: 390)
                        }
                        .allowsHitTesting(false)
                } else if coordinator.selectedText != nil {
                    DictionarySelectionActionBar(playbackEngine: playbackEngine)
                        .position(anchor(in: geometry.size, yOffset: 28))
                        .allowsHitTesting(true)
                }
            }
        }
        .onAppear {
            coordinator.bindPlaybackEngine(playbackEngine)
        }
    }

    private func anchor(in size: CGSize, yOffset: CGFloat) -> CGPoint {
        guard let screenPoint = coordinator.anchorScreenPoint,
              let window = NSApp.keyWindow,
              let contentView = window.contentView else {
            return CGPoint(x: size.width / 2, y: yOffset)
        }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let height = contentView.bounds.height
        return CGPoint(
            x: min(size.width - 200, max(200, windowPoint.x)),
            y: min(size.height - 20, max(yOffset, height - windowPoint.y - yOffset))
        )
    }
}

private struct DictionaryLookupPopoverContent: View {
    let query: String
    let context: String?
    let entries: [StudyMateDictionaryLookup]
    let onPronounce: () -> Void
    let onCopy: () -> Void
    let onOpenDictionary: () -> Void
    let onDismiss: () -> Void
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(query)
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(action: onPronounce) {
                    Label(lang.text("播放发音", "Pronounce"), systemImage: "speaker.wave.2.fill")
                }
                .buttonStyle(.borderless)
            }

            Divider()

            if entries.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(lang.text("正在查询词典…", "Looking up dictionaries…"))
                        .foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.dictionaryTitle)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(DictionaryInteractionCoordinator.plainTextForDisplay(entry.text))
                                    .font(.system(size: 13))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .frame(maxHeight: 250)
            }

            if let context, !context.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    Text(lang.text("当前字幕上下文", "Current subtitle context"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(context)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            Divider()
            HStack {
                Button(lang.text("复制释义", "Copy definition"), action: onCopy)
                Button(lang.text("在字典 App 中打开", "Open in Dictionary"), action: onOpenDictionary)
                Spacer()
                Button(lang.text("关闭", "Close"), action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
    }
}

public extension DictionaryInteractionCoordinator {
    static func plainTextForDisplay(_ value: String) -> String {
        value
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
