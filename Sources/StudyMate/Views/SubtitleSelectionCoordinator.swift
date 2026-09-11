import SwiftUI
import AppKit
import AVFoundation
import OSLog

private var subtitleTextContextAssociationKey: UInt8 = 0
private var subtitleSelectableTextMarkerKey: UInt8 = 0

private let subtitleBoundaryPunctuation = CharacterSet(charactersIn: #",.:;!?…"'“”‘’`()[]{}<>«»—–/"#)
    .union(.whitespacesAndNewlines)

private func cleanSubtitleQueryWord(_ value: String) -> String {
    value.trimmingCharacters(in: subtitleBoundaryPunctuation)
}

/// Reports a SwiftUI-hosted control's frame in AppKit's window coordinate space.
private struct SubtitleActionBarFrameReader: NSViewRepresentable {
    let onChange: (NSRect?) -> Void

    func makeNSView(context: Context) -> SubtitleActionBarFrameReportingView {
        let view = SubtitleActionBarFrameReportingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: SubtitleActionBarFrameReportingView, context: Context) {
        nsView.onChange = onChange
        nsView.reportFrame()
    }
}

private final class SubtitleActionBarFrameReportingView: NSView {
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

/// 统一管理字幕取词状态。负责选区、浮动操作条（查词、发音、生词本）、
/// 轻量原生气泡查词弹窗（NSPopover），并支持跳转外部独立词典应用。
@MainActor
public final class SubtitleSelectionCoordinator: ObservableObject {
    public static let shared = SubtitleSelectionCoordinator()

    private static let audioLogger = Logger(
        subsystem: "com.samuel.StudyMate",
        category: "subtitle-audio"
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
    private var popoverDelegate: SubtitlePopoverDelegate?
    private var pausedPlaybackForInteraction = false
    private var shouldResumePlaybackAfterInteraction = false
    private let avSynthesizer = AVSpeechSynthesizer()
    private var dictionaryAudioTask: Task<Void, Never>?
    private var dictionaryAudioPlayer: AVAudioPlayer?
    private var audioGeneration: UInt64 = 0
    private var selectionObserver: NSObjectProtocol?
    private var mouseUpMonitor: Any?
    private var mouseDownMonitor: Any?
    private var keyDownMonitor: Any?
    private var selectionUpdateTask: Task<Void, Never>?
    private weak var pendingSelectionTextView: NSTextView?

    private init() {
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let textView = notification.object as? NSTextView,
                  Self.isSubtitleSelectableTextView(textView) else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.isLookupPresented else { return }
                self.scheduleSelectionUpdate(for: textView)
            }
        }

        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] event in
            guard let self else { return event }
            let mouseInWindow = event.locationInWindow
            let targetWindow = self.activeTextView?.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            // 鼠标松开若在操作条范围内，属于点击操作条按钮，绝不重算选区与锚点，防止面板跳动
            if let barFrame = self.actionBarFrameInWindow,
               event.window === targetWindow || event.window == nil {
                if barFrame.insetBy(dx: -10, dy: -10).contains(mouseInWindow) {
                    return event
                }
            }
            let screenPoint = event.window?.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin ?? NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                guard let self, !self.isLookupPresented else { return }
                if let textView = self.currentSelectionTextView {
                    self.flushSelectionUpdate(for: textView, screenPoint: screenPoint)
                }
            }
            return event
        }

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
                    // 预留 10pt 点击容差，避免点在操作条胶囊边缘缝隙时误触关闭
                    if barFrame.insetBy(dx: -10, dy: -10).contains(mouseInWindow) {
                        return event
                    }
                }
                self.clearSelectionAndDeselect()
                return event
            }

            return event
        }

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
    }

    public func bindPlaybackEngine(_ engine: PlaybackEngine) {
        playbackEngine = engine
    }

    public func updateSelection(
        text: String,
        context: String? = nil,
        screenPoint: NSPoint? = nil,
        screenRect: NSRect? = nil
    ) {
        let value = cleanSubtitleQueryWord(text)
        guard !value.isEmpty else {
            clearSelection()
            return
        }
        selectedText = value
        contextText = context?.trimmingCharacters(in: .whitespacesAndNewlines)
        anchorScreenRect = screenRect
        if let screenRect, screenRect.width > 0, screenRect.height > 0 {
            anchorScreenPoint = NSPoint(x: screenRect.midX, y: screenRect.midY)
        } else if let screenPoint {
            anchorScreenPoint = screenPoint
        } else {
            anchorScreenPoint = NSEvent.mouseLocation
        }
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
            let end = (activeTextView.string as NSString).length
            activeTextView.setSelectedRange(NSRange(location: end, length: 0))
            if activeTextView.window?.firstResponder === activeTextView {
                activeTextView.window?.makeFirstResponder(nil)
            }
            activeTextView.needsDisplay = true
        }
        activeTextView = nil
    }

    /// 点击“查词”时调用：在当前选词旁弹出原生轻量气泡弹窗
    public func lookupSelected() {
        guard let selectedText else { return }
        pausePlaybackForInteractionIfNeeded()
        DictionarySourceSettings.shared.reloadFromStorage()
        let targetDictionaryID = DictionarySourceSettings.shared.lookupScopeDictionaryID
        DictionaryEngine.shared.clearSearch()
        DictionaryEngine.shared.search(
            query: selectedText,
            dictionaryID: targetDictionaryID,
            includeDetails: true,
            immediate: true
        )
        showNativePopover()
    }

    public func showNativePopover() {
        dismissPopover()
        DictionarySourceSettings.shared.reloadFromStorage()

        guard let query = selectedText else { return }

        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true

        let delegate = SubtitlePopoverDelegate(coordinator: self)
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
            onPronounce: { [weak self] word in
                self?.speakPreferred(word)
            },
            onToggleVocabulary: { [weak self] word in
                guard let self else { return }
                self.toggleVocabulary(word: word, exampleSentence: self.contextText ?? "")
            },
            onOpenDictionary: { [weak self] word in
                self?.dismissPopover()
                StudyMateDictionaryBridge.openDictionary(query: word)
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
            let rect: NSRect
            if range.length > 0 {
                rect = textView.firstRect(forCharacterRange: range, actualRange: nil)
            } else {
                rect = textView.bounds
            }
            let localRect = textView.window?.convertFromScreen(rect) ?? rect
            let targetRect = textView.convert(localRect, from: nil)
            popover.show(relativeTo: targetRect, of: textView, preferredEdge: .maxY)
        } else if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first,
                  let contentView = window.contentView {
            let targetRect: NSRect
            if let anchorScreenPoint {
                let windowPoint = window.convertPoint(fromScreen: anchorScreenPoint)
                let pointInView = contentView.convert(windowPoint, from: nil)
                let safeX = min(max(20, pointInView.x), max(20, contentView.bounds.width - 20))
                let safeY = min(max(20, pointInView.y), max(20, contentView.bounds.height - 20))
                targetRect = NSRect(x: safeX, y: safeY, width: 1, height: 1)
            } else {
                targetRect = NSRect(x: contentView.bounds.midX, y: contentView.bounds.midY, width: 1, height: 1)
            }
            let preferredEdge: NSRectEdge = contentView.isFlipped
                ? (targetRect.midY > contentView.bounds.height * 0.58 ? .minY : .maxY)
                : (targetRect.midY < contentView.bounds.height * 0.42 ? .maxY : .minY)
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

    public func dismissPopover() {
        if let popover = activePopover {
            activePopover = nil
            popover.delegate = nil
            popover.close()
        }
        popoverDelegate = nil
        isLookupPresented = false
    }

    fileprivate func popoverDidClose(_ popover: NSPopover) {
        guard activePopover === popover else { return }
        activePopover = nil
        popoverDelegate = nil
        isLookupPresented = false
        clearSelectionAndDeselect()
    }

    public func pausePlaybackForVideoSubtitleSelection() {
        pausePlaybackForInteractionIfNeeded()
    }

    public func lookupCurrentSelectionOrWord() {
        guard let textView = currentSelectionTextView,
              textView.window?.isKeyWindow == true else { return }
        guard Self.isSubtitleSelectableTextView(textView) else { return }
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

    public func speakPreferred(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let generation = beginAudioRequest()

        dictionaryAudioTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let resource = try await DictionaryEngine.shared.firstDictionaryPronunciation(for: trimmed) else {
                    guard !Task.isCancelled, self.audioGeneration == generation else { return }
                    self.speak(trimmed)
                    return
                }
                try Task.checkCancellation()
                guard self.audioGeneration == generation else { return }
                guard !resource.data.isEmpty,
                      let player = await Self.makeDictionaryAudioPlayerInBackground(
                          data: resource.data,
                          mimeType: resource.mimeType
                      ) else {
                    guard self.audioGeneration == generation else { return }
                    self.speak(trimmed)
                    return
                }
                self.dictionaryAudioPlayer = player
                player.prepareToPlay()
                guard self.audioGeneration == generation else { return }
                let didPlay = player.play()
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
                guard !Task.isCancelled, self.audioGeneration == generation else { return }
                self.speak(trimmed)
            }
        }
    }

    public func playDictionaryAudio(dictionaryID: String, key: String) {
        let id = dictionaryID.trimmingCharacters(in: .whitespacesAndNewlines)
        let resourceKey = key.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let fallbackText = resourceKey
        guard !id.isEmpty, !resourceKey.isEmpty else {
            speakPreferred(fallbackText)
            return
        }

        let generation = beginAudioRequest()

        dictionaryAudioTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let resource = try await DictionaryEngine.shared.resourceData(
                    dictionaryID: id,
                    key: resourceKey
                ), !resource.data.isEmpty else {
                    guard !Task.isCancelled, self.audioGeneration == generation else { return }
                    self.speakPreferred(fallbackText)
                    return
                }
                try Task.checkCancellation()
                guard self.audioGeneration == generation else { return }
                guard let player = await Self.makeDictionaryAudioPlayerInBackground(
                    data: resource.data,
                    mimeType: resource.mimeType
                ) else {
                    guard self.audioGeneration == generation else { return }
                    self.speakPreferred(fallbackText)
                    return
                }
                self.dictionaryAudioPlayer = player
                player.prepareToPlay()
                guard self.audioGeneration == generation else { return }
                let didPlay = player.play()
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
                guard !Task.isCancelled, self.audioGeneration == generation else { return }
                self.speakPreferred(fallbackText)
            }
        }
    }

    private nonisolated static func makeDictionaryAudioPlayerInBackground(
        data: Data,
        mimeType: String?
    ) async -> AVAudioPlayer? {
        await Task.detached(priority: .userInitiated) {
            makeDictionaryAudioPlayer(data: data, mimeType: mimeType)
        }.value
    }

    private nonisolated static func makeDictionaryAudioPlayer(
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
        guard let text = selectedText, !text.isEmpty else { return }
        DictionarySourceSettings.shared.reloadFromStorage()
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
                // 异常统一在状态栏中展示
            }
        }
    }

    public func toggleSelectedVocabulary() {
        guard let selectedText else { return }
        toggleVocabulary(word: selectedText, exampleSentence: contextText ?? "")
    }

    private func vocabularySourceName() -> String {
        if let title = playbackEngine?.currentMedia?.title,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return ""
    }

    public func openDictionaryWindow(query: String? = nil, postNotification: Bool = true) {
        let targetQuery = query ?? selectedText ?? ""
        dismissPopover()
        StudyMateDictionaryBridge.openDictionary(query: targetQuery.isEmpty ? nil : targetQuery)
        clearSelectionAndDeselect(resumePlayback: false)
    }

    @discardableResult
    public func captureCurrentSelection() -> Bool {
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
        let cleaned = cleanSubtitleQueryWord(value)
        guard !cleaned.isEmpty else { return false }
        updateSelection(
            text: cleaned,
            context: objc_getAssociatedObject(textView, &subtitleTextContextAssociationKey) as? String,
            screenPoint: NSEvent.mouseLocation
        )
        return true
    }

    @discardableResult
    public func captureCurrentSelectionForDictionary() -> Bool {
        captureCurrentSelection()
    }

    public func dictionaryWindowDidClose() {
        resumePlaybackIfNeeded()
    }

    private func pausePlaybackForInteractionIfNeeded() {
        guard let playbackEngine else { return }
        if !pausedPlaybackForInteraction {
            shouldResumePlaybackAfterInteraction = playbackEngine.isPlaying
            pausedPlaybackForInteraction = true
        }
        guard playbackEngine.isPlaying else { return }
        playbackEngine.pause()
    }

    private func resumePlaybackIfNeeded() {
        guard pausedPlaybackForInteraction else { return }
        let shouldResume = shouldResumePlaybackAfterInteraction
        pausedPlaybackForInteraction = false
        shouldResumePlaybackAfterInteraction = false
        guard shouldResume, playbackEngine?.currentMedia != nil else { return }
        playbackEngine?.play()
    }

    private func selectionChanged(_ textView: NSTextView?, screenPoint: NSPoint? = nil) {
        guard let textView,
              textView.window?.isKeyWindow == true,
              Self.isSubtitleSelectableTextView(textView) else { return }
        let range = textView.selectedRange()
        guard range.length > 0, range.location != NSNotFound,
              range.location + range.length <= (textView.string as NSString).length else {
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
            let rectInView = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            if let window = textView.window {
                let rectInWindow = textView.convert(rectInView, to: nil)
                calculatedScreenRect = window.convertToScreen(rectInWindow)
                calculatedScreenPoint = NSPoint(x: calculatedScreenRect!.midX, y: calculatedScreenRect!.midY)
            }
        }

        let selected = (textView.string as NSString).substring(with: range)
        let context = objc_getAssociatedObject(textView, &subtitleTextContextAssociationKey) as? String
        updateSelection(
            text: selected,
            context: context,
            screenPoint: calculatedScreenPoint ?? screenPoint,
            screenRect: calculatedScreenRect
        )
    }

    private func scheduleSelectionUpdate(for textView: NSTextView) {
        pendingSelectionTextView = textView
        guard selectionUpdateTask == nil else { return }
        selectionUpdateTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.selectionUpdateTask = nil
            guard let target = self.pendingSelectionTextView else { return }
            self.pendingSelectionTextView = nil
            self.selectionChanged(target)
        }
    }

    private func flushSelectionUpdate(for textView: NSTextView, screenPoint: NSPoint? = nil) {
        cancelPendingSelectionUpdate()
        selectionChanged(textView, screenPoint: screenPoint)
    }

    private func cancelPendingSelectionUpdate() {
        selectionUpdateTask?.cancel()
        selectionUpdateTask = nil
        pendingSelectionTextView = nil
    }

    private var currentSelectionTextView: NSTextView? {
        if let responder = NSApp.keyWindow?.firstResponder as? NSTextView,
           Self.isSubtitleSelectableTextView(responder) {
            return responder
        }
        if let textView = pendingSelectionTextView,
           textView.window?.isKeyWindow == true,
           Self.isSubtitleSelectableTextView(textView) {
            return textView
        }
        if let activeTextView,
           activeTextView.window?.isKeyWindow == true,
           Self.isSubtitleSelectableTextView(activeTextView) {
            return activeTextView
        }
        return nil
    }

    private nonisolated static func isSubtitleSelectableTextView(_ textView: NSTextView) -> Bool {
        (objc_getAssociatedObject(textView, &subtitleSelectableTextMarkerKey) as? NSNumber)?.boolValue == true
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
        let cleaned = cleanSubtitleQueryWord(rawWord)
        return cleaned.isEmpty ? nil : cleaned
    }
}

