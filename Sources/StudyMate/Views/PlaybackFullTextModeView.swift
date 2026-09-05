import AppKit
import SwiftUI

/// 全文模式中的段落模型
///
/// 当媒体具备角色（s1, s2等）时，按角色发言轮替分段；
/// 当媒体无角色时，所有句子合并为一个段落首尾相连。
public struct FullTextParagraph: Identifiable, Equatable {
    public let id: UUID
    public let speakerRole: String?
    public let segments: [SentenceSegment]

    public init(id: UUID = UUID(), speakerRole: String?, segments: [SentenceSegment]) {
        self.id = id
        self.speakerRole = speakerRole
        self.segments = segments
    }
}

/// 全文模式辅助工具：段落切分、文本拼接与富文本生成
public enum FullTextParagraphBuilder {
    /// 将断句序列切分为全文段落
    public static func buildParagraphs(from segments: [SentenceSegment]) -> [FullTextParagraph] {
        guard !segments.isEmpty else { return [] }

        let hasSpeakers = segments.contains { !$0.speakerRoleLabel.isEmpty }

        // 如果没有角色的，所有断句首尾拼接在一起
        if !hasSpeakers {
            return [FullTextParagraph(speakerRole: nil, segments: segments)]
        }

        // 如果有角色的，即 s1, s2 等，每一个角色结束需要换行（按角色轮替分段）
        var paragraphs: [FullTextParagraph] = []
        var currentSpeaker: String? = nil
        var currentGroup: [SentenceSegment] = []

        for seg in segments {
            let role = seg.speakerRoleLabel.isEmpty ? nil : seg.speakerRoleLabel
            if role == currentSpeaker && !currentGroup.isEmpty {
                currentGroup.append(seg)
            } else {
                if !currentGroup.isEmpty {
                    paragraphs.append(FullTextParagraph(
                        speakerRole: currentSpeaker,
                        segments: currentGroup
                    ))
                }
                currentSpeaker = role
                currentGroup = [seg]
            }
        }

        if !currentGroup.isEmpty {
            paragraphs.append(FullTextParagraph(
                speakerRole: currentSpeaker,
                segments: currentGroup
            ))
        }

        return paragraphs
    }

    /// 拼接段落内的句子文本，并记录每个句子的字符范围 NSRange
    public static func concatenate(
        segments: [SentenceSegment],
        useTranslation: Bool
    ) -> (text: String, ranges: [(id: UUID, range: NSRange)]) {
        var result = ""
        var ranges: [(id: UUID, range: NSRange)] = []

        for seg in segments {
            let rawText = useTranslation ? seg.translation : seg.text
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                let loc = (result as NSString).length
                ranges.append((id: seg.id, range: NSRange(location: loc, length: 0)))
                continue
            }

            if !result.isEmpty {
                // 智能空格拼接：若前句末尾不是空白且当前句开头不是空白
                let lastChar = result.last
                let firstChar = trimmed.first
                if let last = lastChar, let first = firstChar {
                    let isLastCJK = isCJKCharacter(last)
                    let isFirstCJK = isCJKCharacter(first)
                    if !last.isWhitespace && !first.isWhitespace {
                        if !isLastCJK || !isFirstCJK {
                            result.append(" ")
                        }
                    }
                }
            }

            let startLocation = (result as NSString).length
            result.append(trimmed)
            let length = (trimmed as NSString).length
            ranges.append((id: seg.id, range: NSRange(location: startLocation, length: length)))
        }

        return (result, ranges)
    }

    private static func isCJKCharacter(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value) ||
               (0x3000...0x303F).contains(scalar.value) ||
               (0xFF00...0xFFEF).contains(scalar.value)
    }

    /// 构建带下划线高亮效果的段落富文本
    ///
    /// 播放哪一句时，那一句展示一段下划线，下划线颜色跟随当前字体颜色。
    public static func buildAttributedString(
        fullText: String,
        ranges: [(id: UUID, range: NSRange)],
        activeSegmentID: UUID?,
        font: NSFont,
        color: NSColor,
        lineSpacing: CGFloat = 6
    ) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.lineBreakMode = .byWordWrapping

        let mutableAttr = NSMutableAttributedString(
            string: fullText,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle
            ]
        )

        if let activeID = activeSegmentID,
           let match = ranges.first(where: { $0.id == activeID }),
           match.range.length > 0,
           match.range.location + match.range.length <= (fullText as NSString).length {
            mutableAttr.addAttributes([
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: color
            ], range: match.range)
        }

        return mutableAttr
    }
}

