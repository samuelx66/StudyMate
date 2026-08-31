import SwiftUI
import AppKit
import AVFoundation

/// NSTextView 不会把 SwiftUI representable 的附加上下文带回选择通知。
/// 将上下文绑定在具体文本视图上，拖动选词时仍能在词典弹窗中显示完整字幕上下文。
private var dictionaryTextContextAssociationKey: UInt8 = 0

/// 统一管理字幕取词状态。这个对象负责选区、浮动操作条和词典弹窗，
/// 仅通过播放器的弱引用在取词期间暂时暂停/恢复，不参与句子选中状态，
/// 因此点击句子仍然保持原有的播放逻辑。
@MainActor
public final class DictionaryInteractionCoordinator: ObservableObject {
    public static let shared = DictionaryInteractionCoordinator()

    @Published public private(set) var selectedText: String?
    @Published public private(set) var contextText: String?
    @Published public private(set) var anchorScreenPoint: NSPoint?
    @Published public private(set) var anchorScreenRect: NSRect?
    @Published public private(set) var isLookupPresented = false

    private weak var activeTextView: NSTextView?
    private weak var playbackEngine: PlaybackEngine?
    private var activePopover: NSPopover?
    private var popoverDelegate: DictionaryPopoverDelegate?
    private var pausedPlaybackForLookup = false
    private var shouldResumePlaybackAfterLookup = false
    private let speechSynthesizer = NSSpeechSynthesizer()
    private let avSynthesizer = AVSpeechSynthesizer()
    private var selectionObserver: NSObjectProtocol?
    private var mouseUpMonitor: Any?
    private var mouseDownMonitor: Any?
    private var keyDownMonitor: Any?

    private init() {
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let textView = notification.object as? NSTextView
            Task { @MainActor [weak self] in
                guard let self, !self.isLookupPresented else { return }
                self.selectionChanged(textView)
            }
        }

