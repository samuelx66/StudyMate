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
struct SegmentListFilterCriteria: Equatable, Sendable {
    var requiresOriginal = false
    var requiresTranslation = false
    var requiresMinimumDuration = false
    var minimumDurationText = "5"
    var requiresWord = false
    var wordText = ""
    var requiresBookmark = false
    var requiresIndexRange = false
    var startIndexText = ""
    var endIndexText = ""

    var hasActiveFilters: Bool {
        requiresOriginal ||
        requiresTranslation ||
        requiresMinimumDuration ||
        requiresWord ||
        requiresBookmark ||
        requiresIndexRange
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
        if requiresIndexRange {
            let start = parsedIndex(from: startIndexText)
            let end = parsedIndex(from: endIndexText)
            if let start, let end {
                let lower = min(start, end)
                let upper = max(start, end)
                guard (lower...upper).contains(segment.index) else { return false }
            } else if let start {
                guard segment.index >= start else { return false }
            } else if let end {
                guard segment.index <= end else { return false }
            }
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

    private func parsedIndex(from text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
            return nil
        }
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
/// 只有存在实际文本时才注册 AppKit tooltip tracking area；不能用空字符串占位，
/// 否则该空 tracking area 仍可能抢占顶层播放列表按钮的提示。
private struct OptionalSegmentListToolTip: ViewModifier {
    let text: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}

private struct SegmentListToolTipsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

private extension EnvironmentValues {
    var segmentListToolTipsEnabled: Bool {
        get { self[SegmentListToolTipsEnabledKey.self] }
        set { self[SegmentListToolTipsEnabledKey.self] = newValue }
    }
}

private struct SegmentListToolTipModifier: ViewModifier {
    @Environment(\.segmentListToolTipsEnabled) private var isEnabled
    let text: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.help(text)
        } else {
            content
        }
    }
}

private extension View {
    func segmentListHelp(_ text: String) -> some View {
        modifier(SegmentListToolTipModifier(text: text))
    }
}

public struct SegmentListView: View {
    @ObservedObject var engine: PlaybackEngine
    /// 播放列表等顶层抽屉展示期间，底层控件不能继续注册说明提示。
    /// AppKit 的 tooltip tracking area 不会自动遵循 SwiftUI 的视觉遮挡层级。
    private let suppressToolTips: Bool
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
    /// “反选”不是反转勾选框状态，而是把当前筛选条件取补集。
    @State private var isFilterInverted = false
    @State private var showFilterPopover: Bool = false
    @State private var showExportPopover: Bool = false
    @State private var showAddToLibraryPopover: Bool = false
    @State private var showSegmentationPopover: Bool = false
    @State private var showRegenerateOriginalConfirmation: Bool = false
    @State private var selectedSegmentIDs: Set<UUID> = []
    @State private var isAddingToLibrary: Bool = false
    @State private var exportNotice: SegmentExportNotice?
    @State private var cachedDisplayedSegments: [SentenceSegment] = []
    /// The list rows are isolated behind a lightweight revision token.  The
    /// parent still observes the engine for toolbar state, but a progress or
    /// playback-count update no longer forces the LazyVStack to rebuild all
    /// visible rows.
    @State private var displayedSegmentsRevision: Int = 0
    @State private var selectionRevision: Int = 0
    @State private var cachedSegmentIDs: Set<UUID> = []
    @State private var selectedDisplayedCountValue: Int = 0
    @State private var followState = SegmentListFollowState()
    @State private var isUserScrolling = false
    @State private var scrollSuppressionToken = UUID()
    @State private var shortcutEditRequest: UUID?
    /// Search filtering is debounced and computed from a value snapshot off
    /// the main actor.  This keeps typing responsive even with thousands of
    /// transcript rows while the visible list remains deterministic.
    @State private var displayRefreshTask: Task<Void, Never>?
    @State private var displayRefreshGeneration = UUID()

    public init(engine: PlaybackEngine, suppressToolTips: Bool = false) {
        self.engine = engine
        self.suppressToolTips = suppressToolTips
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
                    Image(systemName: "target")
                        .frame(width: 24, height: 24)
                        .foregroundColor(followState.shouldFollow ? .primary : .secondary.opacity(0.45))
                        .segmentListHelp(MacAbobooShortcutCatalog.help(
                            followState.shouldFollow
                                ? lang.text("播放时自动跟随当前句", "Follow the active sentence during playback")
                                : lang.text("已暂停自动跟随，点击恢复", "Automatic following is paused; click to resume"),
                            shortcut: .followActiveSentence
                        ))
                }
                .macabobooChromeButton(shape: .circle)
                .focusable(false)
                .segmentListHelp(MacAbobooShortcutCatalog.help(
                    followState.shouldFollow
                        ? lang.text("播放时自动跟随当前句", "Follow the active sentence during playback")
                        : lang.text("已暂停自动跟随，点击恢复", "Automatic following is paused; click to resume"),
                    shortcut: .followActiveSentence
                ))
                .keyboardShortcut("f", modifiers: [.command, .shift])

