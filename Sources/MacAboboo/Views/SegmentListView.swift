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

/// 断句列表筛选条件。每个条件都是独立的“启用/不启用”复选项，
/// 启用多个条件时取交集；筛选值为空或无效时不额外排除句子，避免用户输入过程中列表突然清空。
struct SegmentListFilterCriteria: Equatable {
    var requiresOriginal = false
    var requiresTranslation = false
    var requiresMinimumDuration = false
    var minimumDurationText = "5"
    var requiresWord = false
    var wordText = ""
    var requiresBookmark = false

    var hasActiveFilters: Bool {
        requiresOriginal ||
        requiresTranslation ||
        requiresMinimumDuration ||
        requiresWord ||
        requiresBookmark
    }

    func matches(_ segment: SentenceSegment) -> Bool {
        if requiresOriginal && segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if requiresTranslation && segment.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if requiresMinimumDuration,
           let threshold = parsedMinimumDuration,
           !(segment.duration > threshold) {
            return false
        }
        if requiresWord {
            let query = wordText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty,
               !Self.containsWord(query, in: segment.text),
               !Self.containsWord(query, in: segment.translation) {
                return false
            }
        }
        if requiresBookmark && !segment.isBookmarked {
            return false
        }
        return true
    }

    private var parsedMinimumDuration: Double? {
        let normalized = minimumDurationText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value >= 0, value.isFinite else { return nil }
        return value
    }

    private static func containsWord(_ query: String, in text: String) -> Bool {
        // 对中文等非 ASCII 文本使用包含匹配；英语/数字使用完整词匹配，
        // 避免查询 “he” 时误命中 “the”。保留撇号以支持 don't 这类词。
        guard query.unicodeScalars.allSatisfy(\.isASCII),
              !query.contains(where: \.isWhitespace) else {
            return text.localizedCaseInsensitiveContains(query)
        }

        let tokens = text
            .lowercased()
            .split { character in
                !(character.isLetter || character.isNumber || character == "'" || character == "’")
            }
        return tokens.contains {
            String($0).compare(
                query,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }
    }
}

/// 断句列表区视图（支持字幕导入、选句媒体导出、多条件筛选、文本编辑与快捷切分）
public struct SegmentListView: View {
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var lang = LanguageManager.shared
    @ObservedObject private var libraryManager = SentenceLibraryManager.shared
    @ObservedObject private var translationSettings = TranslationSettings.shared
    @ObservedObject private var statusCenter = MainStatusCenter.shared
    @Environment(\.openWindow) private var openWindow

    @State private var searchText: String = ""
    @State private var showImportSheet: Bool = false
    @State private var showSettingsPopover: Bool = false
    @State private var showTranslationPopover: Bool = false
    @State private var filterCriteria = SegmentListFilterCriteria()
    @State private var showFilterPopover: Bool = false
    @State private var selectedSegmentIDs: Set<UUID> = []
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