/// 全文模式主视图（Full Text Mode View）
///
/// 界面布局与句子模式一致：顶部可选波形图 + 中间全文文章视窗 + 底部固定播放控制区。
/// 文章由所有断句首尾拼接而成；有角色时每个角色结束换行分段；
/// 原文与译文同时显示时每一行原文下方紧跟对应译文；
/// 播放中句子具有跟随字体颜色的下划线高亮；
/// 完整支持划词查词、双击播放、单击跳转与全套播放循环控制。
public struct PlaybackFullTextModeView: View {
    @ObservedObject private var engine: PlaybackEngine
    @ObservedObject private var videoSubtitleSettings: VideoSubtitleSettings
    @ObservedObject private var lang: LanguageManager

    @State private var followPlayback: Bool = true
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

    private var activeSegmentID: UUID? {
        guard let index = engine.activeSegmentIndex,
              engine.segments.indices.contains(index) else { return nil }
        return engine.segments[index].id
    }

    private var paragraphs: [FullTextParagraph] {
        FullTextParagraphBuilder.buildParagraphs(from: engine.segments)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if engine.segments.isEmpty {
                emptyStateView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 顶部状态与跟随播放控制栏
                topHeaderBar

                // 中间全文文章视窗（48pt 两侧安全边距）
                articleScrollView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // 底部固定播放控制条（与句子模式/列表模式一致）
            bottomPlaybackControlBar
        }
        .background(StudyMateMediaStyle.windowBackground)
    }

    // MARK: - 顶部工具与状态栏

    private var topHeaderBar: some View {
        HStack {
            let segCount = engine.segments.count
            let paraCount = paragraphs.count
            let statsText = (lang.currentLanguage == .en)
                ? "\(paraCount) paragraph\(paraCount > 1 ? "s" : ""), \(segCount) sentence\(segCount > 1 ? "s" : "")"
                : "共 \(paraCount) 个段落，\(segCount) 句"

            Text(statsText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.leading, 16)

            Spacer()

            Button {
                followPlayback.toggle()
            } label: {
                Image(systemName: "target")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
                    .foregroundColor(followPlayback ? .primary : .secondary.opacity(0.45))
                    .help(StudyMateShortcutCatalog.help(
                        followPlayback
                            ? lang.text("播放时自动跟随当前句", "Follow the active sentence during playback")
                            : lang.text("已暂停自动跟随，点击恢复", "Automatic following is paused; click to resume"),
                        shortcut: .followActiveSentence
                    ))
            }
            .studymateChromeButton(shape: .circle)
            .focusable(false)
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .padding(.trailing, 16)
        }
        .frame(height: 30)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(StudyMateMediaStyle.separator.opacity(0.6)),
            alignment: .bottom
        )
    }

    // MARK: - 全文滚动视窗

    private var articleScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    Spacer(minLength: 16)

                    ForEach(paragraphs) { paragraph in
                        FullTextParagraphRowView(
                            paragraph: paragraph,
                            activeSegmentID: activeSegmentID,
                            showOriginal: videoSubtitleSettings.showOriginal,
                            showTranslation: videoSubtitleSettings.showTranslation,
                            originalFont: videoSubtitleSettings.makeOriginalFont(for: .fullText),
                            originalColor: videoSubtitleSettings.originalNSColor(for: .fullText),
                            translationFont: videoSubtitleSettings.makeTranslationFont(for: .fullText),
                            translationColor: videoSubtitleSettings.translationNSColor(for: .fullText),
                            language: lang.currentLanguage,
                            onSelect: { segID in
                                engine.jumpToSegment(id: segID)
                            },
                            onDoubleClick: { segID in
                                engine.jumpToSegment(id: segID)
                                engine.play()
                            }
                        )
                        .equatable()
                        .id(paragraph.id)
                    }

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: activeSegmentID) { _, newActiveID in
                guard followPlayback, let newActiveID else { return }
                if let targetPara = paragraphs.first(where: { $0.segments.contains(where: { $0.id == newActiveID }) }) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(targetPara.id, anchor: nil)
                    }
                }
            }
        }
    }

    // MARK: - 底部播放控制条

    private var bottomPlaybackControlBar: some View {
        HStack {
            Spacer()
            FloatingVideoOSDView(
                engine: engine,
                isScrubbing: $isScrubbing,
                isVolumeScrubbing: $isVolumeScrubbing
            )
            .padding(.vertical, 7)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(StudyMateMediaStyle.windowBackground)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(StudyMateMediaStyle.separator),
            alignment: .top
        )
    }

    // MARK: - 空状态

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 44))
                .foregroundColor(.secondary.opacity(0.6))

            Text(lang.text("暂无全文内容", "No text available"))
                .font(.headline)
                .foregroundColor(.secondary)

            Text(lang.text("请先打开音视频文件并进行智能断句", "Please open media and perform segmentation"))
                .font(.subheadline)
                .foregroundColor(.secondary.opacity(0.7))
        }
    }
}