                // 句子筛选：每项都是独立复选条件，启用后自动选中符合条件的句子。
                Button {
                    showFilterPopover.toggle()
                } label: {
                    Image(systemName: filterCriteria.hasActiveFilters
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                        .frame(width: 24, height: 24)
                        .foregroundColor(filterCriteria.hasActiveFilters ? MacAbobooMediaStyle.accent : .secondary)
                }
                .macabobooChromeButton(shape: .circle)
                .focusable(false)
                .segmentListHelp(MacAbobooShortcutCatalog.help(
                    lang.text("筛选句子", "Filter sentences"),
                    shortcut: .filterSentences
                ))
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .popover(isPresented: $showFilterPopover, arrowEdge: .top) {
                    SegmentFilterPopover(
                        criteria: $filterCriteria,
                        lang: lang,
                        displayedCount: displayedSegments.count,
                        selectedCount: selectedDisplayedCount,
                        onSelectAll: selectDisplayedSegments,
                        onDeselectAll: deselectDisplayedSegments,
                        onInvertSelection: invertDisplayedSegmentSelection
                    )
                }

                // 按现有时间轴重新运行 Whisper，只覆盖原文；未勾选时处理全部句子。
                Button {
                    showRegenerateOriginalConfirmation = true
                } label: {
                    Image(systemName: "waveform.and.mic")
                        .frame(width: 24, height: 24)
                        .foregroundColor(.secondary)
                }
                .macabobooChromeButton(shape: .circle)
                .focusable(false)
                .disabled(
                    engine.currentMedia == nil
                        || engine.segments.isEmpty
                        || engine.isAITranscribing
                        || engine.isAutoTranslating
                )
                .segmentListHelp(regenerateOriginalHelpText)
                .keyboardShortcut("t", modifiers: [.command, .shift])

                // 翻译必须由用户明确发起；点击后在列表上方冒泡选择服务、模型与目标语言。
                Button {
                    showTranslationPopover = true
                } label: {
                    Image(systemName: "translate")
                        .frame(width: 24, height: 24)
                        .foregroundColor(translationSettings.isAutomaticTranslationEnabled ? .secondary : .secondary.opacity(0.45))
                }
                .macabobooChromeButton(shape: .circle)
                .focusable(false)
                .disabled(!translationSettings.isAutomaticTranslationEnabled || engine.segments.isEmpty || engine.isAutoTranslating)
                .segmentListHelp(MacAbobooShortcutCatalog.help(
                    translationSettings.isAutomaticTranslationEnabled
                        ? lang.text("翻译句子（选择服务和目标语言）", "Translate sentences (choose service and target language)")
                        : lang.text("请先在设置中启用翻译功能", "Enable translation in Settings first"),
                    shortcut: .translateSentences
                ))
                .keyboardShortcut("t", modifiers: [.command])
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
                    Image(systemName: "arrow.down.doc")
                        .frame(width: 24, height: 24)
                        .foregroundColor(.secondary)
                        .segmentListHelp(MacAbobooShortcutCatalog.help(
                            lang.text("导入字幕（SRT / LRC / VTT / ASS / SSA / TXT）", "Import subtitles (SRT / LRC / VTT / ASS / SSA / TXT)"),
                            shortcut: .importSubtitles
                        ))
                }
                .macabobooChromeButton(shape: .circle)
                .focusable(false)
                .segmentListHelp(MacAbobooShortcutCatalog.help(
                    lang.text("导入字幕（SRT / LRC / VTT / ASS / SSA / TXT）", "Import subtitles (SRT / LRC / VTT / ASS / SSA / TXT)"),
                    shortcut: .importSubtitles
                ))
                .keyboardShortcut("i", modifiers: [.command, .shift])

                // 将已选断句统一导出为音频和字幕（仅在勾选句子时显示并启用）
                if !selectedSegmentIDs.isEmpty {
                    Button {
                        showExportPopover = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 24, height: 24)
                            .foregroundColor(.secondary)
                    }
                    .macabobooChromeButton(shape: .circle)
                    .focusable(false)
                    .disabled(selectedSegmentIDs.isEmpty || engine.currentMedia == nil || statusCenter.progress != nil)
                    .segmentListHelp(MacAbobooShortcutCatalog.help(
                        lang.text("导出已选句子的 M4A 和 LRC", "Export selected sentences as M4A and LRC"),
                        shortcut: .exportMenu
                    ))
                    .keyboardShortcut("e", modifiers: [.command, .option])
                    .popover(isPresented: $showExportPopover, arrowEdge: .top) {
                        SegmentExportPopoverView(
                            onExportSeparate: {
                                showExportPopover = false
                                chooseIndividualExportDestination()
                            },
                            onExportMerged: {
                                showExportPopover = false
                                chooseMergedExportDestination()
                            },
                            lang: lang
                        )
                    }
                }

                // 将已选断句保存到当前句库；视频句子会在后台截取预览帧。
                Button {
                    showAddToLibraryPopover = true
                } label: {
                    Image(systemName: "text.badge.plus")
                        .frame(width: 24, height: 24)
                        .foregroundColor(isAddingToLibrary ? MacAbobooMediaStyle.accent : .secondary)
                }
                .macabobooChromeButton(shape: .circle)
                .focusable(false)
                .segmentListHelp(MacAbobooShortcutCatalog.help(
                    selectedSegmentIDs.isEmpty
                        ? lang.text("请先勾选要加入句库的句子", "Select sentences to add to a library")
                        : lang.text("将已选句子加入当前句库", "Add selected sentences to the current library"),
                    shortcut: .addToSentenceLibrary
                ))
                .keyboardShortcut("a", modifiers: [.command, .option])
                .popover(isPresented: $showAddToLibraryPopover, arrowEdge: .top) {
                    SegmentAddToLibraryPopoverView(
                        currentLibraryName: libraryManager.currentLibrary?.name ?? lang.text("默认句库", "Default Library"),
                        hasSelectedSegments: !selectedSegmentIDs.isEmpty && engine.currentMedia != nil,
                        isAdding: isAddingToLibrary,
                        libraries: libraryManager.libraries,
                        currentLibraryID: libraryManager.currentLibraryID,
                        onAddToCurrentLibrary: {
                            showAddToLibraryPopover = false
                            addSelectedSegmentsToLibrary()
                        },
                        onSelectLibrary: { libraryID in
                            libraryManager.selectLibrary(libraryID)
                        },
                        onOpenLibrary: {
                            showAddToLibraryPopover = false
                            openWindow(id: "sentence-library")
                        },
                        lang: lang
                    )
                }

