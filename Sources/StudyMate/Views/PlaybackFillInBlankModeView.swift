import AppKit
import SwiftUI

// MARK: - 填空词元模型与分词解析器

public struct FillInBlankToken: Identifiable, Equatable {
    public let id: Int
    public let text: String
    public let isWord: Bool
    public let wordIndex: Int?

    public init(id: Int, text: String, isWord: Bool, wordIndex: Int?) {
        self.id = id
        self.text = text
        self.isWord = isWord
        self.wordIndex = wordIndex
    }
}

public enum FillInBlankTokenizer {
    /// 匹配字母与数字构成的词元（支持内部连接符与撇号缩写，如 don't, I'm, state-of-the-art）
    private static let wordRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*"#, options: [])
    }()

    /// 将断句原文拆分为单词槽与标点/空白间隔符
    public static func tokenize(_ text: String) -> [FillInBlankToken] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let regex = wordRegex else {
            return [FillInBlankToken(id: 0, text: trimmed, isWord: true, wordIndex: 0)]
        }

        let nsString = trimmed as NSString
        let matches = regex.matches(in: trimmed, options: [], range: NSRange(location: 0, length: nsString.length))

        var tokens: [FillInBlankToken] = []
        var lastLocation = 0
        var tokenID = 0
        var wordIndex = 0

        for match in matches {
            let matchRange = match.range
            if matchRange.location > lastLocation {
                let sepRange = NSRange(location: lastLocation, length: matchRange.location - lastLocation)
                let sepText = nsString.substring(with: sepRange)
                tokens.append(FillInBlankToken(id: tokenID, text: sepText, isWord: false, wordIndex: nil))
                tokenID += 1
            }

            let wordText = nsString.substring(with: matchRange)
            tokens.append(FillInBlankToken(id: tokenID, text: wordText, isWord: true, wordIndex: wordIndex))
            tokenID += 1
            wordIndex += 1
            lastLocation = matchRange.location + matchRange.length
        }

        if lastLocation < nsString.length {
            let tailRange = NSRange(location: lastLocation, length: nsString.length - lastLocation)
            let tailText = nsString.substring(with: tailRange)
            tokens.append(FillInBlankToken(id: tokenID, text: tailText, isWord: false, wordIndex: nil))
        }

        return tokens
    }

    /// 忽略大小写及缩写撇号的智能词汇匹配
    public static func isMatch(input: String, target: String) -> Bool {
        let cleanInput = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanTarget = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanInput.isEmpty else { return false }
        if cleanInput == cleanTarget { return true }

        // 规范化印刷撇号与直撇号
        let normInput = cleanInput.replacingOccurrences(of: "’", with: "'")
        let normTarget = cleanTarget.replacingOccurrences(of: "’", with: "'")
        if normInput == normTarget { return true }

        // 允许省略内部符号（例如输入 "dont" 匹配 "don't"）
        let stripInput = normInput.filter { $0.isLetter || $0.isNumber }
        let stripTarget = normTarget.filter { $0.isLetter || $0.isNumber }
        return !stripInput.isEmpty && stripInput == stripTarget
    }
}

// MARK: - 自适应流式换行排版布局 (FlowLayout)

public struct FillInBlankFlowLayout: Layout {
    public var horizontalSpacing: CGFloat = 6
    public var verticalSpacing: CGFloat = 12

    public init(horizontalSpacing: CGFloat = 6, verticalSpacing: CGFloat = 12) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var currentLineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += currentLineHeight + verticalSpacing
                currentLineHeight = 0
            }
            currentLineHeight = max(currentLineHeight, size.height)
            currentX += size.width + horizontalSpacing
        }

        return CGSize(width: maxWidth, height: currentY + currentLineHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var currentLineHeight: CGFloat = 0

        var lineItems: [(subview: LayoutSubview, size: CGSize, x: CGFloat)] = []

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                for item in lineItems {
                    let yOffset = currentY + (currentLineHeight - item.size.height)
                    item.subview.place(at: CGPoint(x: item.x, y: yOffset), proposal: ProposedViewSize(item.size))
                }
                lineItems.removeAll()
                currentX = bounds.minX
                currentY += currentLineHeight + verticalSpacing
                currentLineHeight = 0
            }

            lineItems.append((subview, size, currentX))
            currentLineHeight = max(currentLineHeight, size.height)
            currentX += size.width + horizontalSpacing
        }

        for item in lineItems {
            let yOffset = currentY + (currentLineHeight - item.size.height)
            item.subview.place(at: CGPoint(x: item.x, y: yOffset), proposal: ProposedViewSize(item.size))
        }
    }
}

