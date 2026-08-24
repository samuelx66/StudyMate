import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Pure state machine for the list's playback-follow behavior.  Keeping the
/// suppression rules outside the view makes the user-scroll/programmatic-scroll
/// boundary deterministic and directly testable without constructing SwiftUI.
struct SegmentListFollowState: Equatable {
    private(set) var followsPlayback = true
    private(set) var isUserScrollSuppressed = false

    var shouldFollow: Bool {
        followsPlayback && !isUserScrollSuppressed
    }

    mutating func toggle() {
        followsPlayback.toggle()
        if !followsPlayback {
            isUserScrollSuppressed = false
        }
    }

    mutating func markUserScroll() {
        guard followsPlayback else { return }
        isUserScrollSuppressed = true
    }

    mutating func resumeFollowing() {
        guard followsPlayback else { return }
        isUserScrollSuppressed = false
    }
}

/// 断句列表区视图（支持字幕导入、选句媒体导出、星标过滤、文本编辑与快捷切分）
public struct SegmentListView: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var lang = LanguageManager.shared
    @ObservedObject private var libraryManager = SentenceLibraryManager.shared
    @Environment(\.openWindow) private var openWindow

    @State private var searchText: String = ""
    @State private var showImportSheet: Bool = false
    @State private var showSettingsPopover: Bool = false
    @State private var filterBookmarkedOnly: Bool = false
    @State private var selectedSegmentIDs: Set<UUID> = []
    @State private var isExporting: Bool = false
    @State private var isAddingToLibrary: Bool = false
    @State private var exportNotice: SegmentExportNotice?
    @State private var cachedDisplayedSegments: [SentenceSegment] = []
    @State private var followState = SegmentListFollowState()
    @State private var scrollSuppressionToken = UUID()

    public init(engine: PlaybackEngine) {
        self.engine = engine
    }

    private var displayedSegments: [SentenceSegment] {
        cachedDisplayedSegments
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 列表头部工具栏
            HStack(spacing: 6) {
                Label(lang.localized(.segmentList), systemImage: "list.bullet.indent")
                    .font(.subheadline.bold())

                Text("(\(engine.segments.count))")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !selectedSegmentIDs.isEmpty {
                    Text(lang.text("已选 \(selectedSegmentIDs.count)", "\(selectedSegmentIDs.count) selected"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // 播放时自动跟随当前句开关
                Button(action: {
                    followState.toggle()
                }) {
                    Image(systemName: followState.shouldFollow
                        ? "book.pages.fill"
                        : "book.closed")
                        .foregroundColor(followState.shouldFollow ? .primary : .secondary)
                        .help(lang.text(
                            followState.shouldFollow
                                ? "播放时自动跟随当前句"
                                : "已暂停自动跟随，点击恢复",
                            followState.shouldFollow
                                ? "Follow the active sentence during playback"
                                : "Automatic following is paused; click to resume"
                        ))
                }
                .buttonStyle(.plain)
                .focusable(false)

                // 难句过滤筛选开关
                Button(action: { filterBookmarkedOnly.toggle() }) {
                    Image(systemName: filterBookmarkedOnly ? "star.fill" : "star")
                        .foregroundColor(filterBookmarkedOnly ? .yellow : .secondary)
                        .help(lang.text("只显示星标难句", "Show bookmarked sentences only"))
                }
                .buttonStyle(.plain)
                .focusable(false)

                // 导入字幕按钮
                Button(action: { showImportSheet = true }) {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundColor(.secondary)
                        .help(lang.text("导入字幕（SRT / LRC / VTT / TXT）", "Import subtitles (SRT / LRC / VTT / TXT)"))
                }
                .buttonStyle(.plain)
                .focusable(false)

                // 将已选断句统一导出为音频和字幕
                Menu {
                    Button(lang.text("逐句导出 MP3＋LRC…", "Export separate MP3 + LRC…")) {
                        chooseIndividualExportDestination()
                    }
                    Button(lang.text("合并导出 MP3＋LRC…", "Export merged MP3 + LRC…")) {
                        chooseMergedExportDestination()
                    }
                } label: {
                    if isExporting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .focusable(false)
                .disabled(selectedSegmentIDs.isEmpty || engine.currentMedia == nil || isExporting)
                .help(lang.text(
                    selectedSegmentIDs.isEmpty ? "请先勾选要导出的句子" : "导出已选句子的 MP3 和 LRC",
                    selectedSegmentIDs.isEmpty ? "Select sentences to export" : "Export selected sentences as MP3 and LRC"
                ))

                // 将已选断句保存到当前句库；视频句子会在后台截取预览帧。
                Menu {
                    Button {
                        addSelectedSegmentsToLibrary()
                    } label: {
                        Label(
                            lang.text(
                                "加入“\(libraryManager.currentLibrary?.name ?? "默认句库")”",
                                "Add to “\(libraryManager.currentLibrary?.name ?? "Default Library")”"
                            ),
                            systemImage: "text.badge.plus"
                        )
                    }
                    .disabled(selectedSegmentIDs.isEmpty || engine.currentMedia == nil || isAddingToLibrary)

                    if libraryManager.libraries.count > 1 {
                        Menu(lang.text("切换句库", "Switch Library")) {
                            ForEach(libraryManager.libraries) { library in
                                Button {
                                    libraryManager.selectLibrary(library.id)
                                } label: {
                                    if library.id == libraryManager.currentLibraryID {
                                        Label(library.name, systemImage: "checkmark")
                                    } else {
                                        Text(library.name)
                                    }
                                }
                            }
                        }
                    }

                    Divider()
                    Button {
                        openWindow(id: "sentence-library")
                    } label: {
                        Label(lang.text("打开句库…", "Open Sentence Library…"), systemImage: "books.vertical")
                    }
                } label: {
                    if isAddingToLibrary {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "text.badge.plus")
                            .foregroundColor(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .focusable(false)
                .help(lang.text(
                    selectedSegmentIDs.isEmpty ? "请先勾选要加入句库的句子" : "将已选句子加入当前句库",
                    selectedSegmentIDs.isEmpty ? "Select sentences to add to a library" : "Add selected sentences to the current library"
                ))

                // 用户只决定速度优先还是质量优先；句长与证据权重由算法分析。
                Menu {
                    Button(lang.text("快速断句（不识别文字）", "Fast segmentation (no transcription)")) {
                        engine.performSegmentation(mode: .fast)
                    }
                    Button(lang.text("智能断句（推荐）", "Intelligent segmentation (Recommended)")) {
                        engine.performSegmentation(mode: .intelligent)
                    }
                } label: {
                    Image(systemName: "wand.and.stars")
                        .foregroundColor(.secondary)
                        .help(lang.text("选择断句模式", "Choose segmentation mode"))
                }
                .menuStyle(.borderlessButton)
                .focusable(false)

                // 添加断句
                Button(action: {
                    let cur = engine.currentTime
                    engine.addSegment(startTime: cur, endTime: min(engine.duration > 0 ? engine.duration : 9999.0, cur + 3.0))
                }) {
                    Image(systemName: "plus")
                        .foregroundColor(.secondary)
                        .help(lang.localized(.addSegment))
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            // AI 语音识别与智能断句进度指示条
            if engine.isAITranscribing {
                HStack(spacing: 8) {
                    ProgressView(value: max(0.05, engine.aiTranscriptionProgress))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                    Text(engine.aiTranscriptionStatusText)
                        .font(.caption2.bold())
                        .foregroundColor(.blue)
                    Button(action: { engine.cancelSegmentation() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(lang.text("取消断句", "Cancel segmentation"))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.12))
                .animation(.easeInOut(duration: 0.2), value: engine.aiTranscriptionProgress)
            }

            if let warning = engine.segmentationWarningMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(warning)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.10))
            }

            // 搜索过滤栏
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.caption)
                TextField(lang.text("搜索台词或字幕…", "Search text or subtitles…"), text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            // 断句列表 (采用高性能 ScrollView + LazyVStack，杜绝 NSTableView 代理重入警告)
            if displayedSegments.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: filterBookmarkedOnly ? "star.slash" : "text.badge.plus")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(filterBookmarkedOnly
                        ? lang.text("暂无星标难句", "No bookmarked sentences")
                        : lang.text("暂无断句数据", "No sentence data"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(displayedSegments) { seg in
                                let isActive: Bool = {
                                    guard let index = engine.activeSegmentIndex,
                                          index >= 0,
                                          index < engine.segments.count else { return false }
                                    return engine.segments[index].id == seg.id
                                }()
                                SegmentRowView(
                                    seg: seg,
                                    isActive: isActive,
                                    isSelectedForExport: selectedSegmentIDs.contains(seg.id),
                                    onToggleExportSelection: {
                                        if selectedSegmentIDs.contains(seg.id) {
                                            selectedSegmentIDs.remove(seg.id)
                                        } else {
                                            selectedSegmentIDs.insert(seg.id)
                                        }
                                    },
                                    onSelect: {
                                        engine.jumpToSegment(id: seg.id)
                                    },
                                    onToggleBookmark: {
                                        engine.toggleBookmark(for: seg.id)
                                    },
                                    onSplit: {
                                        engine.splitSegment(id: seg.id, at: (seg.startTime + seg.endTime) / 2.0)
                                    },
                                    onMergeNext: {
                                        engine.mergeSegmentWithNext(id: seg.id)
                                    },
                                    onDelete: {
                                        engine.deleteSegment(id: seg.id)
                                    },
                                    onSaveText: { originalText, translationText in
                                        engine.updateSegmentText(
                                            id: seg.id,
                                            text: originalText,
                                            translation: translationText
                                        )
                                    }
                                )
                                .id(seg.id)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .background(
                            ScrollViewInteractionObserver {
                                markUserScroll()
                            }
                            .frame(width: 1, height: 1)
                        )
                    }
                    .onChange(of: engine.activeSegmentIndex) { _, newIndex in
                        guard followState.shouldFollow else { return }
                        if let idx = newIndex, idx >= 0, idx < engine.segments.count {
                            let targetId = engine.segments[idx].id
                            DispatchQueue.main.async {
                                guard self.followState.shouldFollow else { return }
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(targetId, anchor: nil)
                                }
                            }
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 220)
        .sheet(isPresented: $showImportSheet) {
            SubtitleImportSheet(engine: engine)
        }
        .onAppear { refreshDisplayedSegments() }
        .onChange(of: engine.segments) { _, _ in refreshDisplayedSegments() }
        .onChange(of: searchText) { _, _ in refreshDisplayedSegments() }
        .onChange(of: filterBookmarkedOnly) { _, _ in refreshDisplayedSegments() }
        .alert(item: $exportNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text(lang.text("好", "OK")))
            )
        }
    }

    private func refreshDisplayedSegments() {
        var list = engine.segments
        if filterBookmarkedOnly { list = list.filter(\.isBookmarked) }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            list = list.filter {
                $0.text.localizedCaseInsensitiveContains(query) ||
                $0.translation.localizedCaseInsensitiveContains(query)
            }
        }
        cachedDisplayedSegments = list
        selectedSegmentIDs.formIntersection(engine.segments.lazy.map(\.id))
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

    private var selectedSegments: [SentenceSegment] {
        engine.segments.filter { selectedSegmentIDs.contains($0.id) }
    }

    private func chooseIndividualExportDestination() {
        guard let media = engine.currentMedia, !selectedSegments.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = lang.text("选择", "Choose")
        panel.message = lang.text("选择逐句 MP3 和 LRC 的保存位置", "Choose where to save separate MP3 and LRC files")
        if panel.runModal() == .OK, let directory = panel.url {
            let segments = selectedSegments
            performExport {
                try SegmentMediaExporter.shared.exportIndividually(
                    mediaURL: media.url,
                    segments: segments,
                    destinationDirectory: directory,
                    baseName: media.title
                )
            }
        }
    }

    private func chooseMergedExportDestination() {
        guard let media = engine.currentMedia, !selectedSegments.isEmpty else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.mp3]
        panel.nameFieldStringValue = media.title + "-已选句子.mp3"
        panel.message = lang.text("将生成一个 MP3 和一个同名 LRC 字幕", "One MP3 and one matching LRC subtitle will be created")
        if panel.runModal() == .OK, let audioURL = panel.url {
            let segments = selectedSegments
            performExport {
                try SegmentMediaExporter.shared.exportMerged(
                    mediaURL: media.url,
                    segments: segments,
                    outputAudioURL: audioURL
                )
            }
        }
    }

    private func performExport(
        operation: @escaping @Sendable () throws -> SegmentMediaExportResult
    ) {
        isExporting = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try operation() }
            }.value
            isExporting = false
            switch result {
            case let .success(output):
                exportNotice = SegmentExportNotice(
                    title: lang.text("导出完成", "Export Complete"),
                    message: lang.text(
                        "已生成 \(output.audioFileCount) 个 MP3 和 \(output.subtitleFileCount) 个字幕文件。\n\(output.location.path)",
                        "Created \(output.audioFileCount) MP3 and \(output.subtitleFileCount) subtitle file(s).\n\(output.location.path)"
                    )
                )
            case let .failure(error):
                exportNotice = SegmentExportNotice(
                    title: lang.text("导出失败", "Export Failed"),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func addSelectedSegmentsToLibrary() {
        guard let media = engine.currentMedia, !selectedSegments.isEmpty else { return }
        let segments = selectedSegments
        isAddingToLibrary = true
        Task {
            defer { isAddingToLibrary = false }
            do {
                let count = try await libraryManager.add(segments: segments, from: media)
                exportNotice = SegmentExportNotice(
                    title: lang.text("已加入句库", "Added to Library"),
                    message: lang.text(
                        "已将 \(count) 个句子加入“\(libraryManager.currentLibrary?.name ?? "默认句库")”。",
                        "Added \(count) sentence(s) to “\(libraryManager.currentLibrary?.name ?? "Default Library")”."
                    )
                )
            } catch {
                exportNotice = SegmentExportNotice(
                    title: lang.text("加入句库失败", "Unable to Add to Library"),
                    message: error.localizedDescription
                )
            }
        }
    }
}

/// Detects trackpad/mouse scrolling without replacing SwiftUI's ScrollView.
/// `willStartLiveScroll` is emitted for user scrolling, not for the list's
/// programmatic `scrollTo`, so playback following can be paused safely.
private struct ScrollViewInteractionObserver: NSViewRepresentable {
    let onUserScroll: () -> Void

    func makeNSView(context: Context) -> ScrollInteractionNSView {
        let view = ScrollInteractionNSView()
        view.onUserScroll = onUserScroll
        return view
    }

    func updateNSView(_ nsView: ScrollInteractionNSView, context: Context) {
        nsView.onUserScroll = onUserScroll
    }
}

private final class ScrollInteractionNSView: NSView {
    var onUserScroll: (() -> Void)?
    private weak var observedScrollView: NSScrollView?
    private var notificationTokens: [NSObjectProtocol] = []
    private var isLiveScrolling = false
    private var liveScrollResetWorkItem: DispatchWorkItem?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeObservers()
        } else {
            attachToEnclosingScrollViewIfNeeded()
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil {
            removeObservers()
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.attachToEnclosingScrollViewIfNeeded()
        }
    }

    private func attachToEnclosingScrollViewIfNeeded() {
        var ancestor: NSView? = superview
        while let view = ancestor, !(view is NSScrollView) {
            ancestor = view.superview
        }
        guard let scrollView = ancestor as? NSScrollView else { return }
        guard observedScrollView !== scrollView else { return }

        removeObservers()
        observedScrollView = scrollView
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                guard let self, !self.isLiveScrolling else { return }
                self.isLiveScrolling = true
                self.onUserScroll?()
                self.scheduleLiveScrollReset()
            },
            center.addObserver(
                forName: NSScrollView.didLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                // A live-scroll notification can arrive without a matching
                // willStart event when a trackpad gesture begins during view
                // reparenting.  Treat that first event as user intent too,
                // but never fire repeatedly for every scroll tick.
                guard let self else { return }
                if !self.isLiveScrolling {
                    self.isLiveScrolling = true
                    self.onUserScroll?()
                }
                self.scheduleLiveScrollReset()
            },
            center.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.liveScrollResetWorkItem?.cancel()
                self.liveScrollResetWorkItem = nil
                self.isLiveScrolling = false
            }
        ]
    }

    private func scheduleLiveScrollReset() {
        liveScrollResetWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.isLiveScrolling = false
        }
        liveScrollResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        notificationTokens.forEach(center.removeObserver)
        notificationTokens.removeAll(keepingCapacity: true)
        liveScrollResetWorkItem?.cancel()
        liveScrollResetWorkItem = nil
        observedScrollView = nil
        isLiveScrolling = false
    }

    deinit {
        removeObservers()
    }
}

