import AppKit
import SwiftUI

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
    @ObservedObject private var videoSubtitleSettings: VideoSubtitleSettings
    @ObservedObject private var lang: LanguageManager

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

    /// 当前激活的断句段落；若尚未定位，默认显示第一句
    private var currentSegment: SentenceSegment? {
        if let index = engine.activeSegmentIndex,
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
    }

    // MARK: - 句子显示主区域

    @ViewBuilder
    private func sentenceAreaView(seg: SentenceSegment) -> some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer(minLength: 20)

                    PlaybackSentenceCardView(
                        seg: seg,
                        showOriginal: videoSubtitleSettings.isOriginalVisible(for: .sentence),
                        showTranslation: videoSubtitleSettings.isTranslationVisible(for: .sentence),
                        originalFont: videoSubtitleSettings.makeOriginalFont(for: .sentence),
                        originalColor: videoSubtitleSettings.originalNSColor(for: .sentence),
                        translationFont: videoSubtitleSettings.makeTranslationFont(for: .sentence),
                        translationColor: videoSubtitleSettings.translationNSColor(for: .sentence),
                        language: lang.currentLanguage,
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

private struct PlaybackSentenceCardView: View, Equatable {
    let seg: SentenceSegment
    let showOriginal: Bool
    let showTranslation: Bool
    let originalFont: NSFont
    let originalColor: NSColor
    let translationFont: NSFont
    let translationColor: NSColor
    let language: AppLanguage
    let onSelect: () -> Void
    let onDoubleClick: () -> Void

    static func == (lhs: PlaybackSentenceCardView, rhs: PlaybackSentenceCardView) -> Bool {
        lhs.seg == rhs.seg
            && lhs.showOriginal == rhs.showOriginal
            && lhs.showTranslation == rhs.showTranslation
            && lhs.originalFont == rhs.originalFont
            && lhs.originalColor == rhs.originalColor
            && lhs.translationFont == rhs.translationFont
            && lhs.translationColor == rhs.translationColor
            && lhs.language == rhs.language
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
            if showOriginal && showTranslation {
                // 原文和译文都显示时：分为两行展示
                // 第一行：序号 + 原文（同一行，用空格隔开，如 "#16 Hello world"）
                originalTextView(prefix: "#\(seg.index) ")

                // 第二行：译文（纯译文，左对齐）
                if !transText.isEmpty {
                    translationTextView(prefix: "")
                }
            } else if showOriginal {
                // 仅显示原文：单行/自然换行展示 序号 + 原文（用空格隔开）
                originalTextView(prefix: "#\(seg.index) ")
            } else if showTranslation {
                // 仅显示译文：单行/自然换行展示 序号 + 译文（用空格隔开）
                translationTextView(prefix: "#\(seg.index) ")
            } else {
                // 原文与译文均隐藏时的简洁提示
                let hiddenNotice = (language == .en)
                    ? "Subtitles hidden (toggle with ⌥⌘O / ⌥⌘T)"
                    : "原文与译文均已隐藏（可通过工具栏或快捷键 ⌥⌘O / ⌥⌘T 重新显示）"
                Text(hiddenNotice)
                    .font(.callout)
                    .foregroundColor(.secondary.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
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