// MARK: - 填空模式主视图（PlaybackFillInBlankModeView）

public struct PlaybackFillInBlankModeView: View {
    @ObservedObject private var engine: PlaybackEngine
    @ObservedObject private var videoSubtitleSettings: VideoSubtitleSettings
    @ObservedObject private var lang: LanguageManager

    @State private var isScrubbing: Bool = false
    @State private var isVolumeScrubbing: Bool = false
    @State private var sentenceAdvanceTask: Task<Void, Never>? = nil

    public init(
        engine: PlaybackEngine,
        videoSubtitleSettings: VideoSubtitleSettings,
        lang: LanguageManager = .shared
    ) {
        self.engine = engine
        self.videoSubtitleSettings = videoSubtitleSettings
        self.lang = lang
    }

    private var currentSegment: SentenceSegment? {
        if let index = engine.activeSegmentIndex,
           engine.segments.indices.contains(index) {
            return engine.segments[index]
        }
        return engine.segments.first
    }

    public var body: some View {
        VStack(spacing: 0) {
            if engine.segments.isEmpty {
                emptyStateView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let seg = currentSegment {
                sentenceFillInBlankArea(seg: seg)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyStateView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            bottomPlaybackControlBar
        }
        .background(StudyMateMediaStyle.windowBackground)
        .onAppear {
            ensureModePlaybackReady()
        }
        .onChange(of: engine.segments.count) { oldCount, newCount in
            if oldCount == 0 && newCount > 0 {
                ensureModePlaybackReady()
            }
        }
        .onChange(of: engine.currentMedia?.url) { _, _ in
            ensureModePlaybackReady()
        }
    }

    private func ensureModePlaybackReady() {
        engine.pauseAfterSegmentHoldsCurrentSegment = true
        engine.loopMode = .pauseAfterSegment
        guard engine.currentMedia != nil, !engine.segments.isEmpty else { return }
        if !engine.isPlaying {
            let targetIdx = engine.activeSegmentIndex ?? 0
            engine.jumpToSegment(at: targetIdx)
            engine.play()
        }
    }

    // MARK: - 填空句子主交互视窗

    @ViewBuilder
    private func sentenceFillInBlankArea(seg: SentenceSegment) -> some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer(minLength: 20)

                    FillInBlankCardView(
                        seg: seg,
                        showOriginal: videoSubtitleSettings.isOriginalVisible(for: .fillInBlank),
                        showTranslation: videoSubtitleSettings.isTranslationVisible(for: .fillInBlank),
                        originalFont: videoSubtitleSettings.makeOriginalFont(for: .fillInBlank),
                        originalColor: videoSubtitleSettings.originalNSColor(for: .fillInBlank),
                        translationFont: videoSubtitleSettings.makeTranslationFont(for: .fillInBlank),
                        translationColor: videoSubtitleSettings.translationNSColor(for: .fillInBlank),
                        language: lang.currentLanguage,
                        replayRevision: engine.replayRevision,
                        onReplayAudio: {
                            sentenceAdvanceTask?.cancel()
                            sentenceAdvanceTask = nil
                            engine.repeatCurrentSegment()
                        },
                        onSentenceCompleted: {
                            sentenceAdvanceTask?.cancel()
                            let replayRevision = engine.replayRevision
                            sentenceAdvanceTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 1_000_000_000)
                                guard !Task.isCancelled,
                                      engine.replayRevision == replayRevision,
                                      currentSegment?.id == seg.id,
                                      currentSegment?.text == seg.text else { return }
                                engine.advanceToNextSentenceAfterCompletion()
                            }
                        }
                    )
                    .id(seg.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 48)
                    .onChange(of: engine.replayRevision) { _, _ in
                        sentenceAdvanceTask?.cancel()
                        sentenceAdvanceTask = nil
                    }
                    .onChange(of: seg.id) { _, _ in
                        sentenceAdvanceTask?.cancel()
                        sentenceAdvanceTask = nil
                        videoSubtitleSettings.hideOriginalPeekInFillInBlank()
                    }
                    .onDisappear {
                        sentenceAdvanceTask?.cancel()
                        sentenceAdvanceTask = nil
                        videoSubtitleSettings.hideOriginalPeekInFillInBlank()
                    }