private struct SegmentExportNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// 单行断句单元格
struct SegmentRowView: View {
    private enum EditField: Hashable {
        case original
        case translation
    }

    let seg: SentenceSegment
    let isActive: Bool
    let isSelectedForExport: Bool
    let onToggleExportSelection: () -> Void
    let onSelect: () -> Void
    let onToggleBookmark: () -> Void
    let onSplit: () -> Void
    let onMergeNext: () -> Void
    let onDelete: () -> Void
    let onSaveText: (String, String) -> Void

    @State private var isHovering: Bool = false
    @State private var isEditing: Bool = false
    @State private var tempOriginalText: String = ""
    @State private var tempTranslationText: String = ""
    @FocusState private var focusedField: EditField?
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                Toggle("", isOn: Binding(
                    get: { isSelectedForExport },
                    set: { _ in onToggleExportSelection() }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(lang.text("选择此句用于导出或加入句库", "Select this sentence for export or sentence library"))
                .padding(.leading, 4)
                .padding(.trailing, 6)

                // 左侧活跃状态指示竖条
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isActive ? Color.blue : Color.clear)
                    .frame(width: 3)
                    .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        // 难句收藏星标按钮
                        Button(action: onToggleBookmark) {
                            Image(systemName: seg.isBookmarked ? "star.fill" : "star")
                                .font(.system(size: 10))
                                .foregroundColor(seg.isBookmarked ? .yellow : .gray.opacity(0.4))
                        }
                        .buttonStyle(.plain)

                        // 序号
                        Text("#\(seg.index)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(isActive ? Color.blue : Color.gray.opacity(0.2))
                            .foregroundColor(isActive ? .white : .primary)
                            .cornerRadius(3)

                        // 起止时间
                        Text("\(seg.formattedStartTime) - \(seg.formattedEndTime)")
                            .font(.system(size: 10, weight: isActive ? .bold : .regular).monospacedDigit())
                            .foregroundColor(isActive ? .primary : .secondary)

                        if !seg.speakerIDs.isEmpty {
                            let speakerLabel: String = {
                                let ids = seg.speakerIDs.map { String($0 + 1) }
                                if seg.isSpeakerOverlap {
                                    return "S" + ids.joined(separator: "+")
                                }
                                if ids.count > 1 {
                                    return "S" + ids.joined(separator: "→")
                                }
                                return "S\(ids[0])"
                            }()
                            Text(speakerLabel)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(seg.isSpeakerOverlap ? .orange : .purple)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background((seg.isSpeakerOverlap ? Color.orange : Color.purple).opacity(0.12))
                                .cornerRadius(3)
                                .help(lang.text("SpeakerKit 说话人标签", "SpeakerKit speaker label"))
                        }

                        Spacer()

                        // 时长
                        Text(seg.formattedDuration)
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundColor(.secondary.opacity(0.8))

                        // 悬停操作按钮（始终占位，避免显示/隐藏引起行宽变化晃动）
                        HStack(spacing: 4) {
                            Button(action: {
                                tempOriginalText = seg.text
                                tempTranslationText = seg.translation
                                isEditing = true
                                focusedField = .original
                            }) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 9))
                            }
                            .buttonStyle(.plain)
                            .help(lang.text("编辑原文和译文", "Edit original text and translation"))
                            .allowsHitTesting(isHovering)