                // 用户只决定速度优先还是质量优先；句长与证据权重由算法分析。
                Button {
                    showSegmentationPopover = true
                } label: {
                    Image(systemName: "wand.and.stars")
                        .frame(width: 24, height: 24)
                        .foregroundColor(.secondary)
                }
                .macabobooChromeButton(shape: .circle)
                .focusable(false)
                .modifier(OptionalSegmentListToolTip(text: suppressToolTips ? nil : MacAbobooShortcutCatalog.help(
                    lang.text("选择断句模式", "Choose segmentation mode"),
                    shortcut: .segmentationMenu
                )))
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .popover(isPresented: $showSegmentationPopover, arrowEdge: .top) {
                    SegmentSegmentationPopoverView(
                        onFastSegmentation: {
                            showSegmentationPopover = false
                            engine.performSegmentation(mode: .fast)
                        },
                        onIntelligentSegmentation: {
                            showSegmentationPopover = false
                            engine.performSegmentation(mode: .intelligent)
                        },
                        lang: lang
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .macabobooContentSurface(cornerRadius: 0)

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
                            .font(.caption)
                            .frame(width: 18, height: 18)
                    }
                    .macabobooChromeButton(shape: .circle)
                    .segmentListHelp(MacAbobooShortcutCatalog.help(
                        lang.text("清除搜索", "Clear search"),
                        shortcut: .clearSearch
                    ))
                    .keyboardShortcut(.escape)
                }
            }
            .padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(MacAbobooMediaStyle.separator.opacity(0.5), lineWidth: 0.7)
            )
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
                        SegmentListRowsView(
                            segments: displayedSegments,
                            activeSegmentID: activeSegmentID,
                            selectedSegmentIDs: selectedSegmentIDs,
                            engineIdentity: ObjectIdentifier(engine),
                            language: lang.currentLanguage,
                            isScrolling: isUserScrolling,
                            displayedSegmentsRevision: displayedSegmentsRevision,
                            selectionRevision: selectionRevision,
                            onToggleExportSelection: { id in
                                if selectedSegmentIDs.contains(id) {
                                    selectedSegmentIDs.remove(id)
                                } else {
                                    selectedSegmentIDs.insert(id)
                                }
                                updateSelectedDisplayedCount()
                                selectionRevision &+= 1
                            },
                            onSelect: { id in
                                engine.jumpToSegment(id: id)
                            },
                            onToggleBookmark: { id in
                                engine.toggleBookmark(for: id)
                            },
                            onToggleNavigationBookmark: { id in
                                engine.toggleNavigationBookmark(for: id)
                            },
                            onSplit: { id, midpoint in
                                engine.splitSegment(id: id, at: midpoint)
                            },
                            onMergePrevious: { id in
                                engine.mergeSegmentWithPrevious(id: id)
                            },
                            onMergeNext: { id in
                                engine.mergeSegmentWithNext(id: id)
                            },
                            onDelete: { id in
                                engine.deleteSegment(id: id)
                            },
                            onSaveText: { id, originalText, translationText in
                                engine.updateSegmentText(
                                    id: id,
                                    text: originalText,
                                    translation: translationText
                                )
                            },
                            onUserScroll: {
                                markUserScroll()
                            },
                            onScrollStateChanged: { scrolling in
                                if isUserScrolling != scrolling {
                                    isUserScrolling = scrolling
                                }
                            },
                            editRequest: $shortcutEditRequest,
                            lang: lang
                        )
                        .equatable()
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
        .background(MacAbobooMediaStyle.windowBackground)
        .frame(minWidth: 220)
        .sheet(isPresented: $showImportSheet) {
            SubtitleImportSheet(engine: engine)
        }
        .confirmationDialog(
            validSelectedSegmentIDs.isEmpty
                ? lang.text("重新生成全部原文？", "Regenerate all original text?")
                : lang.text("重新生成已选原文？", "Regenerate selected original text?"),
            isPresented: $showRegenerateOriginalConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                validSelectedSegmentIDs.isEmpty
                    ? lang.text(
                        "覆盖并重新生成全部 \(engine.segments.count) 句",
                        "Overwrite and regenerate all \(engine.segments.count) sentences"
                    )
                    : lang.text(
                        "覆盖并重新生成已选 \(validSelectedSegmentIDs.count) 句",
                        "Overwrite and regenerate \(validSelectedSegmentIDs.count) selected sentences"
                    ),
                role: .destructive
            ) {
                engine.regenerateOriginalText(
                    segmentIDs: validSelectedSegmentIDs.isEmpty ? nil : validSelectedSegmentIDs
                )
            }
            Button(lang.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(lang.text(
                "Whisper 将按现有时间轴重新识别并覆盖已有原文。译文、断句时间和其他句子数据不会改变。",
                "Whisper will recognize the existing time ranges again and overwrite original text. Translations, sentence timing, and other sentence data will not change."
            ))
        }
        .onAppear { refreshDisplayedSegments() }
        .onChange(of: engine.segments) { _, _ in refreshDisplayedSegments() }
        .onChange(of: searchText) { _, _ in scheduleSearchRefresh() }
        .onChange(of: filterCriteria) { _, _ in
            if !filterCriteria.hasActiveFilters {
                isFilterInverted = false
            }
            refreshDisplayedSegments(selectMatching: filterCriteria.hasActiveFilters)
        }
        .onDisappear {
            invalidateScheduledDisplayRefresh()
        }
        .alert(item: $exportNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text(lang.text("好", "OK")))
            )
        }
        .background(listKeyboardShortcuts)
        .environment(\.segmentListToolTipsEnabled, !suppressToolTips)
    }

    private var activeSegmentID: UUID? {
        guard let index = engine.activeSegmentIndex,
              engine.segments.indices.contains(index) else { return nil }
        return engine.segments[index].id
    }

    private var listKeyboardShortcuts: some View {
        Group {
            Button(action: toggleActiveSentenceSelection) { EmptyView() }
                .keyboardShortcut(.space, modifiers: [.command, .shift])

            Button(action: selectActiveSentence) { EmptyView() }
                .keyboardShortcut(.return, modifiers: [.command])

            Button(action: toggleActiveDifficultyBookmark) { EmptyView() }
                .keyboardShortcut("b", modifiers: [.command, .shift])

            Button(action: requestEditActiveSentence) { EmptyView() }
                .keyboardShortcut("y", modifiers: [.command, .shift])

            Button(action: splitActiveSentence) { EmptyView() }
                .keyboardShortcut("s", modifiers: [.command, .shift])

            Button(action: mergeActiveWithPrevious) { EmptyView() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

            Button(action: mergeActiveWithNext) { EmptyView() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

            Button(action: toggleActiveNavigationBookmark) { EmptyView() }
                .keyboardShortcut("b", modifiers: [.command])

            Button(action: deleteActiveSentence) { EmptyView() }
                .keyboardShortcut(.delete, modifiers: [.command])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
    }

    private func toggleActiveSentenceSelection() {
        guard let id = activeSegmentID else { return }
        if selectedSegmentIDs.contains(id) {
            selectedSegmentIDs.remove(id)
        } else {
            selectedSegmentIDs.insert(id)
        }
        updateSelectedDisplayedCount()
        selectionRevision &+= 1
    }

    private func selectActiveSentence() {
        guard let id = activeSegmentID else { return }
        engine.jumpToSegment(id: id)
    }

    private func toggleActiveDifficultyBookmark() {
        guard let id = activeSegmentID else { return }
        engine.toggleBookmark(for: id)
    }

    private func requestEditActiveSentence() {
        guard let id = activeSegmentID else { return }
        shortcutEditRequest = id
        DispatchQueue.main.async {
            if shortcutEditRequest == id { shortcutEditRequest = nil }
        }
    }

    private func splitActiveSentence() {
        guard let id = activeSegmentID,
              let segment = engine.segments.first(where: { $0.id == id }) else { return }
        engine.splitSegment(id: id, at: (segment.startTime + segment.endTime) / 2.0)
    }

    private func mergeActiveWithPrevious() {
        guard let id = activeSegmentID else { return }
        engine.mergeSegmentWithPrevious(id: id)
    }

    private func mergeActiveWithNext() {
        guard let id = activeSegmentID else { return }
        engine.mergeSegmentWithNext(id: id)
    }

    private func toggleActiveNavigationBookmark() {
        guard let id = activeSegmentID else { return }
        engine.toggleNavigationBookmark(for: id)
    }

    private func deleteActiveSentence() {
        guard let id = activeSegmentID else { return }
        engine.deleteSegment(id: id)
    }

    private func refreshDisplayedSegments(selectMatching: Bool = false) {
        invalidateScheduledDisplayRefresh()
        let result = Self.computeDisplayedSegments(
            from: engine.segments,
            criteria: filterCriteria,
            searchText: searchText,
            isFilterInverted: isFilterInverted
        )
        applyDisplayedSegments(result, selectMatching: selectMatching)
    }

    private struct DisplayRefreshResult: Sendable {
        let list: [SentenceSegment]
        let criteriaResultIDs: [UUID]
        let allIDs: [UUID]
    }

    nonisolated private static func computeDisplayedSegments(
        from segments: [SentenceSegment],
        criteria: SegmentListFilterCriteria,
        searchText: String,
        isFilterInverted: Bool
    ) -> DisplayRefreshResult {
        let hasActiveFilters = criteria.hasActiveFilters
        let criteriaResult = segments.filter { segment in
            let matches = criteria.matches(segment)
            return isFilterInverted && hasActiveFilters ? !matches : matches
        }
        var list = criteriaResult
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            list = list.filter {
                $0.text.localizedCaseInsensitiveContains(query) ||
                $0.translation.localizedCaseInsensitiveContains(query)
            }
        }
        return DisplayRefreshResult(
            list: list,
            criteriaResultIDs: criteriaResult.map(\.id),
            allIDs: segments.map(\.id)
        )
    }

    private func applyDisplayedSegments(
        _ result: DisplayRefreshResult,
        selectMatching: Bool
    ) {
        cachedDisplayedSegments = result.list
        cachedSegmentIDs = Set(result.allIDs)
        displayedSegmentsRevision &+= 1
        if selectMatching && filterCriteria.hasActiveFilters {
            selectedSegmentIDs = Set(result.list.map(\.id))
        } else if filterCriteria.hasActiveFilters {
            // 底层句子被编辑、合并或星标状态变化后，移除已不再符合当前结果的隐藏选择；
            // 但保留用户对仍符合条件句子的手动取消勾选。搜索词不参与此集合，避免搜索栏改变导出范围。
            selectedSegmentIDs.formIntersection(result.criteriaResultIDs)
        } else {
            selectedSegmentIDs.formIntersection(result.allIDs)
        }
        updateSelectedDisplayedCount()
        selectionRevision &+= 1
    }

    private func invalidateScheduledDisplayRefresh() {
        displayRefreshTask?.cancel()
        displayRefreshTask = nil
        displayRefreshGeneration = UUID()
    }

    private func scheduleSearchRefresh() {
        displayRefreshTask?.cancel()
        let generation = UUID()
        displayRefreshGeneration = generation
        let snapshot = engine.segments
        let criteria = filterCriteria
        let query = searchText
        let inverted = isFilterInverted
        displayRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, generation == displayRefreshGeneration else { return }
            let result = await Task.detached(priority: .userInitiated) {
                Self.computeDisplayedSegments(
                    from: snapshot,
                    criteria: criteria,
                    searchText: query,
                    isFilterInverted: inverted
                )
            }.value
            guard !Task.isCancelled, generation == displayRefreshGeneration else { return }
            applyDisplayedSegments(result, selectMatching: false)
            displayRefreshTask = nil
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

    private var selectedDisplayedCount: Int {
        selectedDisplayedCountValue
    }

    private var validSelectedSegmentIDs: Set<UUID> {
        selectedSegmentIDs.intersection(cachedSegmentIDs)
    }

    private var regenerateOriginalHelpText: String {
        let count = validSelectedSegmentIDs.count
        let desc = count == 0
            ? lang.text("重新生成全部句子的原文", "Regenerate original text for all sentences")
            : lang.text("重新生成已选 \(count) 个句子的原文", "Regenerate original text for \(count) selected sentences")
        return MacAbobooShortcutCatalog.help(desc, shortcut: .regenerateOriginalText)
    }

    private func selectDisplayedSegments() {
        selectedSegmentIDs.formUnion(displayedSegments.map(\.id))
        updateSelectedDisplayedCount()
        selectionRevision &+= 1
    }

    private func deselectDisplayedSegments() {
        selectedSegmentIDs.subtract(displayedSegments.map(\.id))
        updateSelectedDisplayedCount()
        selectionRevision &+= 1
    }

    private func updateSelectedDisplayedCount() {
        selectedDisplayedCountValue = cachedDisplayedSegments.reduce(into: 0) { count, segment in
            if selectedSegmentIDs.contains(segment.id) { count += 1 }
        }
    }

    private func invertDisplayedSegmentSelection() {
        guard filterCriteria.hasActiveFilters else { return }
        // 反选作用于“筛选条件的结果集”，不是当前勾选状态：
        // 例如 20 句中筛出 3 句时，反选会显示并选中另外 17 句。
        isFilterInverted.toggle()
        refreshDisplayedSegments(selectMatching: true)
    }

    private func chooseIndividualExportDestination() {
        guard let media = engine.currentMedia, !selectedSegments.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = lang.text("选择", "Choose")
        panel.message = lang.text("选择逐句 M4A、LRC 和 SRT 的保存位置", "Choose where to save separate M4A, LRC, and SRT files")
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
        panel.message = lang.text("将生成一个 AAC 编码的 M4A 以及同名 LRC 与 SRT 字幕", "One AAC-encoded M4A and matching LRC and SRT subtitles will be created")
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
    let onDeselectAll: () -> Void
    let onInvertSelection: () -> Void

    private var isAllSelected: Bool {
        displayedCount > 0 && selectedCount == displayedCount
    }

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

            HStack(spacing: 6) {
                Toggle(isOn: $criteria.requiresIndexRange) {
                    Text(lang.text("只显示编号", "Only sentence numbers"))
                }
                .toggleStyle(.checkbox)

                Text("#")
                    .foregroundColor(.secondary)
                TextField("x", text: $criteria.startIndexText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 46)
                    .disabled(!criteria.requiresIndexRange)

                Text(lang.text("到 #", "to #"))
                    .foregroundColor(.secondary)
                TextField("y", text: $criteria.endIndexText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 46)
                    .disabled(!criteria.requiresIndexRange)
            }

            Divider()

            HStack(spacing: 8) {
                Button(
                    isAllSelected ? lang.text("清除", "Clear") : lang.text("全选", "Select All"),
                    action: isAllSelected ? onDeselectAll : onSelectAll
                )
                .disabled(displayedCount == 0)
                .keyboardShortcut("a", modifiers: [.command])
                .segmentListHelp(MacAbobooShortcutCatalog.help(
                    isAllSelected
                        ? lang.text("清除选择", "Clear Selection")
                        : lang.text("全选", "Select All"),
                    shortcut: .selectAllVisibleSentences
                ))
                Button(lang.text("反选", "Invert Selection"), action: onInvertSelection)
                    .disabled(displayedCount == 0)
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .segmentListHelp(MacAbobooShortcutCatalog.help(
                        lang.text("反选", "Invert Selection"),
                        shortcut: .invertVisibleSentenceSelection
                    ))
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

private struct SegmentExportPopoverView: View {
    let onExportSeparate: () -> Void
    let onExportMerged: () -> Void
    @ObservedObject var lang: LanguageManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(lang.text("导出音频与字幕", "Export Audio & Subtitles"))
                .font(.headline)
                .padding(.bottom, 2)

            Button(action: onExportSeparate) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 16)
                    Text(lang.text("逐句导出 M4A＋LRC…", "Export separate M4A + LRC…"))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)

            Button(action: onExportMerged) {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.stack")
                        .frame(width: 16)
                    Text(lang.text("合并导出 M4A＋LRC…", "Export merged M4A + LRC…"))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)
        }
        .padding(12)
        .frame(minWidth: 200)
    }
}

private struct SegmentAddToLibraryPopoverView: View {
    let currentLibraryName: String
    let hasSelectedSegments: Bool
    let isAdding: Bool
    let libraries: [SentenceLibraryDescriptor]
    let currentLibraryID: UUID?
    let onAddToCurrentLibrary: () -> Void
    let onSelectLibrary: (UUID) -> Void
    let onOpenLibrary: () -> Void
    @ObservedObject var lang: LanguageManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(lang.text("句库操作", "Sentence Library"))
                .font(.headline)
                .padding(.bottom, 2)

            Button(action: onAddToCurrentLibrary) {
                HStack(spacing: 8) {
                    Image(systemName: "text.badge.plus")
                        .frame(width: 16)
                    Text(
                        lang.text(
                            "加入“\(currentLibraryName)”",
                            "Add to “\(currentLibraryName)”"
                        )
                    )
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Popover 打开时不把第一个操作项设为默认键盘焦点；用户
            // 仍可用鼠标点击任意操作项。
            .focusable(false)
            .disabled(!hasSelectedSegments || isAdding)
            .padding(.vertical, 4)

            if libraries.count > 1 {
                Divider()
                Text(lang.text("切换当前句库", "Switch Library"))
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(libraries) { library in
                    Button {
                        onSelectLibrary(library.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: library.id == currentLibraryID ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(library.id == currentLibraryID ? MacAbobooMediaStyle.accent : .secondary)
                                .frame(width: 16)
                            Text(library.name)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .padding(.vertical, 2)
                }
            }

            Divider()

            Button(action: onOpenLibrary) {
                HStack(spacing: 8) {
                    Image(systemName: "books.vertical")
                        .frame(width: 16)
                    Text(lang.text("打开句库管理…", "Open Sentence Library…"))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .padding(.vertical, 4)
        }
        .padding(12)
        .frame(minWidth: 220)
        .focusable(false)
    }
}

private struct SegmentSegmentationPopoverView: View {
    let onFastSegmentation: () -> Void
    let onIntelligentSegmentation: () -> Void
    @ObservedObject var lang: LanguageManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(lang.text("断句模式", "Segmentation Mode"))
                .font(.headline)
                .padding(.bottom, 2)

            Button(action: onFastSegmentation) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .frame(width: 16)
                    Text(lang.text("快速断句（默认）", "Fast segmentation (Default)"))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .padding(.vertical, 4)

            Button(action: onIntelligentSegmentation) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .frame(width: 16)
                    Text(lang.text("智能断句", "Intelligent segmentation"))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .padding(.vertical, 4)
        }
        .padding(12)
        .frame(minWidth: 220)
        .focusable(false)
    }
}

/// Detects trackpad/mouse scrolling without replacing SwiftUI's ScrollView.
/// `willStartLiveScroll` is emitted for user scrolling, not for the list's
/// programmatic `scrollTo`, so playback following can be paused safely.
private struct ScrollViewInteractionObserver: NSViewRepresentable {
    let onUserScroll: () -> Void
    let onScrollStateChanged: (Bool) -> Void

    func makeNSView(context: Context) -> ScrollInteractionNSView {
        let view = ScrollInteractionNSView()
        view.onUserScroll = onUserScroll
        view.onScrollStateChanged = onScrollStateChanged
        return view
    }

    func updateNSView(_ nsView: ScrollInteractionNSView, context: Context) {
        nsView.onUserScroll = onUserScroll
        nsView.onScrollStateChanged = onScrollStateChanged
    }
}

private final class ScrollInteractionNSView: NSView {
    var onUserScroll: (() -> Void)?
    var onScrollStateChanged: ((Bool) -> Void)?
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
                self.onScrollStateChanged?(true)
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
                    self.onScrollStateChanged?(true)
                    self.scheduleLiveScrollReset()
                }
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
                self.onScrollStateChanged?(false)
            }
        ]
    }

    private func scheduleLiveScrollReset() {
        // `didLiveScroll` can be delivered for every trackpad tick.  Keep one
        // long-lived fallback only for the rare case where AppKit omits the
        // matching didEnd notification; do not allocate/cancel a work item on
        // every pixel of a gesture.
        guard liveScrollResetWorkItem == nil else { return }
        liveScrollResetWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.liveScrollResetWorkItem = nil
            self.isLiveScrolling = false
            self.onScrollStateChanged?(false)
        }
        liveScrollResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: workItem)
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        notificationTokens.forEach(center.removeObserver)
        notificationTokens.removeAll(keepingCapacity: true)
        liveScrollResetWorkItem?.cancel()
        liveScrollResetWorkItem = nil
        observedScrollView = nil
        isLiveScrolling = false
        onScrollStateChanged?(false)
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

