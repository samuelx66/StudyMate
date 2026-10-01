import AppKit
import SwiftUI
#if canImport(StudyMatePackage)
import StudyMatePackage
#endif

/// 句子模式主视图（Sentence Mode View）
///
/// 在波形图与底部固定播放控制区之间，居中呈现当前正在播放的单个句子。
/// 严格遵循极简学习界面规范：
/// 1. 仅显示“序号 + 原文或译文”，若原文与译文均开启则分为两行展示；
/// 2. 除了序号、原文、译文之外无任何杂质元素（无表头、无角色列、无干扰边框）；
/// 3. 全面联动工具栏原文字幕与译文字幕显隐，以及字幕字体设置（字体名称、字号、加粗、斜体、颜色）；
/// 4. 底部常驻核心播放控制条（FloatingVideoOSDView），支持 4 种播放模式、单句复读次数、跟读停顿倒计时等全部功能；
/// 5. 原文与译文均使用 DictionarySelectableText，完整支持原生取词、查词、发音与加入生词本。
public struct PlaybackSentenceModeView: View {
    @ObservedObject private var engine: PlaybackEngine
    @ObservedObject private var activeSegmentState: ActiveSegmentPresentationState
    @ObservedObject private var videoSubtitleSettings: VideoSubtitleSettings
    @ObservedObject private var lang: LanguageManager
    @ObservedObject private var phoneticManager: PhoneticEngineManager = .shared
    @ObservedObject private var clock: PlaybackClock

    @State private var isScrubbing: Bool = false
    @State private var isVolumeScrubbing: Bool = false

    public init(
        engine: PlaybackEngine,
        videoSubtitleSettings: VideoSubtitleSettings,
        lang: LanguageManager = .shared
    ) {
        self.engine = engine
        self._activeSegmentState = ObservedObject(wrappedValue: engine.activeSegmentState)
        self.videoSubtitleSettings = videoSubtitleSettings
        self.lang = lang
        self._clock = ObservedObject(wrappedValue: engine.clock)
    }

    /// 当前激活的断句段落；若尚未定位，默认显示第一句
    private var currentSegment: SentenceSegment? {
        if let index = activeSegmentState.index,
           engine.segments.indices.contains(index) {
            return engine.segments[index]
        }
        return engine.segments.first
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 中间单句居中视窗
            if engine.segments.isEmpty {
                emptyStateView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let seg = currentSegment {
                sentenceAreaView(seg: seg)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyStateView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // 底部固定播放控制条（与列表模式对齐，4种播放循环模式、复读次数、停顿跟读等完全可用）
            bottomPlaybackControlBar
        }
        .background(StudyMateMediaStyle.windowBackground)
        .background(
            Button("") {
                phoneticManager.togglePhonetics()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .opacity(0)
        )
    }

    // MARK: - 句子显示主区域

    @ViewBuilder
    private func sentenceAreaView(seg: SentenceSegment) -> some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 0) {
                    Spacer(minLength: 20)

                    PlaybackSentenceCardView(
                        seg: seg,
                        currentTime: clock.currentTime,
                        showOriginal: videoSubtitleSettings.isOriginalVisible(for: .sentence),
                        showTranslation: videoSubtitleSettings.isTranslationVisible(for: .sentence),
                        showPhonetics: phoneticManager.showPhonetics,
                        originalFont: videoSubtitleSettings.makeOriginalFont(for: .sentence),
                        originalColor: videoSubtitleSettings.originalNSColor(for: .sentence),
                        translationFont: videoSubtitleSettings.makeTranslationFont(for: .sentence),
                        translationColor: videoSubtitleSettings.translationNSColor(for: .sentence),
                        language: lang.currentLanguage,
                        availableSpeakers: engine.currentSpeakerNames,
                        sentenceIndex: seg.index,
                        matchingCount: engine.countSegments(withSpeakerRoleLabel: seg.speakerRoleLabel),
                        onToggleBookmark: {
                            engine.toggleBookmark(for: seg.id)
                        },
                        onSeekToToken: { offset in
                            engine.seek(to: seg.startTime + offset)
                            engine.play()
                        },
                        onRegenerateTokens: {
                            engine.regenerateOriginalText(segmentIDs: [seg.id])
                        },
                        onRenameSpeaker: { fromRole, toName, scope in
                            engine.renameSpeaker(fromRole: fromRole, toName: toName, scope: scope, segmentID: seg.id)
                        },
                        onSelect: {
                            engine.jumpToSegment(id: seg.id)
                        },
                        onDoubleClick: {
                            engine.jumpToSegment(id: seg.id)
                            engine.play()
                        }
                    )
                    .equatable()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 48)

                    Spacer(minLength: 20)
                }
                .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .id(seg.id)
        }
    }

    // MARK: - 底部固定播放控制条

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
            Image(systemName: "text.quote")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.6))

            Text(lang.text("暂无断句内容", "No sentences available"))
                .font(.headline)
                .foregroundColor(.secondary)

            Text(lang.text("请先打开音视频文件并进行智能断句", "Please open media and perform segmentation"))
                .font(.subheadline)
                .foregroundColor(.secondary.opacity(0.7))
        }
    }
}