                // 句子筛选：每项都是独立复选条件，启用后自动选中符合条件的句子。
                Button {
                    showFilterPopover.toggle()
                } label: {
                    Image(systemName: filterCriteria.hasActiveFilters
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                        .foregroundColor(filterCriteria.hasActiveFilters ? .blue : .secondary)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(lang.text("筛选句子", "Filter sentences"))
                .popover(isPresented: $showFilterPopover, arrowEdge: .top) {
                    SegmentFilterPopover(
                        criteria: $filterCriteria,
                        lang: lang,
                        displayedCount: displayedSegments.count,
                        selectedCount: selectedSegmentIDs.intersection(Set(displayedSegments.map(\.id))).count,
                        onSelectAll: selectDisplayedSegments,
                        onInvertSelection: invertDisplayedSegmentSelection
                    )
                }

                // 翻译必须由用户明确发起；点击后在列表上方冒泡选择服务、模型与目标语言。
                Button {
                    showTranslationPopover = true
                } label: {
                    Image(systemName: "character.book.closed")
                        .foregroundColor(translationSettings.isAutomaticTranslationEnabled ? .secondary : .secondary.opacity(0.45))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .disabled(!translationSettings.isAutomaticTranslationEnabled || engine.segments.isEmpty || engine.isAutoTranslating)
                .help(lang.text(
                    translationSettings.isAutomaticTranslationEnabled
                        ? "翻译句子（选择服务和目标语言）"
                        : "请先在设置中启用翻译功能",
                    translationSettings.isAutomaticTranslationEnabled
                        ? "Translate sentences (choose service and target language)"
                        : "Enable translation in Settings first"
                ))
                .popover(isPresented: $showTranslationPopover, arrowEdge: .top) {
                    TranslationExecutionSheet(
                        engine: engine,
                        settings: translationSettings,
                        selectedSegmentIDs: selectedSegmentIDs,
                        lang: lang
                    )
                }

                // 导入字幕按钮
                Button(action: { showImportSheet = true }) {
                    Image(systemName: "captions.bubble")
                        .foregroundColor(.secondary)
                        .help(lang.text("导入字幕（SRT / LRC / VTT / TXT）", "Import subtitles (SRT / LRC / VTT / TXT)"))
                }
                .buttonStyle(.plain)
                .focusable(false)

                // 将已选断句统一导出为音频和字幕
                Menu {
                    Button(lang.text("逐句导出 M4A＋LRC…", "Export separate M4A + LRC…")) {
                        chooseIndividualExportDestination()
                    }
                    Button(lang.text("合并导出 M4A＋LRC…", "Export merged M4A + LRC…")) {
                        chooseMergedExportDestination()
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .focusable(false)
                .disabled(selectedSegmentIDs.isEmpty || engine.currentMedia == nil || statusCenter.progress != nil)
                .help(lang.text(
                    selectedSegmentIDs.isEmpty ? "请先勾选要导出的句子" : "导出已选句子的 M4A 和 LRC",
                    selectedSegmentIDs.isEmpty ? "Select sentences to export" : "Export selected sentences as M4A and LRC"
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
                    Image(systemName: "text.badge.plus")
                        .foregroundColor(isAddingToLibrary ? .blue : .secondary)
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
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

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
                    Image(systemName: filterCriteria.hasActiveFilters || !searchText.isEmpty
                        ? "line.3.horizontal.decrease.circle"
                        : "text.badge.plus")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(filterCriteria.hasActiveFilters
                        ? lang.text("没有符合筛选条件的句子", "No sentences match the filters")
                        : !searchText.isEmpty
                            ? lang.text("没有符合搜索条件的句子", "No sentences match the search")
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
                                    onToggleNavigationBookmark: {
                                        engine.toggleNavigationBookmark(for: seg.id)
                                    },
                                    onSplit: {
                                        engine.splitSegment(id: seg.id, at: (seg.startTime + seg.endTime) / 2.0)
                                    },
                                    onMergePrevious: {
                                        engine.mergeSegmentWithPrevious(id: seg.id)
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
        .onChange(of: filterCriteria) { _, _ in
            refreshDisplayedSegments(selectMatching: filterCriteria.hasActiveFilters)
        }
        .alert(item: $exportNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text(lang.text("好", "OK")))
            )
        }
    }

    private func refreshDisplayedSegments(selectMatching: Bool = false) {
        let criteriaMatches = engine.segments.filter { filterCriteria.matches($0) }
        var list = criteriaMatches
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            list = list.filter {
                $0.text.localizedCaseInsensitiveContains(query) ||
                $0.translation.localizedCaseInsensitiveContains(query)
            }
        }
        cachedDisplayedSegments = list
        if selectMatching && filterCriteria.hasActiveFilters {
            selectedSegmentIDs = Set(list.map(\.id))
        } else if filterCriteria.hasActiveFilters {
            // 底层句子被编辑、合并或星标状态变化后，移除已不再符合条件的隐藏选择；
            // 但保留用户对仍符合条件句子的手动取消勾选。搜索词不参与此集合，避免搜索栏改变导出范围。
            selectedSegmentIDs.formIntersection(criteriaMatches.lazy.map(\.id))
        } else {
            selectedSegmentIDs.formIntersection(engine.segments.lazy.map(\.id))
        }
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

    private func selectDisplayedSegments() {
        selectedSegmentIDs.formUnion(displayedSegments.map(\.id))
    }

    private func invertDisplayedSegmentSelection() {
        let displayedIDs = Set(displayedSegments.map(\.id))
        selectedSegmentIDs = selectedSegmentIDs.symmetricDifference(displayedIDs)
    }

    private func chooseIndividualExportDestination() {
        guard let media = engine.currentMedia, !selectedSegments.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = lang.text("选择", "Choose")
        panel.message = lang.text("选择逐句 M4A 和 LRC 的保存位置", "Choose where to save separate M4A and LRC files")
        if panel.runModal() == .OK, let directory = panel.url {
            let segments = selectedSegments
            performExport { progress in
                try SegmentMediaExporter.shared.exportIndividually(
                    mediaURL: media.url,
                    segments: segments,
                    destinationDirectory: directory,
                    baseName: media.title,
                    progress: progress
                )
            }
        }
    }

    private func chooseMergedExportDestination() {
        guard let media = engine.currentMedia, !selectedSegments.isEmpty else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "m4a") ?? .audio]
        panel.nameFieldStringValue = media.title + "-已选句子.m4a"
        panel.message = lang.text("将生成一个 AAC 编码的 M4A 和一个同名 LRC 字幕", "One AAC-encoded M4A and one matching LRC subtitle will be created")
        if panel.runModal() == .OK, let audioURL = panel.url {
            let segments = selectedSegments
            performExport { progress in
                try SegmentMediaExporter.shared.exportMerged(
                    mediaURL: media.url,
                    segments: segments,
                    outputAudioURL: audioURL,
                    progress: progress
                )
            }
        }
    }

    private func performExport(
        operation: @escaping @Sendable (@escaping @Sendable (SegmentMediaExportProgress) -> Void) throws -> SegmentMediaExportResult
    ) {
        statusCenter.clearError()
        let operationGeneration = statusCenter.begin(MainStatusProgress(
            fraction: 0,
            phase: lang.text("准备导出", "Preparing export")
        ))
        let progressUpdate: @Sendable (SegmentMediaExportProgress) -> Void = { progress in
            Task { @MainActor in
                statusCenter.update(
                    MainStatusProgress(
                        fraction: progress.fraction,
                        phase: progress.phase,
                        currentItem: progress.currentItem
                    ),
                    generation: operationGeneration
                )
            }
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try operation(progressUpdate) }
            }.value
            statusCenter.finish(generation: operationGeneration)
            switch result {
            case let .success(output):
                exportNotice = SegmentExportNotice(
                    title: lang.text("导出完成", "Export Complete"),
                    message: lang.text(
                        "已生成 \(output.audioFileCount) 个 M4A 和 \(output.subtitleFileCount) 个字幕文件。\n\(output.location.path)",
                        "Created \(output.audioFileCount) M4A and \(output.subtitleFileCount) subtitle file(s).\n\(output.location.path)"
                    )
                )
            case let .failure(error):
                statusCenter.showError(error.localizedDescription)
            }
        }
    }

    private func addSelectedSegmentsToLibrary() {
        guard let media = engine.currentMedia, !selectedSegments.isEmpty else { return }
        let segments = selectedSegments
        isAddingToLibrary = true
        statusCenter.clearError()
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
                statusCenter.showError(error.localizedDescription)
            }
        }
    }
}

private struct SegmentFilterPopover: View {
    @Binding var criteria: SegmentListFilterCriteria
    @ObservedObject var lang: LanguageManager
    let displayedCount: Int
    let selectedCount: Int
    let onSelectAll: () -> Void
    let onInvertSelection: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(lang.text("句子筛选", "Sentence Filters"))
                .font(.headline)

