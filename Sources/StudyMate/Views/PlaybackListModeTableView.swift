import SwiftUI
import AppKit

/// 列表模式文字展示表格（上方多列表格展示序号、[角色]、原文、译文；底部固定核心播放控制条）
/// 具备独立 Equatable 行渲染、字幕字体/字号/颜色实时联动、无卡顿即时高亮跟随与跟随播放按钮。
public struct PlaybackListModeTableView: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var videoSubtitleSettings: VideoSubtitleSettings
    @ObservedObject var lang: LanguageManager

    @State private var followState = SegmentListFollowState()
    @State private var isUserScrolling: Bool = false
    @State private var scrollSuppressionToken: UUID?
    @State private var hasSpeakers: Bool = false
    @State private var isScrubbing: Bool = false
    @State private var isVolumeScrubbing: Bool = false

    public init(
        engine: PlaybackEngine,
        videoSubtitleSettings: VideoSubtitleSettings,
        lang: LanguageManager = .shared
    ) {
        self.engine = engine
        self.videoSubtitleSettings = videoSubtitleSettings
        self.lang = lang
    }

    /// 当前播放句的唯一标识符（严格与 engine.activeSegmentIndex 对应的 segment.id 同步，杜绝索引偏差）
    private var activeSegmentID: UUID? {
        guard let index = engine.activeSegmentIndex,
              engine.segments.indices.contains(index) else { return nil }
        return engine.segments[index].id
    }

    public var body: some View {
        VStack(spacing: 0) {
            if engine.segments.isEmpty {
                emptyStateView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tableHeaderView
                tableContentView
            }

            // 固定在文字列表区域与状态栏之间的核心播放控制区
            bottomPlaybackControlBar
        }
        .background(StudyMateMediaStyle.windowBackground)
        .onAppear {
            updateHasSpeakers()
        }
        .onChange(of: engine.segments) { _, _ in
            updateHasSpeakers()
        }
    }

    private func updateHasSpeakers() {
        hasSpeakers = engine.segments.contains { !$0.speakerIDs.isEmpty }
    }

    private func markUserScroll() {
        guard followState.followsPlayback else { return }
        followState.markUserScroll()
        let token = UUID()
        scrollSuppressionToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            guard token == scrollSuppressionToken, followState.followsPlayback else { return }
            followState.resumeFollowing()
        }
    }

    // MARK: - 表头区域

    private var tableHeaderView: some View {
        HStack(spacing: 0) {
            // 序号列
            Text(lang.text("序号", "No."))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 55, alignment: .center)

            columnDivider

            // 角色列（条件列：断句中包含角色如 s1, s2 时显示）
            if hasSpeakers {
                Text(lang.text("角色", "Role"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 65, alignment: .center)

                columnDivider
            }

            // 原文列
            if videoSubtitleSettings.isOriginalVisible(for: .list) {
                Text(lang.text("原文", "Original"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)

                if videoSubtitleSettings.isTranslationVisible(for: .list) {
                    columnDivider
                }
            }

            // 译文列
            if videoSubtitleSettings.isTranslationVisible(for: .list) {
                Text(lang.text("译文", "Translation"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }

            // 若原文与译文均隐藏时的提示表头
            if !videoSubtitleSettings.isOriginalVisible(for: .list) && !videoSubtitleSettings.isTranslationVisible(for: .list) {
                Text(lang.text("提示", "Notice"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }

            // 播放时自动跟随当前句开关（与视频模式断句列表右边按钮样式完全一致）
            Button(action: {
                followState.toggle()
            }) {
                Image(systemName: "target")
                    .frame(width: 24, height: 24)
                    .foregroundColor(followState.shouldFollow ? .primary : .secondary.opacity(0.45))
                    .help(StudyMateShortcutCatalog.help(
                        followState.shouldFollow
                            ? lang.text("播放时自动跟随当前句", "Follow the active sentence during playback")
                            : lang.text("已暂停自动跟随，点击恢复", "Automatic following is paused; click to resume"),
                        shortcut: .followActiveSentence
                    ))
            }
            .studymateChromeButton(shape: .circle)
            .focusable(false)
            .help(StudyMateShortcutCatalog.help(
                followState.shouldFollow
                    ? lang.text("播放时自动跟随当前句", "Follow the active sentence during playback")
                    : lang.text("已暂停自动跟随，点击恢复", "Automatic following is paused; click to resume"),
                shortcut: .followActiveSentence
            ))
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .padding(.trailing, 8)
        }
        .frame(height: 32)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(StudyMateMediaStyle.separator),
            alignment: .bottom
        )
    }

    private var columnDivider: some View {
        Rectangle()
            .fill(StudyMateMediaStyle.separator.opacity(0.6))
            .frame(width: 1, height: 16)
    }

    // MARK: - 表体内容区域

    private var tableContentView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                PlaybackListModeRowsView(
                    segments: engine.segments,
                    activeSegmentID: activeSegmentID,
                    hasSpeakers: hasSpeakers,
                    showOriginal: videoSubtitleSettings.isOriginalVisible(for: .list),
                    showTranslation: videoSubtitleSettings.isTranslationVisible(for: .list),
                    originalFont: videoSubtitleSettings.makeOriginalFont(for: .list),
                    originalColor: videoSubtitleSettings.originalNSColor(for: .list),
                    translationFont: videoSubtitleSettings.makeTranslationFont(for: .list),
                    translationColor: videoSubtitleSettings.translationNSColor(for: .list),
                    language: lang.currentLanguage,
                    onSelect: { id in
                        engine.jumpToSegment(id: id)
                        followState.resumeFollowing()
                    },
                    onDoubleClick: { id in
                        engine.jumpToSegment(id: id)
                        engine.play()
                        followState.resumeFollowing()
                    },
                    onUserScroll: {
                        markUserScroll()
                    },
                    onScrollStateChanged: { scrolling in
                        if isUserScrolling != scrolling {
                            isUserScrolling = scrolling
                        }
                    }
                )
                .equatable()
            }
            .onAppear {
                if let idx = engine.activeSegmentIndex, idx >= 0, idx < engine.segments.count {
                    let targetID = engine.segments[idx].id
                    DispatchQueue.main.async {
                        proxy.scrollTo(targetID, anchor: nil)
                    }
                }
            }
            .onChange(of: engine.activeSegmentIndex) { _, newIndex in
                guard followState.shouldFollow else { return }
                guard let newIndex, newIndex >= 0, newIndex < engine.segments.count else { return }
                let targetID = engine.segments[newIndex].id
                DispatchQueue.main.async {
                    guard self.followState.shouldFollow else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(targetID, anchor: nil)
                    }
                }
            }
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
            Image(systemName: "text.badge.checkmark")
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

// MARK: - 表格多行容器（Equatable，隔离高频重绘，联动字体/字号/颜色）

private struct PlaybackListModeRowsView: View, Equatable {
    let segments: [SentenceSegment]
    let activeSegmentID: UUID?
    let hasSpeakers: Bool
    let showOriginal: Bool
    let showTranslation: Bool
    let originalFont: NSFont
    let originalColor: NSColor
    let translationFont: NSFont
    let translationColor: NSColor
    let language: AppLanguage
    let onSelect: (UUID) -> Void
    let onDoubleClick: (UUID) -> Void
    let onUserScroll: () -> Void
    let onScrollStateChanged: (Bool) -> Void

    static func == (lhs: PlaybackListModeRowsView, rhs: PlaybackListModeRowsView) -> Bool {
        lhs.activeSegmentID == rhs.activeSegmentID
            && lhs.hasSpeakers == rhs.hasSpeakers
            && lhs.showOriginal == rhs.showOriginal
            && lhs.showTranslation == rhs.showTranslation
            && lhs.originalFont == rhs.originalFont
            && lhs.originalColor == rhs.originalColor
            && lhs.translationFont == rhs.translationFont
            && lhs.translationColor == rhs.translationColor
            && lhs.language == rhs.language
            && lhs.segments == rhs.segments
    }

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(segments) { seg in
                PlaybackListModeRowView(
                    seg: seg,
                    isActive: activeSegmentID == seg.id,
                    hasSpeakers: hasSpeakers,
                    showOriginal: showOriginal,
                    showTranslation: showTranslation,
                    originalFont: originalFont,
                    originalColor: originalColor,
                    translationFont: translationFont,
                    translationColor: translationColor,
                    language: language,
                    onSelect: { onSelect(seg.id) },
                    onDoubleClick: { onDoubleClick(seg.id) }
                )
                .equatable()
                .id(seg.id)
            }
        }
        .padding(.bottom, 8)
        .background(
            ScrollViewInteractionObserver(
                onUserScroll: onUserScroll,
                onScrollStateChanged: onScrollStateChanged
            )
            .frame(width: 1, height: 1)
        )
    }
}