        // SwiftUI 的 Text 选择最终由 NSTextView 承载。鼠标松开时再次读取
        // 选区，可以覆盖跨行拖选及系统菜单弹出时通知顺序不同的情况。
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] event in
            let screenPoint = event.locationInWindow
            Task { @MainActor [weak self] in
                guard let self, !self.isLookupPresented else { return }
                if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
                    self.selectionChanged(textView, screenPoint: screenPoint)
                }
            }
            return event
        }

        // 监控鼠标点击：词典弹窗展示时，点击弹窗外部区域自动关闭弹窗
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let eventWindow = event.window
            Task { @MainActor [weak self] in
                guard let self, self.isLookupPresented else { return }
                // 仅当点击发生在词典弹窗窗口外部时关闭弹窗
                if let popoverWindow = self.activePopover?.contentViewController?.view.window,
                   eventWindow !== popoverWindow {
                    self.dismissPopover()
                    self.clearSelectionAndDeselect()
                }
            }
            return event
        }

        // 按 ESC 键取消选择或关闭取词弹窗
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53, self.isLookupPresented || self.selectedText != nil {
                self.dismissPopover()
                self.clearSelectionAndDeselect()
                return nil
            }
            return event
        }
    }

    deinit {
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
        if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
        if let keyDownMonitor { NSEvent.removeMonitor(keyDownMonitor) }
    }

    /// 将媒体播放器绑定到取词协调器。协调器只保存弱引用，避免把播放器
    /// 生命周期耦合到词典窗口；这样视频字幕取词时可以安全地暂停/恢复。
    public func bindPlaybackEngine(_ engine: PlaybackEngine) {
        playbackEngine = engine
    }

    public func updateSelection(
        text: String,
        context: String? = nil,
        screenPoint: NSPoint? = nil,
        screenRect: NSRect? = nil
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            clearSelection()
            return
        }
        selectedText = value
        contextText = context?.trimmingCharacters(in: .whitespacesAndNewlines)
        anchorScreenRect = screenRect
        if let screenPoint {
            anchorScreenPoint = screenPoint
        } else if let screenRect {
            anchorScreenPoint = NSPoint(x: screenRect.midX, y: screenRect.midY)
        } else {
            anchorScreenPoint = NSEvent.mouseLocation
        }
    }

    public func clearSelection() {
        if !isLookupPresented {
            dismissPopover()
        }
        selectedText = nil
        contextText = nil
        anchorScreenPoint = nil
        anchorScreenRect = nil
        resumePlaybackIfNeeded()
    }

    public func clearSelectionAndDeselect() {
        dismissPopover()
        selectedText = nil
        contextText = nil
        anchorScreenPoint = nil
        anchorScreenRect = nil
        isLookupPresented = false
        resumePlaybackIfNeeded()
        if let activeTextView {
            activeTextView.setSelectedRange(NSRange(location: NSNotFound, length: 0))
            if activeTextView.window?.firstResponder === activeTextView {
                activeTextView.window?.makeFirstResponder(nil)
            }
            activeTextView.needsDisplay = true
        }
        activeTextView = nil
    }

    public func lookupSelected() {
        guard let selectedText else { return }
        pausePlaybackIfNeeded()
        isLookupPresented = true
        DictionaryEngine.shared.clearSearch()
        DictionaryEngine.shared.search(query: selectedText, includeDetails: true, immediate: true)
        showNativePopover()
    }

    public func showNativePopover() {
        dismissPopover()

        guard let query = selectedText else { return }

        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true

        let delegate = DictionaryPopoverDelegate(coordinator: self)
        self.popoverDelegate = delegate
        popover.delegate = delegate

        let popoverView = DictionaryLookupPopoverContent(
            query: query,
            context: contextText,
            onPronounce: { [weak self] in self?.speak(query) },
            onCopy: { [weak self] in
                self?.copyDefinition(DictionaryEngine.shared.searchResults)
            },
            onOpenDictionary: { [weak self] in
                self?.openDictionaryWindow(query: query)
            },
            onDismiss: { [weak self] in
                self?.dismissPopover()
                self?.clearSelectionAndDeselect()
            }
        )

        let hostingController = NSHostingController(rootView: popoverView)
        popover.contentViewController = hostingController

        if let textView = activeTextView, textView.window != nil {
            let range = textView.selectedRange()
            var targetRect: NSRect = .zero
            if range.length > 0, range.location != NSNotFound,
               let layoutManager = textView.layoutManager,
               let textContainer = textView.textContainer {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                rect.origin.x += textView.textContainerOrigin.x
                rect.origin.y += textView.textContainerOrigin.y
                targetRect = rect
            } else {
                targetRect = textView.bounds
            }

            popover.show(relativeTo: targetRect, of: textView, preferredEdge: .maxY)
        } else if let window = NSApp.keyWindow ?? NSApp.mainWindow, let contentView = window.contentView {
            var targetRect = NSRect(x: contentView.bounds.midX, y: contentView.bounds.midY, width: 1, height: 1)
            if let screenPoint = anchorScreenPoint {
                let windowPoint = window.convertPoint(fromScreen: screenPoint)
                let pointInView = contentView.convert(windowPoint, from: nil)
                targetRect = NSRect(x: pointInView.x, y: pointInView.y, width: 1, height: 1)
            }
            popover.show(relativeTo: targetRect, of: contentView, preferredEdge: .maxY)
        }

        self.activePopover = popover
    }

    public func dismissPopover() {
        if let popover = activePopover {
            activePopover = nil
            popover.close()
        }
        isLookupPresented = false
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

    public func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        speechSynthesizer.stopSpeaking()
        let started = speechSynthesizer.startSpeaking(trimmed)
        if !started {
            let utterance = AVSpeechUtterance(string: trimmed)
            avSynthesizer.stopSpeaking(at: .immediate)
            avSynthesizer.speak(utterance)
        }
    }

    public func speakSelected() {
        let text = selectedText ?? DictionaryEngine.shared.requestedQuery ?? ""
        speak(text)
    }

    public func copySelected() {
        guard let selectedText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedText, forType: .string)
    }

    public func copyDefinition(_ entries: [StudyMateDictionaryLookup]) {
        let value = entries.map { "\($0.key)\n\(Self.plainTextForDisplay($0.text))" }.joined(separator: "\n\n")
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    public func openDictionaryWindow(query: String? = nil) {
        let targetQuery = query ?? selectedText ?? DictionaryEngine.shared.requestedQuery ?? ""
        if !targetQuery.isEmpty {
            DictionaryEngine.shared.requestLookup(targetQuery)
        }
        NotificationCenter.default.post(name: .studyMateOpenDictionaryWindow, object: nil)
        dismissPopover()
        clearSelectionAndDeselect()
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
            // 当 Popover 正在展示时，不要因为 TextView 失去焦点或选区重置而关闭 Popover
            if !isLookupPresented && selectedText != nil {
                clearSelection()
            }
            return
        }
        activeTextView = textView

        var calculatedScreenPoint: NSPoint?
        var calculatedScreenRect: NSRect?

        let firstRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
        if firstRect.width > 0 && firstRect.height > 0 {
            calculatedScreenRect = firstRect
            calculatedScreenPoint = NSPoint(x: firstRect.midX, y: firstRect.midY)
        } else if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            let rectInWindow = textView.convert(rect, to: nil)
            if let window = textView.window {
                let rectInScreen = window.convertToScreen(rectInWindow)
                calculatedScreenRect = rectInScreen
                calculatedScreenPoint = NSPoint(x: rectInScreen.midX, y: rectInScreen.midY)
            }
        }

        updateSelection(
            text: (textView.string as NSString).substring(with: range),
            context: objc_getAssociatedObject(textView, &dictionaryTextContextAssociationKey) as? String,
            screenPoint: calculatedScreenPoint ?? (screenPoint.flatMap { textView.window?.convertPoint(toScreen: $0) } ?? NSEvent.mouseLocation),
            screenRect: calculatedScreenRect
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

public enum TextDragPhase {
    case started
    case changed(translation: CGSize)
    case ended(translation: CGSize)
}

/// 可选择的字幕文本。
///
/// 这里使用原生 NSTextView，并通过轻量子类补充鼠标进入/离开回调与 Ctrl+拖移支持。
/// 文本容器仍使用 NSTextView(frame:) 创建，保留 AppKit 自带的双击选词、
/// 拖动选短语和选区通知。按住 Ctrl 拖移时将移动字幕位置，不影响普通文本选区。
public struct DictionarySelectableText: NSViewRepresentable {
    public let text: String
    public let font: NSFont
    public let color: NSColor
    public let context: String?
    public let alignment: NSTextAlignment
    public let onHoverChanged: ((Bool) -> Void)?
    public let onSingleClick: (() -> Void)?
    public let onOptionDrag: ((TextDragPhase) -> Void)?

    public init(
        text: String,
        font: NSFont = .systemFont(ofSize: 13),
        color: NSColor = .labelColor,
        context: String? = nil,
        alignment: NSTextAlignment = .left,
        onHoverChanged: ((Bool) -> Void)? = nil,
        onSingleClick: (() -> Void)? = nil,
        onOptionDrag: ((TextDragPhase) -> Void)? = nil
    ) {
        self.text = text
        self.font = font
        self.color = color
        self.context = context
        self.alignment = alignment
        self.onHoverChanged = onHoverChanged
        self.onSingleClick = onSingleClick
        self.onOptionDrag = onOptionDrag
    }

    public final class Coordinator: NSObject {
        var onSingleClick: (() -> Void)?
        var onHoverChanged: ((Bool) -> Void)?
        var onOptionDrag: ((TextDragPhase) -> Void)?

        public init(
            onSingleClick: (() -> Void)? = nil,
            onHoverChanged: ((Bool) -> Void)? = nil,
            onOptionDrag: ((TextDragPhase) -> Void)? = nil
        ) {
            self.onSingleClick = onSingleClick
            self.onHoverChanged = onHoverChanged
            self.onOptionDrag = onOptionDrag
        }

        @objc func handleSingleClick(_ recognizer: NSClickGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onSingleClick?()
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            onSingleClick: onSingleClick,
            onHoverChanged: onHoverChanged,
            onOptionDrag: onOptionDrag
        )
    }

    public func makeNSView(context: Context) -> NSTextView {
        // Use only NSTextView(frame:), which lets AppKit create its standard
        // text container safely on all supported macOS versions.
        let textView = DictionaryTextView(frame: .zero)
        textView.onHoverChanged = context.coordinator.onHoverChanged
        textView.onOptionDrag = context.coordinator.onOptionDrag
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.insertionPointColor = .clear
        textView.focusRingType = .none
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
        context.coordinator.onSingleClick = onSingleClick
        context.coordinator.onHoverChanged = onHoverChanged
        context.coordinator.onOptionDrag = onOptionDrag
        if let dictTextView = textView as? DictionaryTextView {
            dictTextView.onHoverChanged = onHoverChanged
            dictTextView.onOptionDrag = onOptionDrag
        }

        if textView.string != text {
            textView.string = text
            textView.toolTip = text
            textView.menu = contextMenu(for: textView)
        } else if textView.menu == nil {
            textView.menu = contextMenu(for: textView)
        }
        if textView.font != font {
            textView.font = font
        }
        if textView.textColor != color {
            textView.textColor = color
        }
        if textView.alignment != alignment {
            textView.alignment = alignment
        }
        objc_setAssociatedObject(
            textView,
            &dictionaryTextContextAssociationKey,
            self.context,
            .OBJC_ASSOCIATION_COPY_NONATOMIC
        )
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

    /// NSTextView is hosted by AppKit and can sit above SwiftUI's hit-testing
    /// layer. Tracking hover directly on the text view makes the move prompt
    /// reliable for both original and translation subtitles.
    private final class DictionaryTextView: NSTextView {
        var onHoverChanged: ((Bool) -> Void)?
        var onOptionDrag: ((TextDragPhase) -> Void)?
        private var trackingArea: NSTrackingArea?
        private var isOptionDragging = false
        private var dragStartWindowPoint: NSPoint?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func resetCursorRects() {
            if NSEvent.modifierFlags.contains(.option) || NSEvent.modifierFlags.contains(.command) {
                discardCursorRects()
                addCursorRect(bounds, cursor: .openHand)
            } else {
                super.resetCursorRects()
            }
        }

        override func flagsChanged(with event: NSEvent) {
            super.flagsChanged(with: event)
            if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
                NSCursor.openHand.set()
            } else if !isOptionDragging {
                NSCursor.arrow.set()
            }
        }

        override func cursorUpdate(with event: NSEvent) {
            if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
                NSCursor.openHand.set()
            } else {
                super.cursorUpdate(with: event)
            }
        }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
                isOptionDragging = true
                dragStartWindowPoint = event.locationInWindow
                NSCursor.closedHand.push()
                onOptionDrag?(.started)
                return
            }
            isOptionDragging = false
            super.mouseDown(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            if isOptionDragging, let start = dragStartWindowPoint {
                let current = event.locationInWindow
                let translation = CGSize(width: current.x - start.x, height: -(current.y - start.y))
                onOptionDrag?(.changed(translation: translation))
                return
            }
            super.mouseDragged(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            if isOptionDragging, let start = dragStartWindowPoint {
                isOptionDragging = false
                dragStartWindowPoint = nil
                NSCursor.pop()
                let current = event.locationInWindow
                let translation = CGSize(width: current.x - start.x, height: -(current.y - start.y))
                onOptionDrag?(.ended(translation: translation))
                return
            }
            super.mouseUp(with: event)
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChanged?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHoverChanged?(false)
        }
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

/// 选中文字后的轻量操作条子按钮。
@MainActor
private struct DictionaryActionButton: View {
    let title: String
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.09) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

/// 选中文字后的 macOS 原生风格轻量浮动操作条。
@MainActor
public struct DictionarySelectionActionBar: View {
    private let playbackEngine: PlaybackEngine
    @ObservedObject private var coordinator = DictionaryInteractionCoordinator.shared
    @ObservedObject private var lang = LanguageManager.shared

    public init(playbackEngine: PlaybackEngine) {
        self.playbackEngine = playbackEngine
    }

    public var body: some View {
        HStack(spacing: 3) {
            DictionaryActionButton(
                title: lang.text("查词", "Look up"),
                systemImage: "book.fill",
                help: lang.text("在词典气泡中查询此词", "Look up in dictionary popover")
            ) {
                coordinator.bindPlaybackEngine(playbackEngine)
                coordinator.lookupSelected()
            }

            divider

            DictionaryActionButton(
                title: lang.text("播放发音", "Pronounce"),
                systemImage: "speaker.wave.2.fill",
                help: lang.text("朗读当前选中文本", "Speak selected text")
            ) {
                coordinator.speakSelected()
            }

            divider

            DictionaryActionButton(
                title: lang.text("复制", "Copy"),
                systemImage: "doc.on.doc",
                help: lang.text("复制到剪贴板", "Copy to clipboard")
            ) {
                coordinator.copySelected()
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThickMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
        }
        .shadow(color: .black.opacity(0.14), radius: 10, x: 0, y: 4)
        .shadow(color: .black.opacity(0.06), radius: 1, x: 0, y: 1)
        .contextMenu {
            Button(lang.text("查询“\(coordinator.selectedText ?? "")”", "Look up “\(coordinator.selectedText ?? "")”")) {
                coordinator.lookupSelected()
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 0.75, height: 14)
    }
}

/// 主媒体窗口中的选区操作条宿主。
@MainActor
public struct DictionaryLookupOverlay: View {
    private let playbackEngine: PlaybackEngine
    @ObservedObject private var coordinator = DictionaryInteractionCoordinator.shared

    public init(engine: PlaybackEngine) {
        self.playbackEngine = engine
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.clear.allowsHitTesting(false)
                if coordinator.selectedText != nil, !coordinator.isLookupPresented {
                    let pos = actionBarPosition(in: geometry.size)
                    DictionarySelectionActionBar(playbackEngine: playbackEngine)
                        .position(pos)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .allowsHitTesting(true)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: coordinator.selectedText != nil && !coordinator.isLookupPresented)
        }
        .onAppear {
            coordinator.bindPlaybackEngine(playbackEngine)
        }
    }

    private func targetAnchorPosition(in size: CGSize) -> CGPoint {
        guard let screenPoint = coordinator.anchorScreenPoint,
              let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first,
              let contentView = window.contentView else {
            return CGPoint(x: size.width / 2, y: size.height / 2)
        }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let pointInContentView = contentView.convert(windowPoint, from: nil)
        let localX = pointInContentView.x
        let localY = contentView.isFlipped ? pointInContentView.y : (contentView.bounds.height - pointInContentView.y)
        return CGPoint(
            x: min(max(10, localX), size.width - 10),
            y: min(max(10, localY), size.height - 10)
        )
    }

    private func actionBarPosition(in size: CGSize) -> CGPoint {
        let anchor = targetAnchorPosition(in: size)
        return CGPoint(
            x: min(size.width - 120, max(120, anchor.x)),
            y: max(24, anchor.y - 34)
        )
    }
}

@MainActor
private struct DictionaryLookupPopoverContent: View {
    let query: String
    let context: String?
    let onPronounce: () -> Void
    let onCopy: () -> Void
    let onOpenDictionary: () -> Void
    let onDismiss: () -> Void
    @ObservedObject private var engine = DictionaryEngine.shared
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

            if (engine.isSearching || engine.isLoadingDefinition || engine.isBusy) && engine.searchResults.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(0..<5, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(index == 0 ? 0.10 : 0.06))
                            .frame(maxWidth: index == 2 ? 220 : .infinity, minHeight: 11, maxHeight: 11)
                    }
                    Text(lang.text("正在查询词典…", "Looking up dictionaries…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .redacted(reason: .placeholder)
                .padding(.vertical, 8)
            } else if engine.searchResults.isEmpty {
                Text(lang.text("未找到释义", "No definition found"))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                DictionaryHTMLView(
                    entries: engine.searchResults,
                    isCompact: true,
                    onLookupWord: { word in
                        DictionaryEngine.shared.search(query: word, includeDetails: true, immediate: true)
                    },
                    onPlayAudio: { audioKey in
                        DictionaryInteractionCoordinator.shared.speak(audioKey)
                    }
                )
                .frame(height: 240)
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
                Button(lang.text("在词典中打开", "Open in Dictionary"), action: onOpenDictionary)
                Spacer()
                Button(lang.text("关闭", "Close"), action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 390)
    }
}

private final class DictionaryPopoverDelegate: NSObject, NSPopoverDelegate {
    weak var coordinator: DictionaryInteractionCoordinator?

    init(coordinator: DictionaryInteractionCoordinator) {
        self.coordinator = coordinator
    }

    func popoverDidClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, let coordinator = self.coordinator else { return }
            if coordinator.isLookupPresented {
                coordinator.clearSelectionAndDeselect()
            }
        }
    }
}

public extension DictionaryInteractionCoordinator {
    static func plainTextForDisplay(_ value: String) -> String {
        var text = value
        text = text.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<ranks[^>]*>[\\s\\S]*?</ranks>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<div class=\"extras\"[\\s\\S]*?</div>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private extension NSView {
    func ancestor(where predicate: (NSView) -> Bool) -> NSView? {
        var current: NSView? = self
        while let view = current {
            if predicate(view) { return view }
            current = view.superview
        }
        return nil
    }
}