                            Button(action: onSplit) {
                                Image(systemName: "rectangle.split.2x1")
                                    .font(.system(size: 9))
                            }
                            .buttonStyle(.plain)
                            .help(lang.text("在中间拆分此句", "Split this sentence at its midpoint"))
                            .allowsHitTesting(isHovering)

                            Button(action: onMergeNext) {
                                Image(systemName: "arrow.triangle.merge")
                                    .font(.system(size: 9))
                            }
                            .buttonStyle(.plain)
                            .help(lang.localized(.mergeSegment))
                            .allowsHitTesting(isHovering)

                            Button(action: onDelete) {
                                Image(systemName: "trash")
                                    .font(.system(size: 9))
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                            .help(lang.localized(.deleteSegment))
                            .allowsHitTesting(isHovering)
                        }
                        .opacity(isHovering ? 1 : 0)
                    }

                    // 第二行：分为两个区域，左边显示原文，右边显示译文
                    if isEditing {
                        editingFields
                    } else {
                        HStack(alignment: .top, spacing: 6) {
                            // 左边区域：原文（若无输入则显示默认占位 Sentence #）
                            let orig = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            Text(orig.isEmpty ? lang.localized(.sentenceIndex(seg.index)) : orig)
                                .font(.caption)
                                .foregroundColor(orig.isEmpty ? .secondary.opacity(0.6) : (isActive ? .primary : .primary.opacity(0.85)))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            // 右边区域：译文
                            let trans = seg.translation.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trans.isEmpty {
                                Text(trans)
                                    .font(.caption)
                                    .foregroundColor(isActive ? .secondary : .secondary.opacity(0.8))
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.blue.opacity(0.14) : (isHovering ? Color.primary.opacity(0.04) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? Color.blue.opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            isHovering = inside
        }
    }

    private var editingFields: some View {
        HStack(spacing: 4) {
            TextField(lang.text("原文…", "Original text…"), text: $tempOriginalText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .focused($focusedField, equals: .original)
                .onSubmit {
                    focusedField = .translation
                }

            TextField(lang.text("译文…", "Translation…"), text: $tempTranslationText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .focused($focusedField, equals: .translation)
                .onSubmit {
                    finishEditing()
                }

            Button(lang.text("完成", "Done"), action: finishEditing)
                .controlSize(.mini)
        }
        .onChange(of: focusedField) { oldField, newField in
            if oldField != nil, newField == nil {
                finishEditing()
            }
        }
    }

    private func finishEditing() {
        guard isEditing else { return }
        onSaveText(tempOriginalText, tempTranslationText)
        isEditing = false
        focusedField = nil
    }
}

#Preview("断句列表侧边栏") {
    SegmentListView(engine: PlaybackEngine.shared)
        .frame(width: 320, height: 600)
}
