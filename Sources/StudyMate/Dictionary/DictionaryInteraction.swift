import SwiftUI
import AppKit
import AVFoundation
import OSLog

/// NSTextView 不会把 SwiftUI representable 的附加上下文带回选择通知。
/// 将上下文绑定在具体文本视图上，拖动选词时仍能在词典弹窗中显示完整字幕上下文。
private var dictionaryTextContextAssociationKey: UInt8 = 0
/// Marks the NSTextView instances created by DictionarySelectableText. The
/// coordinator observes AppKit's global selection notification, so without a
/// marker a selection in a settings/search field could incorrectly open the
/// subtitle lookup HUD.
private var dictionarySelectableTextMarkerKey: UInt8 = 0

/// Reports a SwiftUI-hosted control's frame in AppKit's window coordinate
/// space. `GeometryProxy.frame(in: .global)` uses a different coordinate
/// system on macOS, which made the global mouse monitor dismiss the action bar
/// before its own button could receive the click.
private struct DictionaryActionBarFrameReader: NSViewRepresentable {
    let onChange: (NSRect?) -> Void

    func makeNSView(context: Context) -> DictionaryActionBarFrameReportingView {
        let view = DictionaryActionBarFrameReportingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: DictionaryActionBarFrameReportingView, context: Context) {
        nsView.onChange = onChange
        nsView.reportFrame()
    }
}

private final class DictionaryActionBarFrameReportingView: NSView {
    var onChange: ((NSRect?) -> Void)?
    private var lastFrame: NSRect?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportFrame()
    }

    override func layout() {
        super.layout()
        reportFrame()
    }

    func reportFrame() {
        guard window != nil else {
            guard lastFrame != nil else { return }
            lastFrame = nil
            onChange?(nil)
            return
        }
        let frame = convert(bounds, to: nil)
        guard lastFrame != frame else { return }
        lastFrame = frame
        onChange?(frame)
    }
}

/// 统一管理字幕取词状态。这个对象负责选区、浮动操作条和词典弹窗，
/// 仅通过播放器的弱引用在视频字幕取词期间暂时暂停/恢复，不参与句子选中状态，
/// 因此点击句子仍然保持原有的播放逻辑。
@MainActor
public final class DictionaryInteractionCoordinator: ObservableObject {
    public static let shared = DictionaryInteractionCoordinator()

    private static let dictionaryAudioLogger = Logger(
        subsystem: "com.samuel.StudyMate",
        category: "dictionary-audio"
    )

    @Published public private(set) var selectedText: String?
    @Published public private(set) var contextText: String?
    @Published public private(set) var anchorScreenPoint: NSPoint?
    @Published public private(set) var anchorScreenRect: NSRect?
    @Published public private(set) var isLookupPresented = false
    public var actionBarFrameInWindow: NSRect?

    fileprivate weak var activeTextView: NSTextView?
    private weak var playbackEngine: PlaybackEngine?
    private var activePopover: NSPopover?
    private var popoverDelegate: DictionaryPopoverDelegate?
    private var pausedPlaybackForDictionaryInteraction = false
    private var shouldResumePlaybackAfterDictionaryInteraction = false
    private let avSynthesizer = AVSpeechSynthesizer()
    private var dictionaryAudioTask: Task<Void, Never>?
    private var dictionaryAudioPlayer: AVAudioPlayer?
    private var audioGeneration: UInt64 = 0
    private var selectionObserver: NSObjectProtocol?
    private var mouseUpMonitor: Any?
    private var mouseDownMonitor: Any?
    private var keyDownMonitor: Any?
    /// Selection notifications arrive for every mouse-moved glyph while a
    /// phrase is being dragged. Coalesce them to one update per run loop so
    /// the floating action bar and its geometry are not rebuilt dozens of
    /// times per second.
    private var selectionUpdateTask: Task<Void, Never>?
    private weak var pendingSelectionTextView: NSTextView?