                    Spacer(minLength: 20)
                }
                .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
        }
    }

    // MARK: - 底部常驻控制条

    private var bottomPlaybackControlBar: some View {
        PlaybackModeBottomBar(
            engine: engine,
            isScrubbing: $isScrubbing,
            isVolumeScrubbing: $isVolumeScrubbing
        )
    }

    // MARK: - 空状态

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "character.textbox")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.6))

            Text(lang.text("暂无填空练习内容", "No fill-in-the-blank content"))
                .font(.headline)
                .foregroundColor(.secondary)

            Text(lang.text("请先打开音视频文件并进行智能断句", "Please open media and perform segmentation"))
                .font(.subheadline)
                .foregroundColor(.secondary.opacity(0.7))
        }
    }
}

// MARK: - AppKit 原生单词填空输入槽 (NSTextField)

public final class WordSlotNSTextField: NSTextField {
    var onMouseDown: (() -> Void)?
    var onWindowAttach: (() -> Void)?

    override public func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onMouseDown?()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            onWindowAttach?()
        }
    }
}

public struct FillInBlankWordSlotField: NSViewRepresentable {
    public let wordIndex: Int
    public let targetWord: String
    public var draft: String = ""
    public let font: NSFont
    public let textColor: NSColor
    public let isCompleted: Bool
    public let isFocused: Bool
    public let onInputChanged: (String) -> Void
    public let onBecameFocused: () -> Void
    public let onTab: () -> Void
    public let onBacktab: () -> Void
    public let onReplayAudio: () -> Void

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> WordSlotNSTextField {
        let tf = WordSlotNSTextField()
        tf.identifier = NSUserInterfaceItemIdentifier("fill-word-\(wordIndex)")
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.alignment = .center
        tf.maximumNumberOfLines = 1
        tf.usesSingleLineMode = true
        tf.lineBreakMode = .byClipping
        tf.stringValue = draft
        tf.font = font
        tf.textColor = isCompleted ? NSColor(StudyMateMediaStyle.accent) : textColor
        tf.isEditable = !isCompleted
        tf.isSelectable = !isCompleted
        let coordinator = context.coordinator
        tf.delegate = coordinator
        tf.onMouseDown = { [weak coordinator] in
            coordinator?.parent.onBecameFocused()
        }
        tf.onWindowAttach = { [weak coordinator, weak tf] in
            guard let coordinator, let tf else { return }
            if coordinator.parent.isFocused && !coordinator.parent.isCompleted {
                DispatchQueue.main.async {
                    if let win = tf.window,
                       coordinator.parent.isFocused && !coordinator.parent.isCompleted {
                        win.makeFirstResponder(tf)
                    }
                }
            }
        }
        coordinator.textField = tf
        return tf
    }

    public func updateNSView(_ nsView: WordSlotNSTextField, context: Context) {
        let wasFocused = context.coordinator.parent.isFocused
        context.coordinator.parent = self
        nsView.font = font

        if isCompleted {
            context.coordinator.stopMonitoring()
            if nsView.stringValue != targetWord {
                nsView.stringValue = targetWord
            }
            nsView.isEditable = false
            nsView.isSelectable = false
            nsView.textColor = NSColor(StudyMateMediaStyle.accent)
        } else {
            nsView.isEditable = true
            nsView.isSelectable = true
            if !context.coordinator.isHinting {
                if nsView.stringValue != draft { nsView.stringValue = draft }
                nsView.textColor = textColor
            }

            if isFocused {
                context.coordinator.startMonitoringIfNeeded()
                if let window = nsView.window {
                    let currentFR = window.firstResponder
                    let isAlreadyFR = (currentFR === nsView) || (currentFR === nsView.currentEditor())
                    if !isAlreadyFR && !wasFocused {
                        DispatchQueue.main.async {
                            if let win = nsView.window,
                               context.coordinator.parent.isFocused && !context.coordinator.parent.isCompleted {
                                win.makeFirstResponder(nsView)
                            }
                        }
                    }
                }
            } else {
                context.coordinator.stopMonitoring()
            }
        }
    }