            Toggle(isOn: $criteria.requiresOriginal) {
                Text(lang.text("只显示有原文的句子", "Only sentences with original text"))
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: $criteria.requiresTranslation) {
                Text(lang.text("只显示有译文的句子", "Only sentences with translation"))
            }
            .toggleStyle(.checkbox)

            HStack(spacing: 6) {
                Toggle(isOn: $criteria.requiresMinimumDuration) {
                    Text(lang.text("只显示时长大于", "Only sentences longer than"))
                }
                .toggleStyle(.checkbox)

                TextField("5", text: $criteria.minimumDurationText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 54)
                    .disabled(!criteria.requiresMinimumDuration)

                Text(lang.text("秒", "sec"))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 6) {
                Toggle(isOn: $criteria.requiresWord) {
                    Text(lang.text("只显示含单词", "Only sentences containing"))
                }
                .toggleStyle(.checkbox)

                TextField(lang.text("单词", "word"), text: $criteria.wordText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 92)
                    .disabled(!criteria.requiresWord)
            }

            Toggle(isOn: $criteria.requiresBookmark) {
                Text(lang.text("只显示带星标的句子", "Only starred sentences"))
            }
            .toggleStyle(.checkbox)

            Divider()

            HStack(spacing: 8) {
                Button(lang.text("全选", "Select All"), action: onSelectAll)
                    .disabled(displayedCount == 0 || selectedCount == displayedCount)
                Button(lang.text("反选", "Invert Selection"), action: onInvertSelection)
                    .disabled(displayedCount == 0)
                Spacer(minLength: 0)
                Text("\(selectedCount)/\(displayedCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

        }
        .padding(14)
        .frame(width: 310)
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
        case done
    }