// MARK: - 单句展示卡片（Equatable 隔离高频刷新，极简无多余修饰）

struct PlaybackSentenceCardView: View, Equatable {
    let seg: SentenceSegment
    let currentTime: Double
    let showOriginal: Bool
    let showTranslation: Bool
    let showPhonetics: Bool
    let originalFont: NSFont
    let originalColor: NSColor
    let translationFont: NSFont
    let translationColor: NSColor
    let language: AppLanguage
    var availableSpeakers: [String: String] = [:]
    var sentenceIndex: Int? = nil
    var matchingCount: Int = 1
    let onToggleBookmark: () -> Void
    let onSeekToToken: (Double) -> Void
    let onRegenerateTokens: () -> Void
    let onRenameSpeaker: ((String, String, SpeakerChangeScope) -> Void)?
    let onSelect: () -> Void
    let onDoubleClick: () -> Void

    @State private var isShowingRenamePopover: Bool = false
    @State private var renameText: String = ""
    @State private var isShowingContextPopover: Bool = false
    @State private var selectedVocabCard: StudyMatePackageVocabularyCard? = nil

    static func activeTokenIndex(for tokens: [StudyMatePackageWordToken]?, baseTime: Double, time: Double) -> Int? {
        guard let tokens, !tokens.isEmpty else { return nil }
        let relTime = time - baseTime
        guard relTime >= 0 else { return nil }

        for (i, token) in tokens.enumerated() {
            // 在当前词自身的时间区间内
            if relTime >= token.startTime && relTime < token.endTime {
                return i
            }
            // 在与下一词之间微小的停顿间隙中（<= 0.35s），平滑维持当前词的高亮，避免词间跳闪
            if i + 1 < tokens.count {
                let nextToken = tokens[i + 1]
                if relTime >= token.endTime && relTime < nextToken.startTime && (nextToken.startTime - token.endTime) <= 0.35 {
                    return i
                }
            } else {
                // 句末最后一个词，延展 0.25 秒平滑过渡
                if relTime >= token.endTime && relTime < token.endTime + 0.25 {
                    return i
                }
            }
        }
        return nil
    }

    private var activeTokens: [StudyMatePackageWordToken]? {
        seg.reconciledWordTokens()
    }

    static func == (lhs: PlaybackSentenceCardView, rhs: PlaybackSentenceCardView) -> Bool {
        lhs.seg == rhs.seg
            && Self.activeTokenIndex(for: lhs.activeTokens, baseTime: lhs.seg.startTime, time: lhs.currentTime)
                == Self.activeTokenIndex(for: rhs.activeTokens, baseTime: rhs.seg.startTime, time: rhs.currentTime)
            && lhs.showOriginal == rhs.showOriginal
            && lhs.showTranslation == rhs.showTranslation
            && lhs.showPhonetics == rhs.showPhonetics
            && lhs.originalFont == rhs.originalFont
            && lhs.originalColor == rhs.originalColor
            && lhs.translationFont == rhs.translationFont
            && lhs.translationColor == rhs.translationColor
            && lhs.language == rhs.language
            && lhs.availableSpeakers == rhs.availableSpeakers
            && lhs.sentenceIndex == rhs.sentenceIndex
            && lhs.matchingCount == rhs.matchingCount
    }