private final class SubtitlePopoverDelegate: NSObject, NSPopoverDelegate {
    weak var coordinator: SubtitleSelectionCoordinator?

    init(coordinator: SubtitleSelectionCoordinator) {
        self.coordinator = coordinator
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        Task { @MainActor [weak self] in
            self?.coordinator?.popoverDidClose(popover)
        }
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

                SubtitleVocabularyActionButton(
                    title: vocabularyManager.isWordSaved(displayedQuery)
                        ? lang.text("从生词本移除", "Remove from Vocabulary")
                        : lang.text("加入生词本", "Add to Vocabulary"),
                    help: vocabularyManager.isWordSaved(displayedQuery)
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
                    allowsJavaScript: true,
                    onLookupWord: { word in
                        displayedQuery = word
                        onLookupWord(word)
                    },
                    onPlayAudio: { audioKey in
                        SubtitleSelectionCoordinator.shared.speak(audioKey)
                    },
                    onPlayDictionaryAudio: { dictID, key in
                        SubtitleSelectionCoordinator.shared.playDictionaryAudio(dictionaryID: dictID, key: key)
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
                Button(lang.text("在独立词典中打开", "Open in Standalone Dictionary")) {
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

public typealias DictionaryInteractionCoordinator = SubtitleSelectionCoordinator

public enum TextDragPhase {
    case started
    case changed(translation: CGSize)
    case ended(translation: CGSize)
}

public extension Notification.Name {
    static let studyMateOpenDictionaryWindow = Notification.Name("StudyMate.OpenDictionaryWindow")
}

public extension NSTextView {
    func configureForSubtitleLookup(context: String?) {
        objc_setAssociatedObject(
            self,
            &subtitleSelectableTextMarkerKey,
            NSNumber(value: true),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        objc_setAssociatedObject(
            self,
            &subtitleTextContextAssociationKey,
            context,
            .OBJC_ASSOCIATION_COPY_NONATOMIC
        )
    }

    func updateSubtitleLookupContext(_ context: String?) {
        objc_setAssociatedObject(
            self,
            &subtitleTextContextAssociationKey,
            context,
            .OBJC_ASSOCIATION_COPY_NONATOMIC
        )
    }

    func configureForDictionaryLookup(context: String?) {
        configureForSubtitleLookup(context: context)
    }

    func updateDictionaryLookupContext(_ context: String?) {
        updateSubtitleLookupContext(context)
    }
}

/// 可选择的字幕文本。使用原生 NSTextView，支持鼠标悬浮回调、修饰键拖移与取词选区。
public struct SubtitleSelectableText: NSViewRepresentable {
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
        let textView = SubtitleTextView(frame: .zero)
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
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.widthTracksTextView = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        objc_setAssociatedObject(
            textView,
            &subtitleSelectableTextMarkerKey,
            NSNumber(value: true),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        return textView
    }

    private static let fittingSizeCache: NSCache<NSString, NSValue> = {
        let cache = NSCache<NSString, NSValue>()
        cache.countLimit = 1500
        return cache
    }()

    public static func calculateFittingSize(
        text: String,
        font: NSFont,
        alignment: NSTextAlignment = .left,
        proposedWidth: CGFloat?
    ) -> CGSize {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let singleLineHeight = ceil(max(font.pointSize * 1.35, font.ascender - font.descender + font.leading))

        guard let width = proposedWidth, width > 0, width.isFinite else {
            guard !trimmed.isEmpty else {
                return CGSize(width: 50, height: singleLineHeight)
            }
            let key = "u:\(trimmed.hashValue):\(font.fontName):\(Int(font.pointSize * 10)):\(alignment.rawValue)" as NSString
            if let cached = fittingSizeCache.object(forKey: key) {
                return cached.sizeValue
            }
            let attrString = NSAttributedString(string: trimmed, attributes: [.font: font])
            let rect = attrString.boundingRect(
                with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            let result = CGSize(width: ceil(rect.width), height: max(singleLineHeight, ceil(rect.height) + 6))
            fittingSizeCache.setObject(NSValue(size: result), forKey: key)
            return result
        }

        guard !trimmed.isEmpty else {
            return CGSize(width: width, height: singleLineHeight)
        }

        let roundedWidth = Int(width)
        let key = "w:\(roundedWidth):\(trimmed.hashValue):\(font.fontName):\(Int(font.pointSize * 10)):\(alignment.rawValue)" as NSString
        if let cached = fittingSizeCache.object(forKey: key) {
            return cached.sizeValue
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle
        ]
        let attrString = NSAttributedString(string: trimmed, attributes: attributes)
        let rect = attrString.boundingRect(
            with: CGSize(width: CGFloat(roundedWidth), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )

        let calculatedHeight = max(singleLineHeight, ceil(rect.height) + 6)
        let result = CGSize(width: width, height: calculatedHeight)
        fittingSizeCache.setObject(NSValue(size: result), forKey: key)
        return result
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        Self.calculateFittingSize(
            text: text,
            font: font,
            alignment: alignment,
            proposedWidth: proposal.width
        )
    }

    public func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.onSingleClick = onSingleClick
        context.coordinator.onDoubleClick = onDoubleClick
        context.coordinator.onHoverChanged = onHoverChanged
        context.coordinator.onOptionDrag = onOptionDrag
        if let subTextView = textView as? SubtitleTextView {
            subTextView.onSingleClick = onSingleClick
            subTextView.onDoubleClick = onDoubleClick
            subTextView.onHoverChanged = onHoverChanged
            subTextView.onOptionDrag = onOptionDrag
        }

        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0

        if textView.string != text {
            textView.string = text
            textView.toolTip = text
            installContextMenu(on: textView)
            textView.font = font
            textView.textColor = color
            textView.alignment = alignment
            textView.invalidateIntrinsicContentSize()
        } else {
            installContextMenu(on: textView)
        }
        if textView.font != font {
            textView.font = font
            textView.invalidateIntrinsicContentSize()
        }
        if textView.textColor != color {
            textView.textColor = color
        }
        if textView.alignment != alignment {
            textView.alignment = alignment
        }
        objc_setAssociatedObject(
            textView,
            &subtitleTextContextAssociationKey,
            self.context,
            .OBJC_ASSOCIATION_COPY_NONATOMIC
        )
    }

    /// Installs the dictionary context menu on a text view exactly once.
    ///
    /// On macOS 26 assigning a *new* `NSMenu` object to an `NSTextView` makes
    /// AppKit's menu coordinator re-evaluate the window's responder chain, which
    /// dismisses any open tertiary submenu panel (e.g. 显示 → 波形图). The video
    /// mode sentence list is the remaining source of fresh text views: as the
    /// list follows playback across a sentence boundary, newly created rows
    /// build new text views and would previously assign a new menu while the
    /// menu bar was still tracking.
    ///
    /// Keep the menu object identity stable by updating the existing target in
    /// place, and defer the very first assignment until the menu session ends.
    private func installContextMenu(on textView: NSTextView) {
        if let target = objc_getAssociatedObject(textView, &ContextMenuTarget.associationKey) as? ContextMenuTarget {
            target.text = text
            target.context = self.context
            if let lookupItem = textView.menu?.items.first {
                lookupItem.title = LanguageManager.shared.text("查询所选词", "Look Up Selection")
            }
            return
        }

        // AppKit installs its own standard text menu on a fresh `NSTextView`, so
        // the presence of `textView.menu` cannot be used to detect our menu.
        // The associated `ContextMenuTarget` is the authoritative marker.
        let install: () -> Void = { [weak textView] in
            guard let textView,
                  objc_getAssociatedObject(textView, &ContextMenuTarget.associationKey) == nil else { return }
            textView.menu = self.contextMenu(for: textView)
        }

        if MenuTrackingState.shared.isTracking {
            (textView as? SubtitleTextView)?.deferContextMenuInstall(install)
        } else {
            install()
        }
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

    private final class SubtitleTextView: NSTextView {
        var onSingleClick: (() -> Void)?
        var onDoubleClick: (() -> Void)?
        var onHoverChanged: ((Bool) -> Void)?
        var onOptionDrag: ((TextDragPhase) -> Void)?
        private var trackingArea: NSTrackingArea?
        private var isOptionDragging = false
        private var dragStartWindowPoint: NSPoint?
        private var plainMouseDownPoint: NSPoint?
        private var plainMouseDidMove = false
        private var lastIntrinsicHeight: CGFloat = 0
        private var deferredContextMenuInstall: (() -> Void)?
        private var menuTrackingEndObserver: NSObjectProtocol?

        /// Holds the first context-menu assignment until the current menu
        /// tracking session ends, so creating a row during playback following
        /// cannot dismiss an open 显示 → 波形图 panel.
        func deferContextMenuInstall(_ install: @escaping () -> Void) {
            if !MenuTrackingState.shared.isTracking {
                install()
                return
            }
            deferredContextMenuInstall = install
            guard menuTrackingEndObserver == nil else { return }
            menuTrackingEndObserver = NotificationCenter.default.addObserver(
                forName: MenuTrackingState.didEndTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.removeMenuTrackingEndObserver()
                let install = self.deferredContextMenuInstall
                self.deferredContextMenuInstall = nil
                install?()
            }
        }

        private func removeMenuTrackingEndObserver() {
            if let menuTrackingEndObserver {
                NotificationCenter.default.removeObserver(menuTrackingEndObserver)
                self.menuTrackingEndObserver = nil
            }
        }

        deinit {
            removeMenuTrackingEndObserver()
        }

        override var intrinsicContentSize: NSSize {
            guard let textContainer, let layoutManager else {
                return super.intrinsicContentSize
            }
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let singleLine = ceil(max((font?.pointSize ?? 13) * 1.35, (font?.ascender ?? 12) - (font?.descender ?? -3)))
            let height = max(singleLine, ceil(usedRect.height) + 6)
            lastIntrinsicHeight = height
            return NSSize(width: NSView.noIntrinsicMetric, height: height)
        }

        // The subtitle text view is purely for text selection and dictionary
        // lookup; it must never participate in the window's key-view loop.
        // Advertising itself as a first responder causes AppKit to rebroadcast
        // focus preferences on every cue-driven size or position update, which
        // triggers the menu coordinator to close any open tertiary submenu panel.
        override var acceptsFirstResponder: Bool { false }
        override var canBecomeKeyView: Bool { false }


        override func layout() {
            super.layout()
            guard let textContainer, let layoutManager else { return }
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let singleLine = ceil(max((font?.pointSize ?? 13) * 1.35, (font?.ascender ?? 12) - (font?.descender ?? -3)))
            let currentHeight = max(singleLine, ceil(usedRect.height) + 6)
            if abs(currentHeight - lastIntrinsicHeight) > 1.0 {
                lastIntrinsicHeight = currentHeight
                invalidateIntrinsicContentSize()
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                removeTrackingArea(trackingArea)
                self.trackingArea = nil
            }
            guard onHoverChanged != nil || onOptionDrag != nil else { return }
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
            guard onOptionDrag != nil else {
                super.resetCursorRects()
                return
            }
            if NSEvent.modifierFlags.contains(.option) || NSEvent.modifierFlags.contains(.command) {
                discardCursorRects()
                addCursorRect(bounds, cursor: .openHand)
            } else {
                super.resetCursorRects()
            }
        }

        override func flagsChanged(with event: NSEvent) {
            super.flagsChanged(with: event)
            guard onOptionDrag != nil else { return }
            if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
                NSCursor.openHand.set()
            } else if !isOptionDragging {
                NSCursor.arrow.set()
            }
        }

        override func cursorUpdate(with event: NSEvent) {
            guard onOptionDrag != nil else {
                super.cursorUpdate(with: event)
                return
            }
            if NSEvent.modifierFlags.contains(.option) || NSEvent.modifierFlags.contains(.command) {
                NSCursor.openHand.set()
            } else {
                super.cursorUpdate(with: event)
            }
        }

        override func mouseDown(with event: NSEvent) {
            let hasModifier = event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) ||
                              NSEvent.modifierFlags.contains(.option) || NSEvent.modifierFlags.contains(.command)
            if hasModifier {
                isOptionDragging = true
                dragStartWindowPoint = event.locationInWindow
                onOptionDrag?(.started)
                return
            }
            isOptionDragging = false
            plainMouseDownPoint = event.locationInWindow
            plainMouseDidMove = false
            if event.clickCount == 2 {
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
            let coordinator = SubtitleSelectionCoordinator.shared
            coordinator.updateSelection(text: selectedValue, context: context, screenPoint: NSEvent.mouseLocation)
            coordinator.lookupSelected()
        }

        @objc func copy(_ sender: Any?) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selectedValue, forType: .string)
        }
    }
}

public typealias DictionarySelectableText = SubtitleSelectableText

/// 选中文字后的轻量操作条子按钮。
@MainActor
private struct SubtitleActionButton: View {
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

@MainActor
private struct SubtitleVocabularyStateIcon: View {
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

@MainActor
private struct SubtitleVocabularyActionButton: View {
    let title: String
    let help: String
    let isSaved: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            SubtitleVocabularyStateIcon(isSaved: isSaved)
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

/// 选中文字后的 macOS 原生风格轻量浮动操作条（查词、发音、生词本）。
@MainActor
public struct SubtitleSelectionActionBar: View {
    private let playbackEngine: PlaybackEngine
    @ObservedObject private var coordinator = SubtitleSelectionCoordinator.shared
    @ObservedObject private var lang = LanguageManager.shared
    @ObservedObject private var vocabularyManager = VocabularyNotebookManager.shared

    public init(playbackEngine: PlaybackEngine) {
        self.playbackEngine = playbackEngine
    }

    public var body: some View {
        HStack(spacing: 3) {
            SubtitleActionButton(
                title: lang.text("查词", "Look up"),
                systemImage: "book.fill",
                help: lang.text("在词典气泡中查询此词", "Look up in dictionary popover")
            ) {
                coordinator.bindPlaybackEngine(playbackEngine)
                coordinator.lookupSelected()
            }

            divider

            SubtitleActionButton(
                title: lang.text("播放发音", "Pronounce"),
                systemImage: "speaker.wave.2.fill",
                help: lang.text("朗读当前选中文本", "Speak selected text")
            ) {
                coordinator.speakSelected()
            }

            divider

            SubtitleVocabularyActionButton(
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
        .background(
            SubtitleActionBarFrameReader { frame in
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

public typealias DictionarySelectionActionBar = SubtitleSelectionActionBar

/// 主媒体窗口中的选区操作条宿主。
@MainActor
public struct SubtitleLookupOverlay: View {
    private let playbackEngine: PlaybackEngine
    @ObservedObject private var coordinator = SubtitleSelectionCoordinator.shared

    public init(engine: PlaybackEngine) {
        self.playbackEngine = engine
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.clear.allowsHitTesting(false)
                if coordinator.selectedText != nil, !coordinator.isLookupPresented {
                    let pos = actionBarPosition(in: geometry.size)
                    SubtitleSelectionActionBar(playbackEngine: playbackEngine)
                        .position(pos)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .allowsHitTesting(true)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: coordinator.selectedText != nil && !coordinator.isLookupPresented)
        }
        .allowsHitTesting(coordinator.selectedText != nil && !coordinator.isLookupPresented)
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

public typealias DictionaryLookupOverlay = SubtitleLookupOverlay