    let seg: SentenceSegment
    let isActive: Bool
    let isSelectedForExport: Bool
    let onToggleExportSelection: () -> Void
    let onSelect: () -> Void
    let onToggleBookmark: () -> Void
    let onToggleNavigationBookmark: () -> Void
    let onSplit: () -> Void
    let onMergePrevious: () -> Void
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
                                focusedField = nil
                                // 编辑区域在下一次布局后才会出现，延迟设置焦点
                                // 可确保点击编辑按钮后始终落入原文输入框。
                                DispatchQueue.main.async {
                                    guard isEditing else { return }
                                    focusedField = .original
                                }
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

                            Button(action: onMergePrevious) {
                                Image(systemName: "arrow.triangle.merge")
                                    .font(.system(size: 9))
                                    .scaleEffect(x: -1, y: 1)
                            }
                            .buttonStyle(.plain)
                            .help(lang.text("合并上一句", "Merge with previous sentence"))
                            .disabled(seg.index <= 1)
                            .allowsHitTesting(isHovering && seg.index > 1)

                            Button(action: onMergeNext) {
                                Image(systemName: "arrow.triangle.merge")
                                    .font(.system(size: 9))
                                    .rotationEffect(.degrees(180))
                            }
                            .buttonStyle(.plain)
                            .help(lang.localized(.mergeSegment))
                            .allowsHitTesting(isHovering)

                            Button(action: onToggleNavigationBookmark) {
                                Image(systemName: seg.isNavigationBookmarked ? "bookmark.fill" : "bookmark")
                                    .font(.system(size: 9))
                                    .foregroundColor(seg.isNavigationBookmarked ? .blue : .secondary)
                            }
                            .buttonStyle(.plain)
                            .help(lang.text(
                                seg.isNavigationBookmarked ? "移出书签" : "加入书签",
                                seg.isNavigationBookmarked ? "Remove bookmark" : "Add bookmark"
                            ))
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
                .onKeyPress(.tab) {
                    moveEditFocus(from: .original)
                }
                .onSubmit {
                    focusedField = .translation
                }

            TextField(lang.text("译文…", "Translation…"), text: $tempTranslationText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .focused($focusedField, equals: .translation)
                .onKeyPress(.tab) {
                    moveEditFocus(from: .translation)
                }
                .onSubmit {
                    finishEditing()
                }

            Button(lang.text("完成", "Done"), action: finishEditing)
                .controlSize(.mini)
                .focusable(true)
                .focused($focusedField, equals: .done)
                .onKeyPress(.tab) {
                    moveEditFocus(from: .done)
                }
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

    private func moveEditFocus(from field: EditField) -> KeyPress.Result {
        let order: [EditField] = [.original, .translation, .done]
        guard let currentIndex = order.firstIndex(of: field) else { return .ignored }
        let nextIndex = (currentIndex + 1) % order.count
        focusedField = order[nextIndex]
        return .handled
    }
}

/// 翻译执行确认面板。它以内嵌 popover 显示在断句列表工具栏下方；翻译按钮只负责
/// 打开此面板，只有用户选择服务、模型、目标语言并点击“开始翻译”后才会创建网络任务。
private struct TranslationExecutionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var settings: TranslationSettings
    let selectedSegmentIDs: Set<UUID>
    @ObservedObject var lang: LanguageManager

    @State private var serviceID: UUID?
    @State private var targetLanguage: TranslationTargetLanguage = .simplifiedChinese
    @State private var overwriteExistingTranslations = false
    @State private var batchSizeText = "100"

    init(
        engine: PlaybackEngine,
        settings: TranslationSettings,
        selectedSegmentIDs: Set<UUID>,
        lang: LanguageManager
    ) {
        self.engine = engine
        self.settings = settings
        self.selectedSegmentIDs = selectedSegmentIDs
        self.lang = lang
        _serviceID = State(initialValue: settings.lastTranslationServiceID ?? settings.selectedServiceID)
        _targetLanguage = State(initialValue: settings.lastTranslationTargetLanguage)
    }

    private var selectedService: TranslationServiceProfile? {
        guard let serviceID else { return nil }
        return settings.services.first(where: { $0.id == serviceID })
    }