    private var origText: String {
        seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var transText: String {
        seg.translation.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var contextString: String {
        [origText, transText].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 顶部元数据指示栏：序号、原片时序坐标、角色、难句收藏、语境快照
            HStack(spacing: 8) {
                Text("#\(seg.index)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(StudyMateMediaStyle.accent)

                if let coordinate = seg.formattedCoordinate(language: language) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 9))
                        Text(coordinate)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
                    .help(language == .en ? "Original media coordinate (source, sequence number, timestamp)" : "原片时序坐标（来源媒体、原片序号、时间戳）")
                } else if let origIdx = seg.originalIndex, origIdx > 0 {
                    Text(language == .en ? "Orig #\(origIdx)" : "原#\(origIdx)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                if !seg.speakerRoleLabel.isEmpty {
                    SpeakerBadgeButton(
                        speakerRoleLabel: seg.speakerRoleLabel,
                        speakerRole: seg.speakerRole,
                        isOverlap: seg.isSpeakerOverlap,
                        font: .system(size: 11, weight: .bold, design: .monospaced),
                        tintColor: StudyMateMediaStyle.accent,
                        shape: .capsule,
                        language: language,
                        availableSpeakers: availableSpeakers,
                        sentenceIndex: sentenceIndex,
                        matchingCount: matchingCount,
                        onSave: { fromRole, toName, scope in
                            onRenameSpeaker?(fromRole, toName, scope)
                        }
                    )
                }

                Button(action: onToggleBookmark) {
                    Image(systemName: seg.isBookmarked ? "star.fill" : "star")
                        .font(.system(size: 12, weight: seg.isBookmarked ? .semibold : .medium))
                        .foregroundColor(seg.isBookmarked ? Color.yellow : Color(nsColor: .systemYellow).opacity(0.85))
                }
                .buttonStyle(.plain)
                .help(language == .en ? "Toggle bookmark" : "切换星标难句")

                if seg.contextBefore != nil || seg.contextAfter != nil {
                    Button {
                        isShowingContextPopover.toggle()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "quote.opening")
                                .font(.system(size: 10))
                            Text(language == .en ? "Context" : "语境")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(language == .en ? "Show surrounding context snapshot" : "查看前后文语境快照")
                    .popover(isPresented: $isShowingContextPopover, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(language == .en ? "Surrounding Context" : "前后文语境快照")
                                .font(.headline)
                                .padding(.bottom, 2)

                            if let before = seg.contextBefore, !before.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(language == .en ? "Previous Sentence:" : "前文语境：")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(before)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(language == .en ? "Current Sentence:" : "当前句子：")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(seg.text)
                                    .font(.subheadline)
                                    .bold()
                                    .foregroundColor(StudyMateMediaStyle.accent)
                            }

                            if let after = seg.contextAfter, !after.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(language == .en ? "Next Sentence:" : "后文语境：")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(after)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(14)
                        .frame(width: 320)
                    }
                }

                Button {
                    PhoneticEngineManager.shared.togglePhonetics()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "character.phonetic")
                            .font(.system(size: 10))
                        Text(language == .en ? "Phonetics" : "注音")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(showPhonetics ? StudyMateMediaStyle.accent : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(showPhonetics ? StudyMateMediaStyle.accent.opacity(0.15) : Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(language == .en ? "Toggle phonetics (⌥⌘P)" : "切换注音显示 (⌥⌘P)")

                if let tokens = activeTokens, !tokens.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "waveform.and.mic")
                            .font(.system(size: 10))
                        Text(language == .en ? "\(tokens.count) Words" : "\(tokens.count) 词同步")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(StudyMateMediaStyle.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(StudyMateMediaStyle.accent.opacity(0.12))
                    .clipShape(Capsule())
                    .help(language == .en ? "Whisper word timestamps active: real-time highlight during playback, click word to play." : "Whisper 词级时间戳已启用：播放时实时卡拉OK高亮，点击下方任意单词即刻发音。")
                } else {
                    Button(action: onRegenerateTokens) {
                        HStack(spacing: 3) {
                            Image(systemName: "waveform.badge.plus")
                                .font(.system(size: 10))
                            Text(language == .en ? "Word Sync" : "识别词级时间戳")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(language == .en ? "Use Whisper to recognize word-level timestamps for this sentence" : "使用 Whisper 识别当前句子的词级时间戳，开启卡拉OK发音同步")
                }

                Spacer()
            }

            if showOriginal && showTranslation {
                // 原文和译文都显示时：分为两行展示
                renderOriginalSection()

                if !transText.isEmpty {
                    translationTextView(prefix: "")
                }
            } else if showOriginal {
                renderOriginalSection()
            } else if showTranslation {
                translationTextView(prefix: "#\(seg.index) ")
            } else {
                let hiddenNotice = (language == .en)
                    ? "Subtitles hidden (toggle with ⌥⌘O / ⌥⌘T)"
                    : "原文与译文均已隐藏（可通过工具栏或快捷键 ⌥⌘O / ⌥⌘T 重新显示）"
                Text(hiddenNotice)
                    .font(.callout)
                    .foregroundColor(.secondary.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            // 关联生词卡片（Associated Vocabulary Words）
            if let words = seg.associatedWords, !words.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 11))
                        .foregroundColor(StudyMateMediaStyle.accent)

                    Text(language == .en ? "Vocabulary:" : "关联生词:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)

                    ForEach(words) { card in
                        Button {
                            selectedVocabCard = card
                        } label: {
                            HStack(spacing: 3) {
                                Text(card.word)
                                    .font(.system(size: 11, weight: .bold))
                                    .underline(color: StudyMateMediaStyle.accent)
                                if let phonetic = card.phonetic, !phonetic.isEmpty {
                                    Text(phonetic)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(StudyMateMediaStyle.accent.opacity(0.12))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: Binding(
                            get: { selectedVocabCard?.id == card.id },
                            set: { if !$0 { selectedVocabCard = nil } }
                        ), arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(card.word)
                                        .font(.title3.bold())
                                    if let p = card.phonetic, !p.isEmpty {
                                        Text(p)
                                            .font(.caption.monospaced())
                                            .foregroundColor(.secondary)
                                    }
                                }
                                if let def = card.definition, !def.isEmpty {
                                    Text(def)
                                        .font(.body)
                                }
                            }
                            .padding(14)
                            .frame(minWidth: 200, maxWidth: 280)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button(action: onRegenerateTokens) {
                Label(
                    language == .en ? "Recognize Word Timestamps (Whisper)" : "使用 Whisper 识别词级时间戳",
                    systemImage: "waveform.badge.magnifyingglass"
                )
            }

            Button(action: onToggleBookmark) {
                Label(
                    seg.isBookmarked
                        ? (language == .en ? "Unstar Sentence" : "取消星标难句")
                        : (language == .en ? "Star Sentence" : "加入星标难句"),
                    systemImage: seg.isBookmarked ? "star.slash" : "star"
                )
            }

            if !seg.speakerRoleLabel.isEmpty {
                Button {
                    renameText = seg.speakerRole ?? seg.speakerRoleLabel
                    isShowingRenamePopover = true
                } label: {
                    Label(
                        language == .en ? "Rename Speaker (\(seg.speakerRoleLabel))…" : "修改说话人 (\(seg.speakerRoleLabel))…",
                        systemImage: "person.crop.circle.badge.checkmark"
                    )
                }
            }

            Divider()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(origText, forType: .string)
                MainStatusCenter.shared.showSuccess(language == .en ? "Copied original text" : "已复制原文")
            } label: {
                Label(language == .en ? "Copy Original Text" : "复制原文", systemImage: "doc.on.doc")
            }

            if !transText.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transText, forType: .string)
                    MainStatusCenter.shared.showSuccess(language == .en ? "Copied translation" : "已复制译文")
                } label: {
                    Label(language == .en ? "Copy Translation" : "复制译文", systemImage: "doc.on.doc")
                }
            }
        }
        .popover(isPresented: $isShowingRenamePopover, arrowEdge: .bottom) {
            SpeakerRenamePopoverContent(
                roleLabel: seg.speakerRoleLabel,
                initialText: SpeakerRoleManager.isCompositeRole(seg.speakerRoleLabel) ? "" : renameText,
                sentenceIndex: sentenceIndex,
                matchingCount: matchingCount,
                language: language,
                availableSpeakers: availableSpeakers,
                isPresented: $isShowingRenamePopover,
                onSave: { fromRole, toName, scope in
                    onRenameSpeaker?(fromRole, toName, scope)
                }
            )
        }
    }

    // MARK: - 原文渲染（支持自动注音与词级时间戳高亮）

    @ViewBuilder
    private func renderOriginalSection() -> some View {
        if let tokens = activeTokens, !tokens.isEmpty {
            wordTokensKaraokeView(tokens: tokens)
        } else if showPhonetics && !origText.isEmpty {
            RubyTextView(
                text: origText,
                fontSize: originalFont.pointSize,
                textColor: Color(originalColor),
                phoneticColor: StudyMateMediaStyle.accent,
                isPhoneticsVisible: true
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
        } else {
            originalTextView(prefix: "")
        }
    }

    private func wordTokensKaraokeView(tokens: [StudyMatePackageWordToken]) -> some View {
        let activeIdx = Self.activeTokenIndex(for: tokens, baseTime: seg.startTime, time: currentTime)

        return RubyFlowLayout(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { idx, token in
                let isTokenActive = (activeIdx == idx)
                let tokenColor: Color = isTokenActive ? StudyMateMediaStyle.accent : Color(originalColor)

                Button {
                    onSeekToToken(token.startTime)
                } label: {
                    if showPhonetics {
                        let phonetic = PhoneticEngine.phoneticText(for: token.text)
                        VStack(alignment: .center, spacing: 1) {
                            if let p = phonetic, !p.isEmpty {
                                Text(p)
                                    .font(.system(size: max(10, originalFont.pointSize * 0.52), weight: .medium, design: .rounded))
                                    .foregroundColor(isTokenActive ? StudyMateMediaStyle.accent : StudyMateMediaStyle.accent.opacity(0.75))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            } else {
                                Text(" ")
                                    .font(.system(size: max(10, originalFont.pointSize * 0.52)))
                                    .opacity(0)
                            }
                            Text(token.text)
                                .font(Font(originalFont))
                                .foregroundColor(tokenColor)
                        }
                    } else {
                        Text(token.text)
                            .font(Font(originalFont))
                            .foregroundColor(tokenColor)
                    }
                }
                .buttonStyle(.plain)
                .help(language == .en ? "Click to play: \(token.text) (\(String(format: "%.2fs", token.startTime)))" : "点击发音播放此词：\(token.text)（\(String(format: "%.2f秒", token.startTime))）")
            }
        }
    }

    // MARK: - 原文文本

    private func originalTextView(prefix: String) -> some View {
        let content = origText.isEmpty
            ? ((language == .en) ? "Sentence \(seg.index)" : "第 \(seg.index) 句")
            : origText
        let fullDisplay = prefix + content
        let isPlaceholder = origText.isEmpty

        return ZStack(alignment: .topLeading) {
            Text(fullDisplay)
                .font(Font(originalFont))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(0)

            if isPlaceholder {
                Text(fullDisplay)
                    .font(Font(originalFont))
                    .foregroundColor(Color(originalColor).opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                DictionarySelectableText(
                    text: fullDisplay,
                    font: originalFont,
                    color: originalColor,
                    context: contextString,
                    onSingleClick: onSelect,
                    onDoubleClick: onDoubleClick
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 译文文本

    private func translationTextView(prefix: String) -> some View {
        let content = transText.isEmpty ? "—" : transText
        let fullDisplay = prefix + content
        let isPlaceholder = transText.isEmpty

        return ZStack(alignment: .topLeading) {
            Text(fullDisplay)
                .font(Font(translationFont))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(0)

            if isPlaceholder {
                Text(fullDisplay)
                    .font(Font(translationFont))
                    .foregroundColor(Color(translationColor).opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                DictionarySelectableText(
                    text: fullDisplay,
                    font: translationFont,
                    color: translationColor,
                    context: contextString,
                    onSingleClick: onSelect,
                    onDoubleClick: onDoubleClick
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