// MARK: - 单行组件（Equatable，联动字体/字号/颜色与自适应行高）

private struct PlaybackListModeRowView: View, Equatable {
    let seg: SentenceSegment
    let isActive: Bool
    let hasSpeakers: Bool
    let showOriginal: Bool
    let showTranslation: Bool
    let originalFont: NSFont
    let originalColor: NSColor
    let translationFont: NSFont
    let translationColor: NSColor
    let language: AppLanguage
    let onSelect: () -> Void
    let onDoubleClick: () -> Void

    @State private var isHovered: Bool = false

    static func == (lhs: PlaybackListModeRowView, rhs: PlaybackListModeRowView) -> Bool {
        lhs.seg == rhs.seg
            && lhs.isActive == rhs.isActive
            && lhs.hasSpeakers == rhs.hasSpeakers
            && lhs.showOriginal == rhs.showOriginal
            && lhs.showTranslation == rhs.showTranslation
            && lhs.originalFont == rhs.originalFont
            && lhs.originalColor == rhs.originalColor
            && lhs.translationFont == rhs.translationFont
            && lhs.translationColor == rhs.translationColor
            && lhs.language == rhs.language
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 当前句高亮左侧指示细条
            Rectangle()
                .fill(isActive ? StudyMateMediaStyle.accent : Color.clear)
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            // 序号（seg.index 已经是 1-based，从 1 开始；52pt + 3pt指示条 = 55pt对齐表头）
            Text("\(seg.index)")
                .font(.system(size: 12, weight: isActive ? .bold : .regular).monospacedDigit())
                .foregroundColor(isActive ? StudyMateMediaStyle.accent : .secondary)
                .frame(width: 52, alignment: .center)
                .padding(.top, 8)

            rowColumnDivider

            // 角色
            if hasSpeakers {
                HStack {
                    if !seg.speakerRoleLabel.isEmpty {
                        Text(seg.speakerRoleLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(seg.isSpeakerOverlap ? StudyMateMediaStyle.warning : Color.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background((seg.isSpeakerOverlap ? StudyMateMediaStyle.warning : Color.purple).opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    } else {
                        Text("—")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.35))
                    }
                }
                .frame(width: 65, alignment: .center)
                .padding(.top, 8)

                rowColumnDivider
            }

            // 原文
            if showOriginal {
                cellTextView(text: seg.text, isOriginal: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                if showTranslation {
                    rowColumnDivider
                }
            }

            // 译文
            if showTranslation {
                cellTextView(text: seg.translation, isOriginal: false)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            // 若原文与译文均隐藏时的行提示
            if !showOriginal && !showTranslation {
                let hiddenNotice = (language == .en)
                    ? "Subtitles hidden (toggle with ⌥⌘O / ⌥⌘T)"
                    : "原文与译文均已隐藏（可通过工具栏或快捷键 ⌥⌘O / ⌥⌘T 重新显示）"
                Text(hiddenNotice)
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .background(rowBackground(isActive: isActive, isHovered: isHovered, index: seg.index))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(StudyMateMediaStyle.separator.opacity(0.35)),
            alignment: .bottom
        )
        .onHover { inside in
            if isHovered != inside {
                isHovered = inside
            }
        }
        .onTapGesture(perform: onSelect)
    }

    @ViewBuilder
    private func cellTextView(text: String, isOriginal: Bool) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let font = isOriginal ? originalFont : translationFont
        let color = isOriginal ? originalColor : translationColor

        if trimmed.isEmpty {
            if isOriginal {
                let sentencePlaceholder = (language == .en)
                    ? "Sentence \(seg.index)"
                    : "第 \(seg.index) 句"
                Text(sentencePlaceholder)
                    .font(Font(font))
                    .foregroundColor(Color(color).opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("—")
                    .font(Font(font))
                    .foregroundColor(Color(color).opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ZStack(alignment: .topLeading) {
                // 隐形 Text 用于在 SwiftUI 中撑开自适应动态行高，使用相同字体以精确匹配行高
                Text(trimmed)
                    .font(Font(font))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(0)

                DictionarySelectableText(
                    text: trimmed,
                    font: font,
                    color: color,
                    context: [seg.text, seg.translation].filter { !$0.isEmpty }.joined(separator: "\n"),
                    onSingleClick: onSelect,
                    onDoubleClick: onDoubleClick
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var rowColumnDivider: some View {
        Rectangle()
            .fill(StudyMateMediaStyle.separator.opacity(0.25))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
    }

    private func rowBackground(isActive: Bool, isHovered: Bool, index: Int) -> Color {
        if isActive {
            return StudyMateMediaStyle.accent.opacity(0.12)
        }
        if isHovered {
            return Color.primary.opacity(0.04)
        }
        if index % 2 == 1 {
            return Color(nsColor: .controlBackgroundColor).opacity(0.35)
        }
        return Color.clear
    }
}