    private var targetSegmentCount: Int {
        engine.segments.reduce(into: 0) { count, segment in
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (overwriteExistingTranslations
                   || segment.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                  selectedSegmentIDs.isEmpty || selectedSegmentIDs.contains(segment.id) else { return }
            count += 1
        }
    }

    private var requestedBatchSize: Int? {
        let value = Int(batchSizeText.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let value, value > 0 else { return nil }
        return value
    }

    private var configuration: TranslationConfiguration? {
        guard let serviceID else { return nil }
        return settings.configuration(for: serviceID, targetLanguage: targetLanguage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(lang.text("确认翻译", "Confirm Translation"))
                .font(.headline)

            Text(lang.text(
                selectedSegmentIDs.isEmpty
                    ? (overwriteExistingTranslations
                       ? "将翻译当前工程中所有有原文的句子，并覆盖已有译文。"
                       : "将翻译当前工程中所有有原文且译文为空的句子。")
                    : (overwriteExistingTranslations
                       ? "将翻译当前勾选的有原文句子，并覆盖已有译文。"
                       : "将翻译当前勾选的、有原文且译文为空的句子。"),
                selectedSegmentIDs.isEmpty
                    ? (overwriteExistingTranslations
                       ? "Translate every sentence with original text and overwrite existing translations."
                       : "Translate every sentence in this project that has original text and no translation.")
                    : (overwriteExistingTranslations
                       ? "Translate the checked sentences with original text and overwrite existing translations."
                       : "Translate the checked sentences that have original text and no translation.")
            ))
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Toggle(isOn: $overwriteExistingTranslations) {
                    Text(lang.text("覆盖已有译文", "Overwrite existing translations"))
                }
                .toggleStyle(.checkbox)

                Spacer(minLength: 8)

                Text(lang.text("每批提交", "Batch size"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("100", text: $batchSizeText)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 62)
                Text(lang.text("句", "sentences"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                Text(lang.text("翻译服务", "Service"))
                    .font(.body.weight(.medium))
                    .frame(width: 88, alignment: .leading)
                Picker("", selection: $serviceID) {
                    ForEach(settings.services) { service in
                        Text(service.name).tag(Optional(service.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: serviceID) { _, value in
                    settings.rememberTranslationService(value)
                }
            }

            HStack(spacing: 8) {
                Text(lang.text("模型", "Model"))
                    .font(.body.weight(.medium))
                    .frame(width: 88, alignment: .leading)
                let models = serviceID.map { settings.availableModels(for: $0) } ?? []
                if !models.isEmpty, let serviceID {
                    Picker("", selection: Binding(
                        get: { settings.services.first(where: { $0.id == serviceID })?.model ?? "" },
                        set: { settings.updateService(id: serviceID, model: $0) }
                    )) {
                        ForEach(models) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(selectedService?.model ?? "—")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack(spacing: 8) {
                Text(lang.text("目标语言", "Target language"))
                    .font(.body.weight(.medium))
                    .frame(width: 88, alignment: .leading)
                Picker("", selection: $targetLanguage) {
                    ForEach(TranslationTargetLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: targetLanguage) { _, value in
                    settings.rememberTranslationTargetLanguage(value)
                }
            }

            if let selectedService {
                HStack(spacing: 8) {
                    Image(systemName: settings.hasAPIKey(for: selectedService.id)
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill")
                        .foregroundColor(settings.hasAPIKey(for: selectedService.id) ? .green : .orange)
                    Text(settings.hasAPIKey(for: selectedService.id)
                        ? lang.text("API Key 已配置，将使用 \(selectedService.provider.displayName) / \(selectedService.model)。", "API key is configured. Using \(selectedService.provider.displayName) / \(selectedService.model).")
                        : lang.text("当前服务尚未配置 API Key，请先在设置中填写。", "This service has no API key. Add it in Settings first."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "number")
                    .foregroundColor(.secondary)
                Text(lang.text("待翻译句子：\(targetSegmentCount) 条", "Sentences to translate: \(targetSegmentCount)"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Button(lang.text("取消", "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(lang.text("开始翻译", "Start Translation")) {
                    startTranslation()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(
                    configuration == nil
                        || targetSegmentCount == 0
                        || requestedBatchSize == nil
                        || engine.isAutoTranslating
                )
            }
        }
        .padding(14)
        .frame(width: 430)
    }

    private func startTranslation() {
        guard let serviceID, let configuration, let requestedBatchSize else { return }
        settings.rememberTranslationService(serviceID)
        settings.rememberTranslationTargetLanguage(targetLanguage)
        engine.translateMissingTranslations(
            configuration: configuration,
            segmentIDs: selectedSegmentIDs.isEmpty ? nil : selectedSegmentIDs,
            overwriteExistingTranslations: overwriteExistingTranslations,
            batchSize: requestedBatchSize
        )
        dismiss()
    }
}

#Preview("断句列表侧边栏") {
    SegmentListView(engine: PlaybackEngine.shared)
        .frame(width: 320, height: 600)
}