    private init() {
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let textView = notification.object as? NSTextView,
                  Self.isDictionarySelectableTextView(textView) else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.isLookupPresented else { return }
                self.scheduleSelectionUpdate(for: textView)
            }
        }

        // SwiftUI 的 Text 选择最终由 NSTextView 承载。鼠标松开时再次读取
        // 选区，可以覆盖跨行拖选及系统菜单弹出时通知顺序不同的情况。
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] event in
            let screenPoint = event.window?.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin ?? NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                guard let self, !self.isLookupPresented else { return }
                if let textView = self.currentSelectionTextView {
                    self.flushSelectionUpdate(for: textView, screenPoint: screenPoint)
                }
            }
            return event
        }

        // 监控鼠标点击：
        // 1. 词典气泡弹窗展示时，点击弹窗外部区域自动关闭弹窗。
        // 2. 仅显示选词浮动操作条（查词 | 发音 | 生词本）时，点击操作条外部区域自动消除操作条。
        // 在当前事件中同步清掉旧选区，同时允许事件自然穿透分发给被点击的底层控件。
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { @MainActor [weak self] event in
            guard let self else { return event }
            let eventWindow = event.window

            if self.isLookupPresented {
                if let popoverAtEvent = self.activePopover,
                   let popoverWindow = popoverAtEvent.contentViewController?.view.window,
                   eventWindow === popoverWindow {
                    return event
                }
                self.clearSelectionAndDeselect()
                return event
            }

            if self.selectedText != nil {
                let mouseInWindow = event.locationInWindow
                let targetWindow = self.activeTextView?.window ?? NSApp.keyWindow ?? NSApp.mainWindow
                if let barFrame = self.actionBarFrameInWindow,
                   eventWindow === targetWindow || eventWindow == nil {
                    // 预留 6pt 点击容差，避免点在操作条胶囊边缘缝隙时误触关闭
                    if barFrame.insetBy(dx: -6, dy: -6).contains(mouseInWindow) {
                        return event
                    }
                }
                self.clearSelectionAndDeselect()
                return event
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
        selectionUpdateTask?.cancel()
        dictionaryAudioTask?.cancel()
        dictionaryAudioPlayer?.stop()
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
        let value = DictionaryEngine.cleanQueryWord(text)
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
        // 静默预取释义，用户移动鼠标点击“查词”时实现 0ms 秒开
        let targetDictionaryID = DictionarySourceSettings.shared.lookupScopeDictionaryID
        DictionaryEngine.shared.prefetchDefinition(for: value, dictionaryID: targetDictionaryID)
    }

    public func clearSelection() {
        cancelPendingSelectionUpdate()
        if !isLookupPresented {
            dismissPopover()
        }
        selectedText = nil
        contextText = nil
        anchorScreenPoint = nil
        anchorScreenRect = nil
        actionBarFrameInWindow = nil
        activeTextView = nil
        resumePlaybackIfNeeded()
    }

    public func clearSelectionAndDeselect(resumePlayback: Bool = true) {
        cancelPendingSelectionUpdate()
        dismissPopover()
        selectedText = nil
        contextText = nil
        anchorScreenPoint = nil
        anchorScreenRect = nil
        actionBarFrameInWindow = nil
        isLookupPresented = false
        if resumePlayback {
            resumePlaybackIfNeeded()
        }
        if let activeTextView {
            // NSNotFound is not a valid insertion point for NSTextView and
            // can make AppKit attempt an invalid layout update on the next
            // selection event. Collapse to the end of the current string.
            let end = (activeTextView.string as NSString).length
            activeTextView.setSelectedRange(NSRange(location: end, length: 0))
            if activeTextView.window?.firstResponder === activeTextView {
                activeTextView.window?.makeFirstResponder(nil)
            }
            activeTextView.needsDisplay = true
        }
        activeTextView = nil
    }

    public func lookupSelected() {
        guard let selectedText else { return }
        pausePlaybackForDictionaryInteractionIfNeeded()
        DictionaryEngine.shared.clearSearch()
        let targetDictionaryID = DictionarySourceSettings.shared.lookupScopeDictionaryID
        DictionaryEngine.shared.search(
            query: selectedText,
            dictionaryID: targetDictionaryID,
            includeDetails: true,
            immediate: true
        )
        showNativePopover()
    }

    /// 视频字幕双击选词时暂停当前媒体。播放前的状态会被记录，
    /// 供选区操作条或词典气泡消失后恢复；如果双击前本来就是暂停状态，
    /// 则不会在交互结束后错误地启动播放。
    public func pausePlaybackForVideoSubtitleSelection() {
        pausePlaybackForDictionaryInteractionIfNeeded()
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
            onLookupWord: { [weak self] word in
                guard let self else { return }
                self.updateSelection(text: word, context: self.contextText)
                let targetDictionaryID = DictionarySourceSettings.shared.lookupScopeDictionaryID
                DictionaryEngine.shared.search(
                    query: word,
                    dictionaryID: targetDictionaryID,
                    includeDetails: true,
                    immediate: true
                )
            },
            onPronounce: { [weak self] word in self?.speakPreferred(word) },
            onToggleVocabulary: { [weak self] word in
                guard let self else { return }
                self.updateSelection(text: word, context: self.contextText)
                self.toggleVocabulary(word: word, exampleSentence: self.contextText ?? "")
            },
            onOpenDictionary: { [weak self] word in
                self?.openDictionaryWindow(query: word)
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

            let viewHeight = textView.bounds.height
            // 在 flipped 视图中，Y 从上往下增加；当文字位于视图下半区（>58%）时向上展开（.minY），否则向下展开（.maxY）
            let preferredEdge: NSRectEdge = textView.isFlipped
                ? (targetRect.midY > viewHeight * 0.58 ? .minY : .maxY)
                : (targetRect.midY < viewHeight * 0.42 ? .maxY : .minY)
            popover.show(relativeTo: targetRect, of: textView, preferredEdge: preferredEdge)
        } else if let window = NSApp.keyWindow ?? NSApp.mainWindow, let contentView = window.contentView {
            var targetRect = NSRect(x: contentView.bounds.midX, y: contentView.bounds.midY, width: 1, height: 1)
            if let screenPoint = anchorScreenPoint {
                let windowPoint = window.convertPoint(fromScreen: screenPoint)
                let pointInView = contentView.convert(windowPoint, from: nil)
                let safeX = min(max(20, pointInView.x), max(20, contentView.bounds.width - 20))
                let safeY = min(max(20, pointInView.y), max(20, contentView.bounds.height - 20))
                targetRect = NSRect(x: safeX, y: safeY, width: 1, height: 1)
            }
            let viewHeight = contentView.bounds.height
            let preferredEdge: NSRectEdge = contentView.isFlipped
                ? (targetRect.midY > viewHeight * 0.58 ? .minY : .maxY)
                : (targetRect.midY < viewHeight * 0.42 ? .maxY : .minY)
            popover.show(relativeTo: targetRect, of: contentView, preferredEdge: preferredEdge)
        }

        guard popover.isShown else {
            popover.delegate = nil
            popoverDelegate = nil
            isLookupPresented = false
            return
        }
        self.activePopover = popover
        isLookupPresented = true
    }

    private func vocabularySourceName() -> String {
        if let title = playbackEngine?.currentMedia?.title,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        var names: [String] = []
        var seen = Set<String>()
        for title in DictionaryEngine.shared.searchResults.map(\.displayName) {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            names.append(trimmed)
        }
        return names.joined(separator: "、")
    }

    public func dismissPopover() {
        if let popover = activePopover {
            activePopover = nil
            popover.delegate = nil
            popover.close()
        }
        popoverDelegate = nil
        isLookupPresented = false
    }

    /// Ignore delayed close callbacks from an older popover. Replacing a
    /// lookup quickly closes the previous NSPopover asynchronously; without
    /// identity checking that callback can clear the new selection and close
    /// the newly presented popover.
    fileprivate func popoverDidClose(_ popover: NSPopover) {
        guard activePopover === popover else { return }
        activePopover = nil
        popoverDelegate = nil
        isLookupPresented = false
        clearSelectionAndDeselect()
    }

    /// Control-Command-D 的统一入口：优先使用选区，没有选区时取光标所在单词。
    public func lookupCurrentSelectionOrWord() {
        guard let textView = currentSelectionTextView,
              textView.window?.isKeyWindow == true else { return }
        guard Self.isDictionarySelectableTextView(textView) else { return }
        let range = textView.selectedRange()
        let length = (textView.string as NSString).length
        guard range.location != NSNotFound,
              range.location >= 0,
              range.location <= length,
              range.length >= 0,
              range.length <= length - range.location else { return }
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

    private static func preferredSpeechVoice(for text: String) -> AVSpeechSynthesisVoice? {
        let hasCJK = text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
        }
        if hasCJK {
            return AVSpeechSynthesisVoice(language: "zh-CN")
        }
        let hasKana = text.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)
        }
        if hasKana {
            return AVSpeechSynthesisVoice(language: "ja-JP")
        }
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let enhanced = voices.first(where: { $0.language == "en-US" && $0.quality == .enhanced }) {
            return enhanced
        }
        return AVSpeechSynthesisVoice(language: "en-US") ?? AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? "en-US")
    }

    public func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = beginAudioRequest()
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = Self.preferredSpeechVoice(for: trimmed)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        avSynthesizer.speak(utterance)
    }

    /// Prefer a pronunciation resource from any installed dictionary; use
    /// AVSpeechSynthesizer only when no matching MDD audio is available.
    public func speakPreferred(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Self.dictionaryAudioLogger.debug("preferred pronunciation requested for \(trimmed, privacy: .public)")

        let generation = beginAudioRequest()

        dictionaryAudioTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let resource = try await DictionaryEngine.shared.firstDictionaryPronunciation(for: trimmed) else {
                    Self.dictionaryAudioLogger.debug("no MDD pronunciation found; falling back to system speech")
                    guard !Task.isCancelled, self.audioGeneration == generation else { return }
                    self.speak(trimmed)
                    return
                }
                try Task.checkCancellation()
                guard self.audioGeneration == generation else { return }
                Self.dictionaryAudioLogger.debug(
                    "MDD pronunciation loaded: \(resource.data.count, privacy: .public) bytes, MIME \(resource.mimeType ?? "nil", privacy: .public)"
                )
                guard !resource.data.isEmpty,
                      let player = Self.makeDictionaryAudioPlayer(
                          data: resource.data,
                          mimeType: resource.mimeType
                      ) else {
                    guard self.audioGeneration == generation else { return }
                    self.speak(trimmed)
                    return
                }
                Self.dictionaryAudioLogger.debug("MDD pronunciation player initialized; duration \(player.duration, format: .fixed(precision: 3), privacy: .public)")
                self.dictionaryAudioPlayer = player
                player.prepareToPlay()
                guard self.audioGeneration == generation else { return }
                let didPlay = player.play()
                Self.dictionaryAudioLogger.debug("MDD pronunciation play returned \(didPlay, privacy: .public)")
                guard didPlay else {
                    guard self.audioGeneration == generation else { return }
                    self.speak(trimmed)
                    return
                }
                guard self.audioGeneration == generation else {
                    player.stop()
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                Self.dictionaryAudioLogger.error("preferred pronunciation failed: \(error.localizedDescription, privacy: .public)")
                guard !Task.isCancelled, self.audioGeneration == generation else { return }
                self.speak(trimmed)
            }
        }
    }

    /// Play an audio record stored in the selected dictionary's MDD package.
    /// Resource lookup and file reading stay off the main actor; only the
    /// short AVAudioPlayer setup returns to the UI actor. A missing or
    /// unsupported record falls back to system pronunciation instead of
    /// leaving the button unresponsive.
    public func playDictionaryAudio(dictionaryID: String, key: String) {
        let id = dictionaryID.trimmingCharacters(in: .whitespacesAndNewlines)
        let resourceKey = key.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let fallbackText: String
        if let selected = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty {
            fallbackText = selected
        } else {
            fallbackText = resourceKey
        }
        guard !id.isEmpty, !resourceKey.isEmpty else {
            speakPreferred(fallbackText)
            return
        }

        Self.dictionaryAudioLogger.debug(
            "entry pronunciation requested: dictionary \(id, privacy: .public), key \(resourceKey, privacy: .public)"
        )

        let generation = beginAudioRequest()

        dictionaryAudioTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let resource = try await DictionaryEngine.shared.resourceData(
                    dictionaryID: id,
                    key: resourceKey
                ), !resource.data.isEmpty else {
                    Self.dictionaryAudioLogger.debug("entry MDD resource missing; falling back to preferred pronunciation")
                    guard !Task.isCancelled, self.audioGeneration == generation else { return }
                    self.speakPreferred(fallbackText)
                    return
                }
                try Task.checkCancellation()
                guard self.audioGeneration == generation else { return }
                Self.dictionaryAudioLogger.debug(
                    "entry MDD resource loaded: \(resource.data.count, privacy: .public) bytes, MIME \(resource.mimeType, privacy: .public)"
                )
                guard let player = Self.makeDictionaryAudioPlayer(
                    data: resource.data,
                    mimeType: resource.mimeType
                ) else {
                    guard self.audioGeneration == generation else { return }
                    self.speakPreferred(fallbackText)
                    return
                }
                Self.dictionaryAudioLogger.debug("entry MDD player initialized; duration \(player.duration, format: .fixed(precision: 3), privacy: .public)")
                self.dictionaryAudioPlayer = player
                player.prepareToPlay()
                guard self.audioGeneration == generation else { return }
                let didPlay = player.play()
                Self.dictionaryAudioLogger.debug("entry MDD play returned \(didPlay, privacy: .public)")
                guard didPlay else {
                    guard self.audioGeneration == generation else { return }
                    self.speakPreferred(fallbackText)
                    return
                }
                guard self.audioGeneration == generation else {
                    player.stop()
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                Self.dictionaryAudioLogger.error("entry pronunciation failed: \(error.localizedDescription, privacy: .public)")
                guard !Task.isCancelled, self.audioGeneration == generation else { return }
                self.speakPreferred(fallbackText)
            }
        }
    }

    /// MDD records are returned as bytes rather than temporary files, so the
    /// decoder cannot infer the container from a path suffix. Supplying the
    /// native file type hint keeps raw MPEG/PCM records decodable while still
    /// falling back to content sniffing for less common dictionary formats.
    private static func makeDictionaryAudioPlayer(
        data: Data,
        mimeType: String?
    ) -> AVAudioPlayer? {
        let normalized = mimeType?.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)
            .map { $0.lowercased() }
        let hint: String?
        switch normalized {
        case "audio/mpeg": hint = AVFileType.mp3.rawValue
        case "audio/wav", "audio/x-wav": hint = AVFileType.wav.rawValue
        case "audio/mp4", "audio/x-m4a": hint = AVFileType.m4a.rawValue
        case "audio/aiff", "audio/x-aiff": hint = AVFileType.aiff.rawValue
        case "audio/x-caf": hint = AVFileType.caf.rawValue
        default: hint = nil
        }
        if let hint, let player = try? AVAudioPlayer(data: data, fileTypeHint: hint) {
            return player
        }
        return try? AVAudioPlayer(data: data)
    }

    private func beginAudioRequest() -> UInt64 {
        audioGeneration &+= 1
        dictionaryAudioTask?.cancel()
        dictionaryAudioTask = nil
        dictionaryAudioPlayer?.stop()
        dictionaryAudioPlayer = nil
        avSynthesizer.stopSpeaking(at: .immediate)
        return audioGeneration
    }

    public func speakSelected() {
        let text = selectedText ?? DictionaryEngine.shared.requestedQuery ?? ""
        speakPreferred(text)
    }

    public func toggleVocabulary(word: String, exampleSentence: String = "") {
        let source = vocabularySourceName()
        Task { @MainActor in
            do {
                _ = try await VocabularyNotebookManager.shared.toggleWord(
                    word: word,
                    exampleSentence: exampleSentence,
                    source: source
                )
            } catch {
                // VocabularyNotebookManager publishes the failure in the
                // status bar; the action bar itself should remain lightweight.
            }
        }
    }

    public func toggleSelectedVocabulary() {
        guard let selectedText else { return }
        toggleVocabulary(word: selectedText, exampleSentence: contextText ?? "")
    }

    public func openDictionaryWindow(query: String? = nil, postNotification: Bool = true) {
        let targetQuery = query ?? selectedText ?? DictionaryEngine.shared.requestedQuery ?? ""
        if !targetQuery.isEmpty {
            DictionaryEngine.shared.requestLookup(targetQuery)
        }
        if postNotification {
            NotificationCenter.default.post(name: .studyMateOpenDictionaryWindow, object: nil)
        }
        dismissPopover()
        // The full dictionary window owns the interaction now. Keep playback
        // paused until that window disappears, matching the popover behavior.
        clearSelectionAndDeselect(resumePlayback: false)
    }

    /// Capture the current subtitle selection for the standalone dictionary
    /// window. The coordinator owns the marker that distinguishes subtitle
    /// NSTextViews from search fields and editors; keeping this check here
    /// prevents a toolbar shortcut from accidentally looking up arbitrary
    /// selected text elsewhere in the app.
    @discardableResult
    public func captureCurrentSelectionForDictionary() -> Bool {
        guard let textView = currentSelectionTextView else { return false }
        let range = textView.selectedRange()
        let length = (textView.string as NSString).length
        guard range.location != NSNotFound,
              range.location >= 0,
              range.location <= length,
              range.length >= 0,
              range.length <= length - range.location else { return false }
        let value: String
        if range.length > 0 {
            value = (textView.string as NSString).substring(with: range)
        } else {
            guard let word = Self.wordAtCaret(in: textView) else { return false }
            value = word
        }
        guard !DictionaryEngine.cleanQueryWord(value).isEmpty else { return false }
        updateSelection(
            text: value,
            context: objc_getAssociatedObject(textView, &dictionaryTextContextAssociationKey) as? String,
            screenPoint: NSEvent.mouseLocation
        )
        DictionaryEngine.shared.requestLookup(DictionaryEngine.cleanQueryWord(value))
        return true
    }

    /// Called by the full dictionary window when it is closed.
    public func dictionaryWindowDidClose() {
        resumePlaybackIfNeeded()
    }

    private func pausePlaybackForDictionaryInteractionIfNeeded() {
        guard let playbackEngine else { return }
        if !pausedPlaybackForDictionaryInteraction {
            shouldResumePlaybackAfterDictionaryInteraction = playbackEngine.isPlaying
            pausedPlaybackForDictionaryInteraction = true
        }
        guard playbackEngine.isPlaying else { return }
        playbackEngine.pause()
    }

    private func resumePlaybackIfNeeded() {
        guard pausedPlaybackForDictionaryInteraction else { return }
        let shouldResume = shouldResumePlaybackAfterDictionaryInteraction
        pausedPlaybackForDictionaryInteraction = false
        shouldResumePlaybackAfterDictionaryInteraction = false
        guard shouldResume, playbackEngine?.currentMedia != nil else { return }
        playbackEngine?.play()
    }

    private func selectionChanged(_ textView: NSTextView?, screenPoint: NSPoint? = nil) {
        guard let textView,
              textView.window?.isKeyWindow == true,
              Self.isDictionarySelectableTextView(textView) else { return }
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

    private func scheduleSelectionUpdate(for textView: NSTextView?) {
        pendingSelectionTextView = textView
        selectionUpdateTask?.cancel()
        selectionUpdateTask = Task { @MainActor [weak self] in
            do {
                // Keep selection feedback responsive while avoiding layout
                // work for every intermediate glyph notification.
                try await Task.sleep(nanoseconds: 16_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, !self.isLookupPresented else { return }
            let pending = self.pendingSelectionTextView
            self.pendingSelectionTextView = nil
            self.selectionUpdateTask = nil
            self.selectionChanged(pending)
        }
    }

    private func flushSelectionUpdate(for textView: NSTextView, screenPoint: NSPoint) {
        cancelPendingSelectionUpdate()
        selectionChanged(textView, screenPoint: screenPoint)
    }

    private func cancelPendingSelectionUpdate() {
        selectionUpdateTask?.cancel()
        selectionUpdateTask = nil
        pendingSelectionTextView = nil
    }

    private var currentSelectionTextView: NSTextView? {
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
           textView.window?.isKeyWindow == true,
           Self.isDictionarySelectableTextView(textView) {
            return textView
        }
        if let pendingSelectionTextView,
           pendingSelectionTextView.window?.isKeyWindow == true,
           Self.isDictionarySelectableTextView(pendingSelectionTextView) {
            return pendingSelectionTextView
        }
        if let activeTextView,
           activeTextView.window?.isKeyWindow == true,
           Self.isDictionarySelectableTextView(activeTextView) {
            return activeTextView
        }
        return nil
    }

    private nonisolated static func isDictionarySelectableTextView(_ textView: NSTextView) -> Bool {
        (objc_getAssociatedObject(textView, &dictionarySelectableTextMarkerKey) as? NSNumber)?.boolValue == true
    }

    private static func wordAtCaret(in textView: NSTextView) -> String? {
        let string = textView.string as NSString
        guard string.length > 0 else { return nil }
        let location = textView.selectedRange().location
        guard location != NSNotFound, location >= 0 else { return nil }
        let caret = min(location, string.length)
        let wordRange = textView.selectionRange(
            forProposedRange: NSRange(location: caret, length: 0),
            granularity: .selectByWord
        )
        guard wordRange.location != NSNotFound, wordRange.length > 0,
              wordRange.location + wordRange.length <= string.length else { return nil }
        let rawWord = string.substring(with: wordRange)
        let cleaned = DictionaryEngine.cleanQueryWord(rawWord)
        return cleaned.isEmpty ? nil : cleaned
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
/// 这里使用原生 NSTextView，并通过轻量子类补充鼠标进入/离开回调与修饰键拖移支持。
/// 文本容器仍使用 NSTextView(frame:) 创建，保留 AppKit 自带的双击选词、
/// 拖动选短语和选区通知。按住 Option/Command 拖移时将移动字幕位置，不影响普通文本选区。
public struct DictionarySelectableText: NSViewRepresentable {
    public let text: String
    public let font: NSFont
    public let color: NSColor
    public let context: String?
    public let alignment: NSTextAlignment
    public let onHoverChanged: ((Bool) -> Void)?
    public let onSingleClick: (() -> Void)?
    public let onDoubleClick: (() -> Void)?
    public let onOptionDrag: ((TextDragPhase) -> Void)?

    public init(
        text: String,
        font: NSFont = .systemFont(ofSize: 13),
        color: NSColor = .labelColor,
        context: String? = nil,
        alignment: NSTextAlignment = .left,
        onHoverChanged: ((Bool) -> Void)? = nil,
        onSingleClick: (() -> Void)? = nil,
        onDoubleClick: (() -> Void)? = nil,
        onOptionDrag: ((TextDragPhase) -> Void)? = nil
    ) {
        self.text = text
        self.font = font
        self.color = color
        self.context = context
        self.alignment = alignment
        self.onHoverChanged = onHoverChanged
        self.onSingleClick = onSingleClick
        self.onDoubleClick = onDoubleClick
        self.onOptionDrag = onOptionDrag
    }

    public final class Coordinator: NSObject {
        var onSingleClick: (() -> Void)?
        var onDoubleClick: (() -> Void)?
        var onHoverChanged: ((Bool) -> Void)?
        var onOptionDrag: ((TextDragPhase) -> Void)?

        public init(
            onSingleClick: (() -> Void)? = nil,
            onDoubleClick: (() -> Void)? = nil,
            onHoverChanged: ((Bool) -> Void)? = nil,
            onOptionDrag: ((TextDragPhase) -> Void)? = nil
        ) {
            self.onSingleClick = onSingleClick
            self.onDoubleClick = onDoubleClick
            self.onHoverChanged = onHoverChanged
            self.onOptionDrag = onOptionDrag
        }

    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            onSingleClick: onSingleClick,
            onDoubleClick: onDoubleClick,
            onHoverChanged: onHoverChanged,
            onOptionDrag: onOptionDrag
        )
    }

    public func makeNSView(context: Context) -> NSTextView {
        // Use only NSTextView(frame:), which lets AppKit create its standard
        // text container safely on all supported macOS versions.
        let textView = DictionaryTextView(frame: .zero)
        textView.onSingleClick = context.coordinator.onSingleClick
        textView.onDoubleClick = context.coordinator.onDoubleClick
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

        // Keep the global selection observer scoped to the two subtitle
        // surfaces (sentence rows and video subtitles). Other NSTextViews in
        // the app, such as search fields and editors, must not trigger lookup.
        objc_setAssociatedObject(
            textView,
            &dictionarySelectableTextMarkerKey,
            NSNumber(value: true),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        return textView
    }

    public func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.onSingleClick = onSingleClick
        context.coordinator.onDoubleClick = onDoubleClick
        context.coordinator.onHoverChanged = onHoverChanged
        context.coordinator.onOptionDrag = onOptionDrag
        if let dictTextView = textView as? DictionaryTextView {
            dictTextView.onSingleClick = onSingleClick
            dictTextView.onDoubleClick = onDoubleClick
            dictTextView.onHoverChanged = onHoverChanged
            dictTextView.onOptionDrag = onOptionDrag
        }

        if textView.string != text {
            textView.string = text
            textView.toolTip = text
            textView.menu = contextMenu(for: textView)
        } else if textView.menu == nil {
            textView.menu = contextMenu(for: textView)
        } else if let target = objc_getAssociatedObject(textView, &ContextMenuTarget.associationKey) as? ContextMenuTarget {
            // SwiftUI can update the subtitle context while reusing the same
            // NSTextView. Refresh the existing target instead of allocating a
            // new menu on every list redraw, while keeping right-click lookup
            // context accurate.
            target.text = text
            target.context = self.context
            if let lookupItem = textView.menu?.items.first {
                lookupItem.title = LanguageManager.shared.text("查询所选词", "Look Up Selection")
            }
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
            title: LanguageManager.shared.text("查询所选词", "Look Up Selection"),
            action: #selector(ContextMenuTarget.lookup(_:)),
            keyEquivalent: ""
        )
        let copy = NSMenuItem(
            title: LanguageManager.shared.text("复制", "Copy"),
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
        var onSingleClick: (() -> Void)?
        var onDoubleClick: (() -> Void)?
        var onHoverChanged: ((Bool) -> Void)?
        var onOptionDrag: ((TextDragPhase) -> Void)?
        private var trackingArea: NSTrackingArea?
        private var isOptionDragging = false
        private var dragStartWindowPoint: NSPoint?
        private var plainMouseDownPoint: NSPoint?
        private var plainMouseDidMove = false

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
            plainMouseDownPoint = event.locationInWindow
            plainMouseDidMove = false
            if event.clickCount == 2 {
                // Notify before NSTextView handles the second click so media
                // pauses at the same time as native word selection begins.
                onDoubleClick?()
            }
            super.mouseDown(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            if isOptionDragging, let start = dragStartWindowPoint {
                let current = event.locationInWindow
                let translation = CGSize(width: current.x - start.x, height: -(current.y - start.y))
                onOptionDrag?(.changed(translation: translation))
                return
            }
            if let start = plainMouseDownPoint {
                let current = event.locationInWindow
                plainMouseDidMove = plainMouseDidMove ||
                    hypot(current.x - start.x, current.y - start.y) > 2
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
            defer {
                plainMouseDownPoint = nil
                plainMouseDidMove = false
            }
            // NSTextView's native selection remains in charge. Only a
            // genuine single click (not a phrase drag or the second click of
            // a double-click word selection) should activate the sentence.
            if event.clickCount == 1, !plainMouseDidMove {
                onSingleClick?()
            }
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
        var text: String
        var context: String?
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
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 24, height: 22)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.09) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

/// 生词本按钮使用稳定存在的基础 SF Symbols 组合，避免某些系统符号
/// 集合中不存在 book.badge.minus 时 Image 退化为空白。
@MainActor
private struct VocabularyStateIcon: View {
    let isSaved: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            Image(systemName: isSaved ? "minus.circle.fill" : "plus.circle.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.primary)
                .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                .offset(x: 3, y: 3)
        }
        .accessibilityHidden(true)
    }
}

/// 选中文字操作条中的生词本切换按钮。
@MainActor
private struct DictionaryVocabularyActionButton: View {
    let title: String
    let help: String
    let isSaved: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VocabularyStateIcon(isSaved: isSaved)
                .frame(width: 24, height: 22)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovered ? Color.primary.opacity(0.09) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(title)
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
    @ObservedObject private var vocabularyManager = VocabularyNotebookManager.shared

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

            DictionaryVocabularyActionButton(
                title: vocabularyManager.isWordSaved(coordinator.selectedText ?? "")
                    ? lang.text("从生词本移除", "Remove from Vocabulary")
                    : lang.text("加入生词本", "Add to Vocabulary"),
                help: vocabularyManager.isWordSaved(coordinator.selectedText ?? "")
                    ? lang.text("从生词本移除", "Remove from Vocabulary")
                    : lang.text("加入生词本", "Add to Vocabulary"),
                isSaved: vocabularyManager.isWordSaved(coordinator.selectedText ?? "")
            ) {
                coordinator.toggleSelectedVocabulary()
            }
            .disabled(vocabularyManager.isWorking)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3.5)
        .studymateChromeCapsule()
        .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 4)
        // NSEvent.locationInWindow is in the AppKit window coordinate space;
        // SwiftUI's .global frame is not. Report the frame from an embedded
        // NSView so a click on one of these buttons cannot be mistaken for an
        // outside click that clears the selection first.
        .background(
            DictionaryActionBarFrameReader { frame in
                coordinator.actionBarFrameInWindow = frame
            }
        )
        .onDisappear {
            coordinator.actionBarFrameInWindow = nil
        }
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
              let window = coordinator.activeTextView?.window ?? NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first,
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
    let onLookupWord: (String) -> Void
    let onPronounce: (String) -> Void
    let onToggleVocabulary: (String) -> Void
    let onOpenDictionary: (String) -> Void
    let onDismiss: () -> Void
    @State private var displayedQuery: String
    @ObservedObject private var engine = DictionaryEngine.shared
    @ObservedObject private var lang = LanguageManager.shared
    @ObservedObject private var vocabularyManager = VocabularyNotebookManager.shared
    @ObservedObject private var dictionaryAppearanceSettings = DictionaryAppearanceSettings.shared
    @ObservedObject private var dictionarySourceSettings = DictionarySourceSettings.shared

    private var displayedEntries: [StudyMateDictionaryLookup] {
        if let scopeID = dictionarySourceSettings.lookupScopeDictionaryID, !scopeID.isEmpty {
            return engine.searchResults.filter { $0.dictionaryID == scopeID }
        }
        return engine.searchResults
    }

    init(
        query: String,
        context: String?,
        onLookupWord: @escaping (String) -> Void,
        onPronounce: @escaping (String) -> Void,
        onToggleVocabulary: @escaping (String) -> Void,
        onOpenDictionary: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.query = query
        self.context = context
        self.onLookupWord = onLookupWord
        self.onPronounce = onPronounce
        self.onToggleVocabulary = onToggleVocabulary
        self.onOpenDictionary = onOpenDictionary
        self.onDismiss = onDismiss
        _displayedQuery = State(initialValue: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayedQuery)
                        .font(.title3.weight(.semibold))
                    if let original = engine.lemmaOriginalQuery,
                       let resolved = engine.definitionQuery,
                       resolved.caseInsensitiveCompare(original) != .orderedSame {
                        Text(lang.text("已还原原型：\(resolved)", "Base form: \(resolved)"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { onPronounce(displayedQuery) } label: {
                    Image(systemName: "speaker.wave.2.fill")
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .accessibilityLabel(lang.text("播放发音", "Pronounce"))
                .help(lang.text("播放发音", "Pronounce"))

                DictionaryVocabularyActionButton(
                    title:
                    vocabularyManager.isWordSaved(displayedQuery)
                        ? lang.text("从生词本移除", "Remove from Vocabulary")
                        : lang.text("加入生词本", "Add to Vocabulary"),
                    help:
                    vocabularyManager.isWordSaved(displayedQuery)
                        ? lang.text("从生词本移除", "Remove from Vocabulary")
                        : lang.text("加入生词本", "Add to Vocabulary"),
                    isSaved: vocabularyManager.isWordSaved(displayedQuery),
                    action: { onToggleVocabulary(displayedQuery) }
                )
                .disabled(vocabularyManager.isWorking)
            }

            Divider()

            if (engine.isSearching || engine.isLoadingDefinition || engine.isBusy) && displayedEntries.isEmpty {
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
            } else if displayedEntries.isEmpty {
                Text(lang.text("未找到释义", "No definition found"))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                DictionaryHTMLView(
                    entries: displayedEntries,
                    isCompact: true,
                    // Keep the popover on the same WebKit/MDX execution path
                    // as the full dictionary pane so fold controls and
                    // dictionary-provided interactions behave consistently.
                    allowsJavaScript: true,
                    adaptsToSystemAppearance: dictionaryAppearanceSettings.adaptsToSystemAppearance,
                    onLookupWord: { word in
                        displayedQuery = word
                        onLookupWord(word)
                    },
                    onPlayAudio: { audioKey in
                        DictionaryInteractionCoordinator.shared.speakPreferred(audioKey)
                    },
                    onPlayDictionaryAudio: { dictionaryID, key in
                        DictionaryInteractionCoordinator.shared.playDictionaryAudio(
                            dictionaryID: dictionaryID,
                            key: key
                        )
                    }
                )
                .frame(height: 360)
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
                Button(lang.text("在词典中打开", "Open in Dictionary")) {
                    onOpenDictionary(displayedQuery)
                }
                Spacer()
                Button(lang.text("关闭", "Close"), action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 420)
    }
}

private final class DictionaryPopoverDelegate: NSObject, NSPopoverDelegate {
    weak var coordinator: DictionaryInteractionCoordinator?

    init(coordinator: DictionaryInteractionCoordinator) {
        self.coordinator = coordinator
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        Task { @MainActor [weak self] in
            guard let self, let coordinator = self.coordinator else { return }
            coordinator.popoverDidClose(popover)
        }
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