    public class Coordinator: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
        var parent: FillInBlankWordSlotField
        weak var textField: WordSlotNSTextField?
        private var eventMonitor: Any?
        private(set) var isHinting: Bool = false
        private var savedUserInput: String = ""

        init(_ parent: FillInBlankWordSlotField) {
            self.parent = parent
            super.init()
        }

        deinit {
            stopMonitoring()
        }

        func startMonitoringIfNeeded() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self else { return event }
                return self.handleKeyEvent(event)
            }
        }

        func stopMonitoring() {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
            if isHinting {
                cancelHint()
            }
        }

        private func cancelHint() {
            guard isHinting, let tf = textField else { return }
            isHinting = false
            tf.stringValue = savedUserInput
            tf.textColor = parent.isCompleted ? NSColor(StudyMateMediaStyle.accent) : parent.textColor
            if let editor = tf.currentEditor() {
                let len = (savedUserInput as NSString).length
                editor.selectedRange = NSRange(location: len, length: 0)
            }
        }

        func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
            guard let tf = textField else { return event }
            if let window = tf.window {
                if let keyWin = NSApp.keyWindow, keyWin !== window {
                    return event
                }
                let fr = window.firstResponder
                let isFieldActive = (fr === tf) || (tf.currentEditor() != nil && fr === tf.currentEditor()) || (fr == nil && parent.isFocused)
                guard isFieldActive, !parent.isCompleted else { return event }
            } else {
                guard parent.isFocused, !parent.isCompleted else { return event }
            }

            // 1. 快捷键 ⌘R / ⌘r：重听当前句（防止被 NSTextView 原生 showRuler: 吞掉）
            let isCmd = event.modifierFlags.contains(.command)
            let char = event.charactersIgnoringModifiers?.lowercased()
            if isCmd && char == "r" {
                if event.type == .keyDown {
                    parent.onReplayAudio()
                }
                return nil
            }

            // 2. 空格键：提示键（按下显示目标单词，松开隐藏恢复）
            let noSpecialModifiers = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            if event.keyCode == 49 && noSpecialModifiers {
                if event.type == .keyDown {
                    if !event.isARepeat && !isHinting {
                        isHinting = true
                        savedUserInput = tf.stringValue
                        tf.stringValue = parent.targetWord
                        tf.textColor = NSColor.systemOrange
                    }
                    return nil
                } else if event.type == .keyUp {
                    if isHinting {
                        isHinting = false
                        tf.stringValue = savedUserInput
                        tf.textColor = parent.textColor
                        if let editor = tf.currentEditor() {
                            let len = (savedUserInput as NSString).length
                            editor.selectedRange = NSRange(location: len, length: 0)
                        }
                    }
                    return nil
                }
            }

            return event
        }

        public func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            guard !isHinting else { return }
            if tf.stringValue.contains(" ") {
                tf.stringValue = tf.stringValue.filter { $0 != " " }
            }
            let text = tf.stringValue
            parent.onInputChanged(text)
        }

        public func controlTextDidBeginEditing(_ obj: Notification) {
            parent.onBecameFocused()
            startMonitoringIfNeeded()
        }

        public func controlTextDidEndEditing(_ obj: Notification) {
            if isHinting {
                cancelHint()
            }
            stopMonitoring()
        }

        public func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            if isHinting {
                return false
            }
            if let str = replacementString, str.contains(" ") {
                let filtered = str.filter { $0 != " " }
                if filtered.isEmpty {
                    return false
                }
                textView.insertText(filtered, replacementRange: affectedCharRange)
                return false
            }
            return true
        }

        public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                parent.onTab()
                return true
            } else if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                parent.onBacktab()
                return true
            }
            return false
        }
    }
}

// MARK: - 单句填空交互卡片