/// The scrollable row container is equatable by explicit, low-cost revision
/// tokens.  `SegmentListView` also observes the engine for its toolbar, but
/// repeat counters, progress text, and other unrelated engine changes no
/// longer rebuild the complete LazyVStack tree.
private struct SegmentListRowsView: View, Equatable {
    let segments: [SentenceSegment]
    let activeSegmentID: UUID?
    let selectedSegmentIDs: Set<UUID>
    let engineIdentity: ObjectIdentifier
    let language: AppLanguage
    let isScrolling: Bool
    let displayedSegmentsRevision: Int
    let selectionRevision: Int
    let onToggleExportSelection: (UUID) -> Void
    let onSelect: (UUID) -> Void
    let onToggleBookmark: (UUID) -> Void
    let onToggleNavigationBookmark: (UUID) -> Void
    let onSplit: (UUID, Double) -> Void
    let onMergePrevious: (UUID) -> Void
    let onMergeNext: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onSaveText: (UUID, String, String) -> Void
    let onUserScroll: () -> Void
    let onScrollStateChanged: (Bool) -> Void
    @Binding var editRequest: UUID?
    let lang: LanguageManager

    var body: some View {
        LazyVStack(spacing: 2) {
            ForEach(segments) { seg in
                SegmentRowView(
                    seg: seg,
                    isActive: activeSegmentID == seg.id,
                    isSelectedForExport: selectedSegmentIDs.contains(seg.id),
                    isScrolling: isScrolling,
                    onToggleExportSelection: {
                        onToggleExportSelection(seg.id)
                    },
                    onSelect: {
                        onSelect(seg.id)
                    },
                    onToggleBookmark: {
                        onToggleBookmark(seg.id)
                    },
                    onToggleNavigationBookmark: {
                        onToggleNavigationBookmark(seg.id)
                    },
                    onSplit: {
                        onSplit(seg.id, (seg.startTime + seg.endTime) / 2.0)
                    },
                    onMergePrevious: {
                        onMergePrevious(seg.id)
                    },
                    onMergeNext: {
                        onMergeNext(seg.id)
                    },
                    onDelete: {
                        onDelete(seg.id)
                    },
                    onSaveText: { originalText, translationText in
                        onSaveText(seg.id, originalText, translationText)
                    },
                    editRequest: $editRequest,
                    lang: lang,
                    language: language
                )
                .equatable()
                .id(seg.id)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            ScrollViewInteractionObserver(
                onUserScroll: onUserScroll,
                onScrollStateChanged: onScrollStateChanged
            )
            .frame(width: 1, height: 1)
        )
    }
}

extension SegmentListRowsView {
    static func == (lhs: SegmentListRowsView, rhs: SegmentListRowsView) -> Bool {
        // Function values intentionally do not participate in equality.  All
        // callbacks target the same engine and are recreated by the parent;
        // the visible data is represented by the revision tokens below.
        lhs.displayedSegmentsRevision == rhs.displayedSegmentsRevision
            && lhs.selectionRevision == rhs.selectionRevision
            && lhs.activeSegmentID == rhs.activeSegmentID
            && lhs.engineIdentity == rhs.engineIdentity
            && lhs.language.rawValue == rhs.language.rawValue
            && lhs.isScrolling == rhs.isScrolling
            && lhs.editRequest == rhs.editRequest
    }
}

/// 单行断句单元格
struct SegmentRowView: View, Equatable {
    let seg: SentenceSegment
    let isActive: Bool
    let isSelectedForExport: Bool
    let isScrolling: Bool
    let onToggleExportSelection: () -> Void
    let onSelect: () -> Void
    let onToggleBookmark: () -> Void
    let onToggleNavigationBookmark: () -> Void
    let onSplit: () -> Void
    let onMergePrevious: () -> Void
    let onMergeNext: () -> Void
    let onDelete: () -> Void
    let onSaveText: (String, String) -> Void
    @Binding var editRequest: UUID?
    let lang: LanguageManager
    let language: AppLanguage