// MARK: - 单个段落行渲染器（Equatable 性能隔离，保证全文流畅）

private struct FullTextParagraphRowView: View, Equatable {
    let paragraph: FullTextParagraph
    let activeSegmentID: UUID?
    let showOriginal: Bool
    let showTranslation: Bool
    let originalFont: NSFont
    let originalColor: NSColor
    let translationFont: NSFont
    let translationColor: NSColor
    let language: AppLanguage
    let onSelect: (UUID) -> Void
    let onDoubleClick: (UUID) -> Void

    static func == (lhs: FullTextParagraphRowView, rhs: FullTextParagraphRowView) -> Bool {
        lhs.paragraph == rhs.paragraph
            && lhs.activeSegmentID == rhs.activeSegmentID
            && lhs.showOriginal == rhs.showOriginal
            && lhs.showTranslation == rhs.showTranslation
            && lhs.originalFont == rhs.originalFont
            && lhs.originalColor == rhs.originalColor
            && lhs.translationFont == rhs.translationFont
            && lhs.translationColor == rhs.translationColor
            && lhs.language == rhs.language
    }

    private var origData: (text: String, ranges: [(id: UUID, range: NSRange)]) {
        FullTextParagraphBuilder.concatenate(segments: paragraph.segments, useTranslation: false)
    }

    private var transData: (text: String, ranges: [(id: UUID, range: NSRange)]) {
        FullTextParagraphBuilder.concatenate(segments: paragraph.segments, useTranslation: true)
    }