struct FillInBlankCardView: View {
    let seg: SentenceSegment
    let showOriginal: Bool
    let showTranslation: Bool
    let originalFont: NSFont
    let originalColor: NSColor
    let translationFont: NSFont
    let translationColor: NSColor
    let language: AppLanguage
    let replayRevision: Int
    let onReplayAudio: () -> Void
    let onSentenceCompleted: () -> Void

    @State private var tokens: [FillInBlankToken] = []
    @State private var drafts: [Int: String] = [:]
    @State private var completedWords: Set<Int> = []
    @State private var isSentenceFinished: Bool = false
    @State private var isSentenceCompletedAndShowingTranslation: Bool = false
    @State private var focusedWordIndex: Int? = 0

    private var totalWordCount: Int {
        tokens.filter { $0.isWord }.count
    }

    private var transText: String {
        seg.translation.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 第一行：原文展示或填空槽
            if showOriginal {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("#\(seg.index)")
                        .font(Font(originalFont))
                        .foregroundColor(Color(originalColor).opacity(0.75))

                    Text(seg.text)
                        .font(Font(originalFont))
                        .foregroundColor(Color(originalColor))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                FillInBlankFlowLayout(horizontalSpacing: 4, verticalSpacing: 10) {
                    // 序号标记（如 #16 ）
                    Text("#\(seg.index)")
                        .font(Font(originalFont))
                        .foregroundColor(Color(originalColor).opacity(0.75))
                        .padding(.trailing, 2)

                    ForEach(tokens) { token in
                        if token.isWord, let wIdx = token.wordIndex {
                            wordSlotView(token: token, wordIndex: wIdx)
                        } else {
                            // 标点符号与空格：基线对齐单词输入槽文本（补偿输入框下划线高度与内边距）
                            Text(token.text)
                                .font(Font(originalFont))
                                .foregroundColor(Color(originalColor).opacity(0.9))
                                .padding(.bottom, 6)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    ensureFocus()
                }
            }

            // 第二行：译文（如果开启，或者整句填对完成时即刻展示）
            if (showTranslation || isSentenceCompletedAndShowingTranslation) && !transText.isEmpty {
                Text(transText)
                    .font(Font(translationFont))
                    .foregroundColor(Color(translationColor))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }

            // 整句填对完成状态下：提供“重新练习”交互
            if isSentenceFinished || isSentenceCompletedAndShowingTranslation {
                HStack(spacing: 8) {
                    Button {
                        setupSentence()
                        onReplayAudio()
                    } label: {
                        Label(
                            language == .en ? "Practice Again" : "重新练习",
                            systemImage: "arrow.counterclockwise"
                        )
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(language == .en ? "Reset blanks and practice this sentence again (⌘R)" : "清空输入并重新练习本句（可按 ⌘R）")

                    Spacer()
                }
                .padding(.top, 4)
            }
        }
        .onAppear {
            setupSentence()
        }
        .onChange(of: seg) { old, new in
            if old.id != new.id || old.text != new.text { setupSentence() }
        }
        .onChange(of: replayRevision) { _, _ in
            if isSentenceFinished { setupSentence() }
        }
        .onChange(of: showOriginal) { oldVal, newVal in
            if oldVal && !newVal {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    ensureFocus()
                }
            }
        }
        .onChange(of: focusedWordIndex) { _, newIdx in
            if newIdx == nil && !isSentenceFinished && !showOriginal {
                DispatchQueue.main.async {
                    ensureFocus()
                }
            }
        }
    }

    private func setupSentence() {
        tokens = FillInBlankTokenizer.tokenize(seg.text)
        drafts = [:]
        completedWords = []
        isSentenceFinished = false
        isSentenceCompletedAndShowingTranslation = false
        focusedWordIndex = 0

        if totalWordCount == 0 {
            isSentenceFinished = true
            isSentenceCompletedAndShowingTranslation = true
            onSentenceCompleted()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                ensureFocus()
            }
        }
    }

    private func ensureFocus() {
        guard !isSentenceFinished, totalWordCount > 0 else { return }
        if let current = focusedWordIndex, !completedWords.contains(current) {
            focusedWordIndex = current
        } else if let next = nextIncompleteWordIndex(from: focusedWordIndex ?? 0) {
            focusedWordIndex = next
        } else if let first = nextIncompleteWordIndex(from: 0) {
            focusedWordIndex = first
        }
    }