    @State private var isHovering: Bool = false
    @State private var isEditing: Bool = false
    @State private var editSessionID = UUID()

    static func == (lhs: SegmentRowView, rhs: SegmentRowView) -> Bool {
        lhs.seg == rhs.seg
            && lhs.isActive == rhs.isActive
            && lhs.isSelectedForExport == rhs.isSelectedForExport
            && lhs.isScrolling == rhs.isScrolling
            && lhs.editRequest == rhs.editRequest
            && lhs.language == rhs.language
    }

    var body: some View {
        HStack(spacing: 0) {
                Button(action: onToggleExportSelection) {
                    Image(systemName: isSelectedForExport ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundColor(isSelectedForExport ? MacAbobooMediaStyle.accent : .secondary.opacity(0.45))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .segmentListHelp(MacAbobooShortcutCatalog.help(
                    lang.text("选择此句用于导出或加入句库", "Select this sentence for export or sentence library"),
                    shortcut: .toggleSentenceSelection
                ))
                .padding(.leading, 4)
                .padding(.trailing, 6)

                // 左侧活跃状态指示竖条
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isActive ? MacAbobooMediaStyle.accent : Color.clear)
                    .frame(width: 3)
                    .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        // 难句收藏星标按钮
                        Button(action: onToggleBookmark) {
                            Image(systemName: seg.isBookmarked ? "star.fill" : "star")
                                .font(.system(size: 10))
                                .frame(width: 20, height: 20)
                                .foregroundColor(seg.isBookmarked ? .yellow : .gray.opacity(0.4))
                        }
                        .macabobooChromeButton(shape: .circle)
                        .segmentListHelp(MacAbobooShortcutCatalog.help(
                            lang.text("切换难句星标", "Toggle difficulty star"),
                            shortcut: .toggleDifficultyBookmark
                        ))
                        .zIndex(3)

                        // 序号
                        Text("#\(seg.index)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(isActive ? MacAbobooMediaStyle.accent : Color.gray.opacity(0.2))
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
                                .segmentListHelp(lang.text("SpeakerKit 说话人标签", "SpeakerKit speaker label"))
                        }

                        Spacer()

                        // 时长
                        Text(seg.formattedDuration)
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundColor(.secondary.opacity(0.8))

                        // 悬停操作按钮：未悬停时只保留固定宽度的占位，不创建
                        // 玻璃按钮和帮助提示，避免长列表中每行常驻一整套控件。
                        ZStack(alignment: .trailing) {
                            if isHovering && !isScrolling {
                                HStack(spacing: 4) {
                                    Button(action: {
                                        beginEditing()
                                    }) {
                                        Image(systemName: "pencil")
                                            .font(.system(size: 9))
                                            .frame(width: 20, height: 20)
                                    }
                                    .macabobooChromeButton(shape: .circle)
                                    .segmentListHelp(MacAbobooShortcutCatalog.help(
                                        lang.text("编辑原文和译文", "Edit original text and translation"),
                                        shortcut: .editSentence
                                    ))

                                    Button(action: onSplit) {
                                        Image(systemName: "rectangle.split.2x1")
                                            .font(.system(size: 9))
                                            .frame(width: 20, height: 20)
                                    }
                                    .macabobooChromeButton(shape: .circle)
                                    .segmentListHelp(MacAbobooShortcutCatalog.help(
                                        lang.text("在中间拆分此句", "Split this sentence at its midpoint"),
                                        shortcut: .splitSentence
                                    ))

                                    Button(action: onMergePrevious) {
                                        Image(systemName: "arrow.triangle.merge")
                                            .font(.system(size: 9))
                                            .frame(width: 20, height: 20)
                                            .scaleEffect(x: -1, y: 1)
                                    }
                                    .macabobooChromeButton(shape: .circle)
                                    .segmentListHelp(MacAbobooShortcutCatalog.help(
                                        lang.text("合并上一句", "Merge with previous sentence"),
                                        shortcut: .mergePreviousSentence
                                    ))
                                    .disabled(seg.index <= 1)

                                    Button(action: onMergeNext) {
                                        Image(systemName: "arrow.triangle.merge")
                                            .font(.system(size: 9))
                                            .frame(width: 20, height: 20)
                                            .rotationEffect(.degrees(180))
                                    }
                                    .macabobooChromeButton(shape: .circle)
                                    .segmentListHelp(MacAbobooShortcutCatalog.help(
                                        lang.localized(.mergeSegment),
                                        shortcut: .mergeNextSentence
                                    ))

                                    Button(action: onToggleNavigationBookmark) {
                                        Image(systemName: seg.isNavigationBookmarked ? "bookmark.fill" : "bookmark")
                                            .font(.system(size: 9))
                                            .frame(width: 20, height: 20)
                                            .foregroundColor(seg.isNavigationBookmarked ? MacAbobooMediaStyle.accent : .secondary)
                                    }
                                    .macabobooChromeButton(shape: .circle)
                                    .segmentListHelp(MacAbobooShortcutCatalog.help(
                                        lang.text(
                                            seg.isNavigationBookmarked ? "移出书签" : "加入书签",
                                            seg.isNavigationBookmarked ? "Remove bookmark" : "Add bookmark"
                                        ),
                                        shortcut: .toggleNavigationBookmark
                                    ))

                                    Button(action: onDelete) {
                                        Image(systemName: "trash")
                                            .font(.system(size: 9))
                                            .frame(width: 20, height: 20)
                                            .foregroundColor(.red)
                                    }
                                    .macabobooChromeButton(shape: .circle)
                                    .segmentListHelp(MacAbobooShortcutCatalog.help(
                                        lang.localized(.deleteSegment),
                                        shortcut: .deleteSentence
                                    ))
                                }
                            }
                        }
                        // Six 20pt controls plus five 4pt gaps.  Keeping this
                        // placeholder width prevents text from shifting when
                        // the pointer enters or leaves a row.
                        .frame(width: 140, height: 20, alignment: .trailing)
                        .zIndex(3)
                    }

                    // 第二行：分为两个区域，左边显示原文，右边显示译文
                    if isEditing {
                        SegmentInlineSubtitleEditor(
                            originalText: seg.text,
                            translationText: seg.translation,
                            onFinish: { original, translation in
                                guard isEditing else { return }
                                onSaveText(original, translation)
                                isEditing = false
                            },
                            onCancel: {
                                isEditing = false
                            }
                        )
                        .id(editSessionID)
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
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)
                .accessibilityAddTraits(.isButton)
        }
        .contentShape(Rectangle())
        // 行内的复选框和六个操作按钮不能嵌套在父 Button 内；嵌套 Button
        // 会让 AppKit 事件与辅助功能焦点在不同 macOS 版本中不稳定。行本身
        // 使用明确的点按手势，子控件保持各自独立的点击语义。
        .accessibilityElement(children: .contain)
        .macabobooSelectableRowSurface(isActive: isActive, isHovered: isHovering)
        .onHover { inside in
            isHovering = inside
        }
        .onChange(of: editRequest) { _, requestedID in
            guard requestedID == seg.id else { return }
            beginEditing()
        }
    }