    private var paragraphContext: String {
        [origData.text, transData.text].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 角色徽章（如有角色）
            if let role = paragraph.speakerRole {
                HStack(spacing: 4) {
                    Text(role)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(StudyMateMediaStyle.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(StudyMateMediaStyle.accent.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            if showOriginal && showTranslation {
                // 原文和译文同时显示：每一行原文下面显示对应的译文
                if !origData.text.isEmpty {
                    originalTextView
                }
                if !transData.text.isEmpty {
                    translationTextView
                }
            } else if showOriginal {
                // 仅显示原文
                if !origData.text.isEmpty {
                    originalTextView
                }
            } else if showTranslation {
                // 仅显示译文
                if !transData.text.isEmpty {
                    translationTextView
                }
            } else {
                // 原文与译文均隐藏
                Text(language == .en
                     ? "Text hidden (toggle with ⌥⌘O / ⌥⌘T)"
                     : "全文内容已隐藏（可通过工具栏或快捷键 ⌥⌘O / ⌥⌘T 重新显示）")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var originalTextView: some View {
        let attr = FullTextParagraphBuilder.buildAttributedString(
            fullText: origData.text,
            ranges: origData.ranges,
            activeSegmentID: activeSegmentID,
            font: originalFont,
            color: originalColor,
            lineSpacing: 6
        )

        return FullTextParagraphTextView(
            attributedString: attr,
            ranges: origData.ranges,
            contextText: paragraphContext,
            onSelect: onSelect,
            onDoubleClick: onDoubleClick
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var translationTextView: some View {
        let attr = FullTextParagraphBuilder.buildAttributedString(
            fullText: transData.text,
            ranges: transData.ranges,
            activeSegmentID: activeSegmentID,
            font: translationFont,
            color: translationColor,
            lineSpacing: 5
        )

        return FullTextParagraphTextView(
            attributedString: attr,
            ranges: transData.ranges,
            contextText: paragraphContext,
            onSelect: onSelect,
            onDoubleClick: onDoubleClick
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 原生 AppKit 文本渲染视图（支持下划线、整段划词取词与单双击事件）

private struct FullTextParagraphTextView: NSViewRepresentable {
    let attributedString: NSAttributedString
    let ranges: [(id: UUID, range: NSRange)]
    let contextText: String?
    let onSelect: ((UUID) -> Void)?
    let onDoubleClick: ((UUID) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect, onDoubleClick: onDoubleClick)
    }

    func makeNSView(context: Context) -> FullTextNSTextView {
        let textView = FullTextNSTextView(frame: .zero)
        textView.coordinator = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.insertionPointColor = .clear
        textView.focusRingType = .none
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width, .height]
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        textView.configureForDictionaryLookup(context: contextText)
        return textView
    }

    func updateNSView(_ textView: FullTextNSTextView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.onDoubleClick = onDoubleClick
        context.coordinator.ranges = ranges
        textView.coordinator = context.coordinator
        textView.updateDictionaryLookupContext(contextText)

        if textView.attributedString() != attributedString {
            textView.textStorage?.setAttributedString(attributedString)
            textView.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FullTextNSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else {
            return nil
        }
        let rect = attributedString.boundingRect(
            with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return CGSize(width: width, height: max(22, ceil(rect.height) + 6))
    }

    final class Coordinator: NSObject {
        var onSelect: ((UUID) -> Void)?
        var onDoubleClick: ((UUID) -> Void)?
        var ranges: [(id: UUID, range: NSRange)] = []

        init(
            onSelect: ((UUID) -> Void)?,
            onDoubleClick: ((UUID) -> Void)?
        ) {
            self.onSelect = onSelect
            self.onDoubleClick = onDoubleClick
        }
    }
}

// MARK: - NSTextView 子类：支持精准单击/双击落点映射到具体句子

private final class FullTextNSTextView: NSTextView {
    weak var coordinator: FullTextParagraphTextView.Coordinator?
    private var plainMouseDownPoint: NSPoint?
    private var plainMouseDidMove = false

    override func mouseDown(with event: NSEvent) {
        plainMouseDownPoint = event.locationInWindow
        plainMouseDidMove = false

        if event.clickCount == 2 {
            let pointInView = convert(event.locationInWindow, from: nil)
            if let segID = findSegment(at: pointInView) {
                coordinator?.onDoubleClick?(segID)
            }
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = plainMouseDownPoint {
            let current = event.locationInWindow
            plainMouseDidMove = plainMouseDidMove || hypot(current.x - start.x, current.y - start.y) > 2
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        defer {
            plainMouseDownPoint = nil
            plainMouseDidMove = false
        }

        // 仅当用户未发生划词拖拽、且未选中范围时，才响应单击跳转
        if event.clickCount == 1, !plainMouseDidMove, selectedRange().length == 0 {
            let pointInView = convert(event.locationInWindow, from: nil)
            if let segID = findSegment(at: pointInView) {
                coordinator?.onSelect?(segID)
            }
        }
    }

    private func findSegment(at point: NSPoint) -> UUID? {
        guard let layoutManager = layoutManager, let textContainer = textContainer else { return nil }
        let charIndex = layoutManager.characterIndex(
            for: point,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        guard let ranges = coordinator?.ranges else { return nil }
        for (id, range) in ranges {
            if charIndex >= range.location && charIndex < (range.location + range.length) {
                return id
            }
        }
        return nil
    }
}