    // MARK: - 单个单词填空输入槽

    @ViewBuilder
    private func wordSlotView(token: FillInBlankToken, wordIndex: Int) -> some View {
        let isCompleted = completedWords.contains(wordIndex)
        let isFocused = (focusedWordIndex == wordIndex)
        let estimatedWidth = estimatedSlotWidth(for: token.text)
        let slotHeight = max(28.0, ceil(originalFont.pointSize) + 8.0)

        VStack(spacing: 2) {
            FillInBlankWordSlotField(
                wordIndex: wordIndex,
                targetWord: token.text,
                draft: drafts[wordIndex, default: ""],
                font: originalFont,
                textColor: originalColor,
                isCompleted: isCompleted,
                isFocused: isFocused,
                onInputChanged: { input in
                    drafts[wordIndex] = input
                    checkWordMatch(wordIndex: wordIndex, input: input, target: token.text)
                },
                onBecameFocused: {
                    if !isCompleted {
                        focusedWordIndex = wordIndex
                    }
                },
                onTab: {
                    if let next = nextIncompleteWordIndex(from: wordIndex + 1) {
                        focusedWordIndex = next
                    }
                },
                onBacktab: {
                    if let prev = previousIncompleteWordIndex(before: wordIndex) {
                        focusedWordIndex = prev
                    }
                },
                onReplayAudio: {
                    if isSentenceFinished {
                        setupSentence()
                    }
                    onReplayAudio()
                }
            )
            .frame(width: estimatedWidth, height: slotHeight)

            // 动态下划线
            Rectangle()
                .frame(width: estimatedWidth, height: isFocused ? 2.5 : 1.5)
                .foregroundColor(
                    isCompleted
                        ? StudyMateMediaStyle.accent.opacity(0.8)
                        : (isFocused ? StudyMateMediaStyle.accent : Color(originalColor).opacity(0.45))
                )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !isCompleted {
                focusedWordIndex = wordIndex
            }
        }
    }

    private func estimatedSlotWidth(for word: String) -> CGFloat {
        let targetSize = (word as NSString).size(withAttributes: [.font: originalFont])
        return max(42.0, ceil(targetSize.width) + 16.0)
    }

    // MARK: - 匹配与焦点控制

    private func checkWordMatch(wordIndex: Int, input: String, target: String) {
        guard !completedWords.contains(wordIndex) else { return }

        if FillInBlankTokenizer.isMatch(input: input, target: target) {
            completedWords.insert(wordIndex)

            if completedWords.count >= totalWordCount && !isSentenceFinished {
                // 整句完成！
                isSentenceFinished = true
                focusedWordIndex = nil
                isSentenceCompletedAndShowingTranslation = true
                playVictoryChime()
                onSentenceCompleted()
            } else {
                // 聚焦到下一个未完成槽位，保持焦点在下一个横线上
                if let next = nextIncompleteWordIndex(from: wordIndex + 1) {
                    focusedWordIndex = next
                } else if let firstRemaining = nextIncompleteWordIndex(from: 0) {
                    focusedWordIndex = firstRemaining
                }
            }
        }
    }

    private func nextIncompleteWordIndex(from start: Int = 0) -> Int? {
        for i in start..<totalWordCount {
            if !completedWords.contains(i) {
                return i
            }
        }
        if start > 0 {
            for i in 0..<start {
                if !completedWords.contains(i) {
                    return i
                }
            }
        }
        return nil
    }

    private func previousIncompleteWordIndex(before current: Int) -> Int? {
        if current > 0 {
            for i in (0..<current).reversed() {
                if !completedWords.contains(i) {
                    return i
                }
            }
        }
        for i in (current..<totalWordCount).reversed() {
            if !completedWords.contains(i) {
                return i
            }
        }
        return nil
    }

    private func playVictoryChime() {
        if let sound = NSSound(named: "Hero") {
            sound.play()
        } else if let sound = NSSound(contentsOfFile: "/System/Library/Sounds/Hero.aiff", byReference: true) {
            sound.play()
        } else if let sound = NSSound(named: "Glass") {
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}