    private func beginEditing() {
        editSessionID = UUID()
        isEditing = true
    }
}

/// 输入状态与复杂的句子行渲染树隔离。每次按键只重绘这三个轻量控件，
/// 不再重建整行时间戳、按钮、标签和背景，长列表中编辑也能即时跟手。
private struct SegmentInlineSubtitleEditor: View {
    private enum EditField: Hashable {
        case original
        case translation
        case done
    }

    @ObservedObject private var lang = LanguageManager.shared
    @State private var originalText: String
    @State private var translationText: String
    @State private var isResolved = false
    @FocusState private var focusedField: EditField?
    let onFinish: (String, String) -> Void
    let onCancel: () -> Void

    init(
        originalText: String,
        translationText: String,
        onFinish: @escaping (String, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _originalText = State(initialValue: originalText)
        _translationText = State(initialValue: translationText)
        self.onFinish = onFinish
        self.onCancel = onCancel
    }

    var body: some View {
        HStack(spacing: 4) {
            TextField(lang.text("原文…", "Original text…"), text: $originalText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .focused($focusedField, equals: .original)
                .onKeyPress(.tab) { moveFocus(from: .original) }
                .onSubmit { focusedField = .translation }

            TextField(lang.text("译文…", "Translation…"), text: $translationText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .focused($focusedField, equals: .translation)
                .onKeyPress(.tab) { moveFocus(from: .translation) }
                .onSubmit { finish() }

            Button(lang.text("完成", "Done"), action: finish)
                .controlSize(.mini)
                .focusable(true)
                .focused($focusedField, equals: .done)
                .onKeyPress(.tab) { moveFocus(from: .done) }
                .onKeyPress(.return) {
                    finish()
                    return .handled
                }
        }
        .onAppear {
            DispatchQueue.main.async {
                guard !isResolved else { return }
                focusedField = .original
            }
        }
        .onKeyPress(.escape) {
            cancel()
            return .handled
        }
        .onExitCommand(perform: cancel)
        .onChange(of: focusedField) { oldField, newField in
            if oldField != nil, newField == nil { finish() }
        }
    }

    private func finish() {
        guard !isResolved else { return }
        isResolved = true
        onFinish(originalText, translationText)
    }

    private func cancel() {
        guard !isResolved else { return }
        isResolved = true
        onCancel()
    }

    private func moveFocus(from field: EditField) -> KeyPress.Result {
        let order: [EditField] = [.original, .translation, .done]
        guard let currentIndex = order.firstIndex(of: field) else { return .ignored }
        focusedField = order[(currentIndex + 1) % order.count]
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
