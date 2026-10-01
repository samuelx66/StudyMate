import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct SentenceLibraryView: View {
    @ObservedObject var manager: SentenceLibraryManager
    @ObservedObject private var lang = LanguageManager.shared
    @StateObject private var libraryPlayer: SentenceLibraryPlayer
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("StudyMate.PlaybackInterfaceMode") private var playbackInterfaceMode: PlaybackInterfaceMode = .video

    @State private var searchText = ""
    @State private var dateFilter: SentenceLibraryDateFilter = .all
    @State private var selectedDate = Date()
    @State private var selectedSource = ""
    @State private var sortOrder: SentenceLibrarySortOrder = .newestFirst
    @State private var selectedEntryIDs: Set<UUID> = []
    @State private var selectedEntryID: UUID?
    @State private var previewRequest: SentencePreviewRequest?
    @State private var showCreateSheet = false
    @State private var showRenameSheet = false
    @State private var libraryToRename: SentenceLibraryDescriptor?
    @State private var confirmLibraryDeletion = false
    @State private var confirmMove = false
    @State private var pendingMoveDestinationID: UUID?
    @State private var notice: SentenceLibraryNotice?
    @State private var isPreparingStudy = false
    @State private var showBatchTagPopover = false
    @State private var showBatchSourcePopover = false

    private var learningPackageType: UTType {
        UTType(exportedAs: "com.studymate.learning-package", conformingTo: .data)
    }

    public init(manager: SentenceLibraryManager) {
        self.manager = manager
        self._libraryPlayer = StateObject(wrappedValue: SentenceLibraryPlayer())
    }

    private var selectedEntry: SentenceLibraryEntry? {
        manager.entries.first { $0.id == selectedEntryID }
    }

    private var selectedVisibleEntries: [SentenceLibraryEntry] {
        manager.entries.filter { selectedEntryIDs.contains($0.id) }
    }

    private var missingSelectedEntries: [SentenceLibraryEntry] {
        selectedVisibleEntries.filter { $0.wordTokens == nil || $0.wordTokens?.isEmpty == true }
    }

    private var selectedEntryPosition: Int? {
        let id = libraryPlayer.currentEntry?.id ?? selectedEntryID
        guard let id,
              let index = manager.entries.firstIndex(where: { $0.id == id }) else { return nil }
        return index + 1
    }

    public var body: some View {
        let visibleIDs = Set(manager.entries.lazy.map(\.id))
        let selectedVisibleCount = selectedEntryIDs.intersection(visibleIDs).count

        NavigationSplitView {
            // MARK: - 左侧句库列表 (Sidebar)
            VStack(spacing: 0) {
                List(selection: Binding(
                    get: { manager.currentLibraryID },
                    set: { if let id = $0 { manager.selectLibrary(id) } }
                )) {
                    ForEach(manager.libraries) { library in
                        HStack(spacing: 8) {
                            Label(library.name, systemImage: "books.vertical")
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            let count = manager.librarySentenceCounts[library.id] ?? (library.id == manager.currentLibraryID ? manager.entries.count : 0)
                            Text("\(count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                        .tag(library.id)
                        .contextMenu {
                            Button {
                                libraryToRename = library
                                showRenameSheet = true
                            } label: {
                                Label(lang.text("重命名句库…", "Rename Library…"), systemImage: "pencil")
                            }

                            Button {
                                chooseLearningPackageExport()
                            } label: {
                                Label(lang.text("导出学习包…", "Export Learning Package…"), systemImage: "square.and.arrow.up")
                            }

                            Divider()

                            Button(role: .destructive) {
                                if library.id == manager.currentLibraryID {
                                    confirmLibraryDeletion = true
                                } else {
                                    manager.selectLibrary(library.id)
                                    confirmLibraryDeletion = true
                                }
                            } label: {
                                Label(lang.text("删除句库", "Delete Library"), systemImage: "trash")
                            }
                            .disabled(library.isDefault)
                        }
                    }
                }
                .listStyle(.sidebar)

                Divider()

                // 侧边栏底部精简工具栏
                HStack(spacing: 8) {
                    Button {
                        showCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .disabled(manager.isWorking)
                    .help(lang.text("新建句库", "New Library"))

                    Button {
                        if let current = manager.currentLibrary {
                            libraryToRename = current
                            showRenameSheet = true
                        }
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .disabled(manager.isWorking || manager.currentLibrary == nil)
                    .help(lang.text("重命名当前句库", "Rename Current Library"))

                    Spacer()

                    Button(role: .destructive) {
                        confirmLibraryDeletion = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .disabled(!manager.canDeleteCurrentLibrary)
                    .help(
                        manager.currentLibrary?.isDefault == true
                            ? lang.text("默认句库不可删除", "The default library cannot be deleted")
                            : lang.text("删除当前句库", "Delete Current Library")
                    )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .navigationTitle(lang.text("句库", "Libraries"))
            .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
        } detail: {
            // MARK: - 主详情视图 (Detail Area)
            VStack(spacing: 0) {
                // 顶部工具栏 (Header Bar)
                HStack(spacing: 10) {
                    // 核心主行动：进入学习
                    Button {
                        enterStudyMode()
                    } label: {
                        if isPreparingStudy {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(lang.text("准备中…", "Preparing…"))
                            }
                        } else {
                            Label(lang.text("进入学习", "Study"), systemImage: "graduationcap.fill")
                                .fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPreparingStudy || manager.isWorking || manager.entries.isEmpty)
                    .help(lang.text("以 5 大学习模式开始复习当前句库", "Start studying current library with 5 study modes"))

                    // 快速分类过滤段 (Segmented Picker)：全部 / 星标 / 生词
                    Picker("", selection: Binding(
                        get: { manager.typeFilter },
                        set: { manager.setTypeFilter($0) }
                    )) {
                        Text(SentenceLibraryTypeFilter.all.localized(with: lang)).tag(SentenceLibraryTypeFilter.all)
                        Text(SentenceLibraryTypeFilter.bookmarkedOnly.localized(with: lang)).tag(SentenceLibraryTypeFilter.bookmarkedOnly)
                        Text(SentenceLibraryTypeFilter.withVocabularyOnly.localized(with: lang)).tag(SentenceLibraryTypeFilter.withVocabularyOnly)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    .help(lang.text("快速按类型过滤句子", "Quickly filter sentences by type"))

                    Spacer(minLength: 8)

                    // 来源筛选器 (Source Picker)
                    Menu {
                        Button {
                            selectedSource = ""
                        } label: {
                            HStack {
                                Text(lang.text("全部来源", "All Sources"))
                                if selectedSource.isEmpty {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        Divider()
                        ForEach(manager.availableSources, id: \.self) { source in
                            Button {
                                selectedSource = source
                            } label: {
                                HStack {
                                    Text(source)
                                    if selectedSource == source {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "film")
                            Text(selectedSource.isEmpty ? lang.text("来源", "Source") : selectedSource)
                                .lineLimit(1)
                        }
                        .font(.callout)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: 130)
                    .help(lang.text("按视频/音频原片来源过滤", "Filter by media source"))

                    // 日期筛选器 (Date Picker)
                    Menu {
                        Button(lang.text("全部日期", "All Dates")) { dateFilter = .all }
                        Button(lang.text("今天", "Today")) { dateFilter = .today }
                        Button(lang.text("近 7 天", "Last 7 Days")) { dateFilter = .lastSevenDays }
                        Button(lang.text("近 30 天", "Last 30 Days")) { dateFilter = .lastThirtyDays }
                        Divider()
                        Button(lang.text("指定日期…", "Specific Date…")) { dateFilter = .specificDay }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar")
                            Text(dateFilterTitle)
                                .lineLimit(1)
                        }
                        .font(.callout)
                    }
                    .menuStyle(.borderlessButton)
                    .help(lang.text("按入库日期过滤", "Filter by date added"))

                    if dateFilter == .specificDay {
                        DatePicker("", selection: $selectedDate, displayedComponents: .date)
                            .labelsHidden()
                            .frame(width: 105)
                    }

                    // 排序方式 (Sort Order)
                    Menu {
                        ForEach(SentenceLibrarySortOrder.allCases) { order in
                            Button {
                                manager.setSortOrder(order)
                            } label: {
                                HStack {
                                    Text(order.localized(with: lang))
                                    if manager.sortOrder == order {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down")
                            Text(manager.sortOrder.localized(with: lang))
                        }
                        .font(.callout)
                    }
                    .menuStyle(.borderlessButton)
                    .help(lang.text("调整句子排序规则", "Change sentence sorting order"))

                    // 更多功能菜单 (More Options Menu)
                    Menu {
                        Section(lang.text("学习包", "Learning Package")) {
                            Button {
                                chooseLearningPackageImport()
                            } label: {
                                Label(lang.text("导入学习包… (.mabstudy)", "Import Package… (.mabstudy)"), systemImage: "archivebox")
                            }
                            .disabled(manager.isWorking)

                            Button {
                                chooseLearningPackageExport()
                            } label: {
                                Label(lang.text("导出当前筛选为学习包…", "Export Current Filter as Package…"), systemImage: "square.and.arrow.up")
                            }
                            .disabled(manager.isWorking || manager.entries.isEmpty)
                        }

                        if !manager.entries.isEmpty {
                            Section(lang.text("选择操作", "Selection")) {
                                Button {
                                    selectAllVisibleEntries()
                                } label: {
                                    Label(lang.text("全选所有可见句子", "Select All Visible"), systemImage: "checkmark.circle")
                                }

                                Button {
                                    invertVisibleEntrySelection()
                                } label: {
                                    Label(lang.text("反选当前选区", "Invert Selection"), systemImage: "arrow.triangle.2.circlepath")
                                }

                                if selectedVisibleCount > 0 {
                                    Button {
                                        selectedEntryIDs.removeAll()
                                    } label: {
                                        Label(lang.text("取消所有勾选", "Deselect All"), systemImage: "xmark.circle")
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 14))
                    }
                    .menuStyle(.borderlessButton)
                    .help(lang.text("更多操作（导入/导出/选择）", "More actions (import/export/selection)"))

                    // 操作全局进度指示器
                    if let progress = manager.operationProgress {
                        ProgressView(value: progress.fraction)
                            .frame(width: 90)
                        Text(progress.phase)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))

                // 横向标签过滤栏 (Tags Bar)
                if !manager.availableTags.isEmpty {
                    Divider()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            TagCapsule(
                                title: lang.text("全部标签", "All Tags"),
                                isSelected: manager.selectedTag == nil,
                                action: { manager.setSelectedTag(nil) }
                            )
                            ForEach(manager.availableTags, id: \.self) { tag in
                                TagCapsule(
                                    title: tag.hasPrefix("#") ? tag : "#\(tag)",
                                    isSelected: manager.selectedTag == tag,
                                    action: {
                                        manager.setSelectedTag(manager.selectedTag == tag ? nil : tag)
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                    }
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                }

                // MARK: - 多选专属批量操作条 (Batch Action Bar)
                if selectedVisibleCount > 0 {
                    Divider()
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                            Text(lang.text("已选择 \(selectedVisibleCount) 句", "\(selectedVisibleCount) Selected"))
                                .font(.callout.weight(.semibold))
                        }
                        .padding(.trailing, 4)

                        Button {
                            selectAllVisibleEntries()
                        } label: {
                            Text(lang.text("全选", "All"))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(selectedVisibleCount == manager.entries.count)

                        Button {
                            invertVisibleEntrySelection()
                        } label: {
                            Text(lang.text("反选", "Invert"))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            selectedEntryIDs.removeAll()
                        } label: {
                            Text(lang.text("取消选择", "Clear"))
                        }
                        .buttonStyle(.plain)
                        .controlSize(.small)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                        Spacer(minLength: 8)

                        // 批量打标签
                        Button {
                            showBatchTagPopover = true
                        } label: {
                            Label(lang.text("标签", "Tags"), systemImage: "tag")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(manager.isWorking)
                        .popover(isPresented: $showBatchTagPopover) {
                            BatchTagEditorPopover(
                                selectedCount: selectedVisibleCount,
                                availableTags: manager.availableTags,
                                onAddTags: { tagsToAdd in
                                    let selectedIDs = selectedEntryIDs.intersection(visibleIDs)
                                    Task {
                                        try? await manager.batchAddTags(to: selectedIDs, tags: tagsToAdd)
                                    }
                                },
                                onSetTags: { tagsToSet in
                                    let selectedIDs = selectedEntryIDs.intersection(visibleIDs)
                                    Task {
                                        try? await manager.batchSetTags(for: selectedIDs, tags: tagsToSet)
                                    }
                                },
                                onDismiss: {
                                    showBatchTagPopover = false
                                }
                            )
                        }

                        // 批量改来源
                        Button {
                            showBatchSourcePopover = true
                        } label: {
                            Label(lang.text("来源", "Source"), systemImage: "film")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(manager.isWorking)
                        .popover(isPresented: $showBatchSourcePopover) {
                            SentenceBatchSourceEditorPopover(
                                selectedCount: selectedVisibleCount,
                                availableSources: manager.availableSources,
                                isPresented: $showBatchSourcePopover,
                                onSave: { newSource in
                                    let selectedIDs = selectedEntryIDs.intersection(visibleIDs)
                                    Task {
                                        try? await manager.batchUpdateSourceMediaName(
                                            for: selectedIDs,
                                            newSourceName: newSource
                                        )
                                    }
                                }
                            )
                        }

                        // 批量对齐时间戳 (仅缺失时出现)
                        if !missingSelectedEntries.isEmpty {
                            Button {
                                if let libraryID = manager.currentLibraryID {
                                    SentenceLibraryAlignmentService.shared.alignWordTokensForEntries(
                                        entries: missingSelectedEntries,
                                        libraryID: libraryID
                                    )
                                }
                            } label: {
                                Label(
                                    lang.text("对齐时间戳 (\(missingSelectedEntries.count))", "Align (\(missingSelectedEntries.count))"),
                                    systemImage: "waveform.badge.magnifyingglass"
                                )
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(manager.isWorking || SentenceLibraryAlignmentService.shared.isAligning)
                            .help(lang.text("使用 Whisper 为选中的句子批量补齐词级时间戳", "Batch align word timestamps using Whisper"))
                        }

                        // 批量导出音频与歌词
                        Menu {
                            Button {
                                chooseIndividualLibraryExportDestination()
                            } label: {
                                Label(lang.text("逐句导出 M4A＋LRC…", "Export Separate M4A + LRC…"), systemImage: "rectangle.split.3x1")
                            }
                            Button {
                                chooseMergedLibraryExportDestination()
                            } label: {
                                Label(lang.text("合并导出 M4A＋LRC…", "Export Merged M4A + LRC…"), systemImage: "arrow.triangle.merge")
                            }
                        } label: {
                            Label(lang.text("导出音频", "Export Audio"), systemImage: "square.and.arrow.up")
                        }
                        .menuStyle(.borderedButton)
                        .controlSize(.small)
                        .disabled(manager.isWorking)

                        // 批量移动到其他句库
                        if manager.libraries.count > 1 {
                            Menu {
                                ForEach(manager.libraries.filter { $0.id != manager.currentLibraryID }) { library in
                                    Button {
                                        pendingMoveDestinationID = library.id
                                        confirmMove = true
                                    } label: {
                                        Label(library.name, systemImage: "books.vertical")
                                    }
                                }
                            } label: {
                                Label(lang.text("移动到", "Move To"), systemImage: "arrow.right.doc.on.clipboard")
                            }
                            .menuStyle(.borderedButton)
                            .controlSize(.small)
                            .disabled(manager.isWorking)
                        }

                        // 批量删除
                        Button(role: .destructive) {
                            deleteSelectedEntries()
                        } label: {
                            Label(lang.text("删除", "Delete"), systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                        .disabled(manager.isWorking)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.08))
                }

                Divider()

                // MARK: - 句子列表区 (Sentence List)
                if manager.entries.isEmpty {
                    ContentUnavailableView(
                        lang.text("句库中没有匹配的句子", "No Matching Sentences"),
                        systemImage: "text.book.closed",
                        description: Text(lang.text("从视频断句列表勾选句子后加入当前句库，即可在此复习与试听。", "Select sentences in segment list and add them to this library."))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let sourceCounts = Dictionary(grouping: manager.entries, by: \.sourceMediaName).mapValues(\.count)
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(Array(manager.entries.enumerated()), id: \.element.id) { offset, entry in
                                SentenceLibraryEntryRow(
                                    entry: entry,
                                    number: offset + 1,
                                    previewURL: manager.previewURL(for: entry),
                                    isActive: selectedEntryID == entry.id,
                                    isChecked: selectedEntryIDs.contains(entry.id),
                                    isCurrentlyPlaying: libraryPlayer.isPlaying && libraryPlayer.currentEntry?.id == entry.id,
                                    availableTags: manager.availableTags,
                                    availableSources: manager.availableSources,
                                    matchingSourceCount: entry.sourceMediaName.isEmpty ? 0 : (sourceCounts[entry.sourceMediaName] ?? 0),
                                    onToggleCheck: { toggleSelection(entry.id) },
                                    onToggleBookmark: {
                                        Task {
                                            try? await manager.toggleBookmark(id: entry.id)
                                        }
                                    },
                                    onSelect: {
                                        selectedEntryID = entry.id
                                    },
                                    onTogglePlay: {
                                        selectedEntryID = entry.id
                                        libraryPlayer.togglePlayback(for: entry, mediaURL: manager.mediaURL(for: entry))
                                    },
                                    onPreview: {
                                        if let previewURL = manager.previewURL(for: entry) {
                                            selectedEntryID = entry.id
                                            previewRequest = SentencePreviewRequest(url: previewURL, title: entry.originalText)
                                        }
                                    },
                                    onUpdateTags: { tags in
                                        try? await manager.updateTags(id: entry.id, tags: tags)
                                    },
                                    onUpdateSource: { newSource, applyToAll in
                                        try? await manager.updateSourceMediaName(
                                            entryID: entry.id,
                                            oldSourceName: entry.sourceMediaName,
                                            newSourceName: newSource,
                                            applyToAllWithSameSource: applyToAll
                                        )
                                    },
                                    onDelete: {
                                        Task {
                                            try? await manager.deleteEntries(ids: [entry.id])
                                        }
                                    },
                                    onAlignTokens: {
                                        if let libraryID = manager.currentLibraryID {
                                            SentenceLibraryAlignmentService.shared.alignWordTokensForEntries(
                                                entries: [entry],
                                                libraryID: libraryID
                                            )
                                        }
                                    },
                                    onSave: { originalText, translationText in
                                        do {
                                            try await manager.updateEntry(
                                                id: entry.id,
                                                originalText: originalText,
                                                translation: translationText
                                            )
                                            return true
                                        } catch {
                                            return false
                                        }
                                    }
                                )
                            }
                        }
                        .padding(12)
                    }
                }

                // MARK: - 底部常驻全局试听播放控制台 (Bottom Playback Bar)
                Divider()
                SentenceLibraryPlaybackBar(
                    player: libraryPlayer,
                    selectedEntry: selectedEntry,
                    selectedMediaURL: selectedEntry.flatMap(manager.mediaURL(for:)),
                    currentPosition: selectedEntryPosition,
                    totalCount: manager.entries.count,
                    onModeChanged: { mode in
                        libraryPlayer.setPlaybackMode(mode)
                    }
                )
            }
            .navigationTitle(manager.currentLibrary?.name ?? lang.text("句库", "Sentence Library"))
            .searchable(
                text: $searchText,
                placement: .toolbar,
                prompt: Text(lang.text("搜索原文或译文…", "Search original or translation…"))
            )
            .overlay(alignment: .bottom) {
                WindowFloatingStatusToast(bottomPadding: 68)
            }
        }
        .frame(minWidth: 840, minHeight: 580)
        .onAppear {
            manager.updateFilter(
                searchText: searchText,
                dateFilter: dateFilter,
                selectedDate: selectedDate,
                sourceMediaName: selectedSource,
                sortOrder: sortOrder
            )
            refreshPlayerPlaylist()
        }
        .onDisappear {
            libraryPlayer.stop()
        }
        .onChange(of: searchText) { _, value in
            manager.updateFilter(
                searchText: value,
                dateFilter: dateFilter,
                selectedDate: selectedDate,
                sourceMediaName: selectedSource,
                sortOrder: sortOrder
            )
            selectedEntryIDs.formIntersection(manager.entries.map(\.id))
        }
        .onChange(of: dateFilter) { _, value in
            manager.updateFilter(
                searchText: searchText,
                dateFilter: value,
                selectedDate: selectedDate,
                sourceMediaName: selectedSource,
                sortOrder: sortOrder
            )
            selectedEntryIDs.formIntersection(manager.entries.map(\.id))
        }
        .onChange(of: selectedDate) { _, value in
            guard dateFilter == .specificDay else { return }
            manager.updateFilter(
                searchText: searchText,
                dateFilter: dateFilter,
                selectedDate: value,
                sourceMediaName: selectedSource,
                sortOrder: sortOrder
            )
        }
        .onChange(of: selectedSource) { _, value in
            manager.updateFilter(
                searchText: searchText,
                dateFilter: dateFilter,
                selectedDate: selectedDate,
                sourceMediaName: value,
                sortOrder: sortOrder
            )
            selectedEntryIDs.formIntersection(manager.entries.map(\.id))
        }
        .onChange(of: sortOrder) { _, value in
            manager.updateFilter(
                searchText: searchText,
                dateFilter: dateFilter,
                selectedDate: selectedDate,
                sourceMediaName: selectedSource,
                sortOrder: value
            )
        }
        .onChange(of: manager.currentLibraryID) { _, _ in
            selectedEntryIDs.removeAll()
            selectedEntryID = nil
            selectedSource = ""
            sortOrder = .newestFirst
            libraryPlayer.stop()
            refreshPlayerPlaylist()
        }
        .onChange(of: manager.entries.map(\.id)) { _, currentIDs in
            refreshPlayerPlaylist()
            selectedEntryIDs.formIntersection(currentIDs)
            if let selectedEntryID, !currentIDs.contains(selectedEntryID) {
                self.selectedEntryID = nil
                libraryPlayer.stop()
            }
        }
        .onChange(of: libraryPlayer.currentEntry?.id) { _, id in
            if let id, manager.entries.contains(where: { $0.id == id }) {
                selectedEntryID = id
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            SentenceLibraryCreationSheet { name in
                Task {
                    do {
                        try await manager.createLibrary(name: name)
                    } catch {
                        notice = SentenceLibraryNotice(title: lang.text("无法新建句库", "Unable to Create Library"), message: error.localizedDescription)
                    }
                }
            }
        }
        .sheet(isPresented: $showRenameSheet) {
            if let target = libraryToRename {
                SentenceLibraryRenameSheet(initialName: target.name) { newName in
                    Task {
                        do {
                            try await manager.renameLibrary(id: target.id, newName: newName)
                        } catch {
                            notice = SentenceLibraryNotice(title: lang.text("重命名失败", "Rename Failed"), message: error.localizedDescription)
                        }
                    }
                }
            }
        }
        .sheet(item: $previewRequest) { request in
            SentenceImagePreview(request: request)
        }
        .confirmationDialog(
            lang.text("删除当前句库？", "Delete Current Library?"),
            isPresented: $confirmLibraryDeletion,
            titleVisibility: .visible
        ) {
            Button(lang.text("删除句库", "Delete Library"), role: .destructive) {
                Task {
                    do {
                        try await manager.deleteCurrentLibrary()
                    } catch {
                        notice = SentenceLibraryNotice(title: lang.text("删除失败", "Delete Failed"), message: error.localizedDescription)
                    }
                }
            }
        } message: {
            Text(lang.text("句库中的句子和预览图片都会被删除。", "All sentences and preview images in this library will be deleted."))
        }
        .confirmationDialog(
            lang.text("移动选中的句子？", "Move Selected Sentences?"),
            isPresented: $confirmMove,
            titleVisibility: .visible
        ) {
            if let pendingMoveDestinationID,
               let destination = manager.libraries.first(where: { $0.id == pendingMoveDestinationID }) {
                Button(lang.text("移动到 \(destination.name)", "Move to \(destination.name)")) {
                    moveSelectedEntries(to: destination.id)
                }
            }
            Button(lang.text("取消", "Cancel"), role: .cancel) {
                pendingMoveDestinationID = nil
            }
        } message: {
            if let destination = pendingMoveDestinationID.flatMap({ id in manager.libraries.first(where: { $0.id == id }) }) {
                Text(lang.text("句子、原文、译文、音频和缩略图会移动到“\(destination.name)”，并从当前句库移除。", "The sentences, text, audio and previews will move to \(destination.name) and be removed from the current library."))
            }
        }
        .alert(item: $notice) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text(lang.text("好", "OK"))))
        }
    }

    private var dateFilterTitle: String {
        switch dateFilter {
        case .all: return lang.text("全部日期", "All Dates")
        case .today: return lang.text("今天", "Today")
        case .lastSevenDays: return lang.text("近 7 天", "Last 7 Days")
        case .lastThirtyDays: return lang.text("近 30 天", "Last 30 Days")
        case .specificDay: return lang.text("指定日期", "Specific")
        }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedEntryIDs.contains(id) { selectedEntryIDs.remove(id) }
        else { selectedEntryIDs.insert(id) }
    }

    private func selectAllVisibleEntries() {
        selectedEntryIDs.formUnion(manager.entries.map(\.id))
    }

    private func invertVisibleEntrySelection() {
        selectedEntryIDs = selectedEntryIDs.symmetricDifference(Set(manager.entries.map(\.id)))
    }

    private func deleteSelectedEntries() {
        let ids = selectedEntryIDs.intersection(Set(manager.entries.map(\.id)))
        guard !ids.isEmpty else { return }
        let removesActiveEntry = selectedEntryID.map(ids.contains) ?? false
        Task {
            do {
                try await manager.deleteEntries(ids: ids)
                selectedEntryIDs.removeAll()
                if removesActiveEntry {
                    selectedEntryID = nil
                    libraryPlayer.stop()
                }
            } catch {
                notice = SentenceLibraryNotice(title: lang.text("删除失败", "Delete Failed"), message: error.localizedDescription)
            }
        }
    }

    private func moveSelectedEntries(to destinationID: UUID) {
        let ids = selectedEntryIDs.intersection(Set(manager.entries.map(\.id)))
        guard !ids.isEmpty else { return }
        Task {
            do {
                try await manager.moveEntries(ids: ids, to: destinationID)
                selectedEntryIDs.removeAll()
                pendingMoveDestinationID = nil
            } catch {
                notice = SentenceLibraryNotice(title: lang.text("移动失败", "Move Failed"), message: error.localizedDescription)
            }
        }
    }

    private func refreshPlayerPlaylist() {
        let mediaURLs = Dictionary(uniqueKeysWithValues: manager.entries.compactMap { entry in
            manager.mediaURL(for: entry).map { (entry.id, $0) }
        })
        libraryPlayer.setPlaylist(entries: manager.entries, mediaURLs: mediaURLs)
    }

    private func chooseIndividualLibraryExportDestination() {
        let entries = selectedVisibleEntries
        guard !entries.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = lang.text("选择", "Choose")
        panel.message = lang.text("选择逐句 M4A、LRC 和 SRT 的保存位置", "Choose where to save separate M4A, LRC, and SRT files")
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        performLibraryExport(entries: entries, merged: false, destinationURL: directory)
    }

    private func chooseMergedLibraryExportDestination() {
        let entries = selectedVisibleEntries
        guard !entries.isEmpty else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "m4a") ?? .audio]
        panel.nameFieldStringValue = (manager.currentLibrary?.name ?? "句库") + "-已选句子.m4a"
        panel.message = lang.text("将生成一个 AAC 编码的 M4A 以及同名 LRC 与 SRT 字幕", "One AAC-encoded M4A and matching LRC and SRT subtitles will be created")
        guard panel.runModal() == .OK, let audioURL = panel.url else { return }
        performLibraryExport(entries: entries, merged: true, destinationURL: audioURL)
    }

    private func performLibraryExport(
        entries: [SentenceLibraryEntry],
        merged: Bool,
        destinationURL: URL
    ) {
        Task {
            do {
                let result = try await manager.exportEntries(
                    entries,
                    merged: merged,
                    destinationURL: destinationURL
                )
                notice = SentenceLibraryNotice(
                    title: lang.text("导出完成", "Export Complete"),
                    message: result.location.path
                )
            } catch {
                notice = SentenceLibraryNotice(title: lang.text("导出失败", "Export Failed"), message: error.localizedDescription)
            }
        }
    }

    private func chooseLearningPackageImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [learningPackageType]
        panel.prompt = lang.text("导入", "Import")
        panel.message = lang.text("选择来自 iPhone 或 iPad 的 .mabstudy 学习包", "Choose a .mabstudy package from iPhone or iPad")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                _ = try await manager.importLearningPackage(from: url)
            } catch {
                notice = SentenceLibraryNotice(title: lang.text("导入失败", "Import Failed"), message: error.localizedDescription)
            }
        }
    }

    private func chooseLearningPackageExport() {
        guard !manager.entries.isEmpty else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [learningPackageType]
        panel.nameFieldStringValue = (manager.currentLibrary?.name ?? "句库") + ".mabstudy"
        panel.message = lang.text("导出当前筛选结果及独立句子音频", "Export the current filtered entries and independent sentence audio")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await manager.exportLearningPackage(manager.entries, destinationURL: url)
                notice = SentenceLibraryNotice(title: lang.text("学习包已导出", "Package Exported"), message: url.path)
            } catch {
                notice = SentenceLibraryNotice(title: lang.text("导出失败", "Export Failed"), message: error.localizedDescription)
            }
        }
    }

    private func enterStudyMode() {
        guard !isPreparingStudy else { return }
        guard let libraryID = manager.currentLibraryID else { return }
        let entriesToStudy = selectedVisibleEntries.isEmpty ? manager.entries : selectedVisibleEntries
        guard !entriesToStudy.isEmpty else { return }

        // 如果当前是视频播放模式，进入句库学习时切换到列表模式以启用 5 大学习模式
        if playbackInterfaceMode == .video {
            playbackInterfaceMode = .list
        }

        let alreadyGenerated = PlaybackEngine.shared.hasGeneratedSentenceLibraryMaterial(
            libraryID: libraryID,
            entries: entriesToStudy,
            descriptor: manager.currentLibrary
        )

        if !alreadyGenerated {
            isPreparingStudy = true
            MainStatusCenter.shared.showInfo(
                lang.text("正在准备学习材料…", "Preparing study materials…")
            )
        }

        Task { @MainActor in
            defer {
                isPreparingStudy = false
            }
            do {
                try await PlaybackEngine.shared.loadSentenceLibrary(
                    libraryID: libraryID,
                    entries: entriesToStudy,
                    descriptor: manager.currentLibrary
                )
                if let mainWindow = NSApp.windows.first(where: {
                    $0.identifier == NSUserInterfaceItemIdentifier("studymate-main-window")
                }) {
                    mainWindow.makeKeyAndOrderFront(nil)
                } else {
                    openWindow(id: "main")
                }
                dismissWindow(id: "welcome")
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if let mainWindow = NSApp.windows.first(where: {
                        $0.identifier == NSUserInterfaceItemIdentifier("studymate-main-window")
                    }) {
                        mainWindow.makeKeyAndOrderFront(nil)
                    }
                }
                MainStatusCenter.shared.showSuccess(
                    lang.text("已载入 \(entriesToStudy.count) 句进入学习模式", "Loaded \(entriesToStudy.count) sentences for study")
                )
            } catch {
                notice = SentenceLibraryNotice(
                    title: lang.text("进入学习失败", "Failed to Enter Study"),
                    message: error.localizedDescription
                )
            }
        }
    }
}

// MARK: - 辅助子视图组件

private struct TagCapsule: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct SentenceTagEditorPopover: View {
    @ObservedObject private var lang = LanguageManager.shared
    let initialTags: [String]
    let availableTags: [String]
    let onSave: ([String]) -> Void

    @State private var tags: [String]
    @State private var newTagText: String = ""

    init(currentTags: [String], availableTags: [String], onSave: @escaping ([String]) -> Void) {
        self.initialTags = currentTags
        self.availableTags = availableTags
        self.onSave = onSave
        self._tags = State(initialValue: currentTags)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(lang.text("管理标签", "Manage Tags"), systemImage: "tag")
                    .font(.headline)
                Spacer()
                if !tags.isEmpty {
                    Text(lang.text("共 \(tags.count) 个标签", "\(tags.count) tags"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(lang.text("当前标签：", "Current Tags:"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                if tags.isEmpty {
                    Text(lang.text("暂未添加任何标签", "No tags added yet"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 2)
                } else {
                    FillInBlankFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Text(tag.hasPrefix("#") ? tag : "#\(tag)")
                                    .font(.caption)
                                Button {
                                    removeTag(tag)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.leading, 8)
                            .padding(.trailing, 6)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField(lang.text("输入标签名称（回车添加）", "Tag name (press Enter)"), text: $newTagText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        addNewTag()
                    }

                Button {
                    addNewTag()
                } label: {
                    Image(systemName: "plus")
                    Text(lang.text("添加", "Add"))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(newTagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            let otherTags = availableTags.filter { !tags.contains($0) }
            if !availableTags.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(lang.text("句库已有标签（点击快速添加）：", "Library Tags (Click to add):"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    if otherTags.isEmpty {
                        Text(lang.text("所有已有标签已全部添加", "All library tags already added"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        FillInBlankFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                            ForEach(otherTags, id: \.self) { tag in
                                Button {
                                    addExistingTag(tag)
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "plus")
                                            .font(.system(size: 9))
                                        Text(tag.hasPrefix("#") ? tag : "#\(tag)")
                                            .font(.caption)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.secondary.opacity(0.1))
                                    .foregroundStyle(.primary)
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(minWidth: 300, idealWidth: 320, maxWidth: 360)
    }

    private func addNewTag() {
        let trimmed = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !trimmed.isEmpty else { return }
        if !tags.contains(trimmed) {
            tags.append(trimmed)
            onSave(tags)
        }
        newTagText = ""
    }

    private func addExistingTag(_ tag: String) {
        if !tags.contains(tag) {
            tags.append(tag)
            onSave(tags)
        }
    }

    private func removeTag(_ tag: String) {
        tags.removeAll { $0 == tag }
        onSave(tags)
    }
}

private struct BatchTagEditorPopover: View {
    @ObservedObject private var lang = LanguageManager.shared
    let selectedCount: Int
    let availableTags: [String]
    let onAddTags: ([String]) -> Void
    let onSetTags: ([String]) -> Void
    let onDismiss: () -> Void

    @State private var pendingTags: [String] = []
    @State private var newTagText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(lang.text("批量标签设置", "Batch Tagging"), systemImage: "tag")
                    .font(.headline)
                Spacer()
                Text(lang.text("已选 \(selectedCount) 句", "\(selectedCount) selected"))
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(lang.text("要应用的标签：", "Tags to apply:"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                if pendingTags.isEmpty {
                    Text(lang.text("在下方输入或点击已有标签以选择", "Enter below or click existing tags to select"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 2)
                } else {
                    FillInBlankFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        ForEach(pendingTags, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Text(tag.hasPrefix("#") ? tag : "#\(tag)")
                                    .font(.caption)
                                Button {
                                    pendingTags.removeAll { $0 == tag }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.leading, 8)
                            .padding(.trailing, 6)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField(lang.text("新标签名称（回车添加）", "Tag name (press Enter)"), text: $newTagText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        addPendingTag()
                    }

                Button {
                    addPendingTag()
                } label: {
                    Image(systemName: "plus")
                    Text(lang.text("添加", "Add"))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(newTagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !availableTags.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(lang.text("从句库已有标签选择：", "Select from library tags:"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    FillInBlankFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        ForEach(availableTags, id: \.self) { tag in
                            let isIncluded = pendingTags.contains(tag)
                            Button {
                                if isIncluded {
                                    pendingTags.removeAll { $0 == tag }
                                } else {
                                    pendingTags.append(tag)
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: isIncluded ? "checkmark" : "plus")
                                        .font(.system(size: 9))
                                    Text(tag.hasPrefix("#") ? tag : "#\(tag)")
                                        .font(.caption)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(isIncluded ? Color.accentColor : Color.secondary.opacity(0.1))
                                .foregroundStyle(isIncluded ? Color.white : Color.primary)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    onAddTags(pendingTags)
                    onDismiss()
                } label: {
                    Text(lang.text("追加标签", "Append Tags"))
                }
                .buttonStyle(.borderedProminent)
                .disabled(pendingTags.isEmpty)
                .help(lang.text("为选中的句子保留原有标签，并追加选定标签", "Keep existing tags on selected sentences and append chosen tags"))

                Button {
                    onSetTags(pendingTags)
                    onDismiss()
                } label: {
                    Text(lang.text("覆盖标签", "Replace Tags"))
                }
                .buttonStyle(.bordered)
                .help(lang.text("将选中句子的标签全部替换为选定标签", "Replace all tags on selected sentences with chosen tags"))

                Spacer()

                Button(lang.text("取消", "Cancel")) {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(minWidth: 320, idealWidth: 350, maxWidth: 400)
    }

    private func addPendingTag() {
        let trimmed = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !trimmed.isEmpty else { return }
        if !pendingTags.contains(trimmed) {
            pendingTags.append(trimmed)
        }
        newTagText = ""
    }
}

/// 单句来源编辑弹窗（支持直接输入、已有来源快速选择、以及勾选同步应用到来自该来源的所有句子）
private struct SentenceSourceEditorPopover: View {
    @ObservedObject private var lang = LanguageManager.shared
    let initialSource: String
    let availableSources: [String]
    let matchingSentenceCount: Int?
    @Binding var isPresented: Bool
    let onSave: (String, Bool) -> Void

    @State private var sourceText: String
    @State private var applyToAllMatching: Bool

    init(
        initialSource: String,
        availableSources: [String],
        matchingSentenceCount: Int? = nil,
        isPresented: Binding<Bool>,
        onSave: @escaping (String, Bool) -> Void
    ) {
        self.initialSource = initialSource
        self.availableSources = availableSources
        self.matchingSentenceCount = matchingSentenceCount
        self._isPresented = isPresented
        self.onSave = onSave
        self._sourceText = State(initialValue: initialSource)
        self._applyToAllMatching = State(initialValue: !initialSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(lang.text("修改句子来源", "Edit Sentence Source"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                TextField(
                    lang.text("输入来源名称（如：老友记 S01E01）", "Enter source name (e.g. Friends S01E01)"),
                    text: $sourceText
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)

                let otherSources = availableSources.filter { $0 != initialSource && !$0.isEmpty }
                if !otherSources.isEmpty {
                    Menu {
                        ForEach(otherSources, id: \.self) { source in
                            Button(source) {
                                sourceText = source
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(lang.text("从已有来源中选择…", "Choose from existing sources…"))
                                .font(.caption)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .foregroundStyle(Color.accentColor)
                    }
                    .menuStyle(.borderlessButton)
                }
            }

            if !initialSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Toggle(isOn: $applyToAllMatching) {
                    if let count = matchingSentenceCount, count > 1 {
                        Text(lang.text("同时应用到来自该来源的所有句子（共 \(count) 句）", "Apply to all sentences from this source (\(count) sentences)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(lang.text("同时应用到来自该来源的所有句子", "Apply to all sentences from this source"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }

            HStack {
                Button(lang.text("取消", "Cancel")) {
                    isPresented = false
                }
                Spacer()
                Button(lang.text("保存", "Save")) {
                    isPresented = false
                    let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(trimmed, applyToAllMatching)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 290)
    }
}

/// 批量修改句子来源弹窗
private struct SentenceBatchSourceEditorPopover: View {
    @ObservedObject private var lang = LanguageManager.shared
    let selectedCount: Int
    let availableSources: [String]
    @Binding var isPresented: Bool
    let onSave: (String) -> Void

    @State private var sourceText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(lang.text("批量修改来源（已选 \(selectedCount) 句）", "Batch Edit Source (\(selectedCount) selected)"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                TextField(
                    lang.text("输入新来源名称", "Enter new source name"),
                    text: $sourceText
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)

                let validSources = availableSources.filter { !$0.isEmpty }
                if !validSources.isEmpty {
                    Menu {
                        ForEach(validSources, id: \.self) { source in
                            Button(source) {
                                sourceText = source
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(lang.text("从已有来源中选择…", "Choose from existing sources…"))
                                .font(.caption)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .foregroundStyle(Color.accentColor)
                    }
                    .menuStyle(.borderlessButton)
                }
            }

            HStack {
                Button(lang.text("取消", "Cancel")) {
                    isPresented = false
                }
                Spacer()
                Button(lang.text("保存", "Save")) {
                    isPresented = false
                    let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(trimmed)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 290)
    }
}

// MARK: - 单句列表卡片行 (Sentence Entry Row)

private struct SentenceLibraryEntryRow: View {
    @ObservedObject private var lang = LanguageManager.shared
    let entry: SentenceLibraryEntry
    let number: Int
    let previewURL: URL?
    let isActive: Bool
    let isChecked: Bool
    let isCurrentlyPlaying: Bool
    let availableTags: [String]
    let availableSources: [String]
    let matchingSourceCount: Int
    let onToggleCheck: () -> Void
    let onToggleBookmark: () -> Void
    let onSelect: () -> Void
    let onTogglePlay: () -> Void
    let onPreview: () -> Void
    let onUpdateTags: ([String]) async -> Void
    let onUpdateSource: (String, Bool) async -> Void
    let onDelete: () -> Void
    let onAlignTokens: (() -> Void)?
    let onSave: (String, String) async -> Bool

    @State private var isEditing = false
    @State private var editSessionID = UUID()
    @State private var showContextPopover = false
    @State private var showTagPopover = false
    @State private var showSourcePopover = false
    @State private var isHoveringSource = false
    @State private var isHoveringRow = false
    @State private var lastClickTime: Date?

    private func handleTap() {
        guard !isEditing else { return }
        let now = Date()
        let interval = NSEvent.doubleClickInterval
        if let last = lastClickTime, now.timeIntervalSince(last) < interval {
            lastClickTime = nil
            onTogglePlay()
        } else {
            lastClickTime = now
            onSelect()
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // 左侧控制列：勾选框 + 星标 + 播放/暂停快捷按钮
            VStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { isChecked }, set: { _ in onToggleCheck() }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()

                Button(action: onToggleBookmark) {
                    Image(systemName: entry.isBookmarked ? "star.fill" : "star")
                        .foregroundStyle(entry.isBookmarked ? Color.yellow : Color.secondary.opacity(0.35))
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help(entry.isBookmarked ? lang.text("取消星标难句", "Unstar") : lang.text("加入星标难句", "Star"))

                Button(action: onTogglePlay) {
                    Image(systemName: isCurrentlyPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(isCurrentlyPlaying ? Color.accentColor : (isHoveringRow || isActive ? Color.primary : Color.secondary.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .help(isCurrentlyPlaying ? lang.text("暂停试听", "Pause") : lang.text("试听此句", "Play this sentence"))
            }
            .frame(width: 22)

            // 序号
            Text("#\(number)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
                .padding(.top, 2)

            // 媒体预览缩略图
            Button(action: onPreview) {
                SentenceLibraryThumbnail(previewURL: previewURL)
                    .frame(width: 124, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .bottomTrailing) {
                        if previewURL != nil {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 9, weight: .bold))
                                .padding(4)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                                .padding(4)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(previewURL == nil)
            .help(previewURL == nil ? "" : lang.text("点击放大预览", "Click to enlarge preview"))

            // 中部文本内容与编辑模式
            if isEditing {
                SentenceLibraryInlineSubtitleEditor(
                    originalText: entry.originalText,
                    translationText: entry.translation,
                    onSave: onSave,
                    onFinish: { isEditing = false },
                    onCancel: { isEditing = false }
                )
                .id(editSessionID)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    // 顶部标签胶囊与角色
                    HStack(spacing: 6) {
                        if !entry.effectiveSpeakerLabel.isEmpty {
                            Text(entry.effectiveSpeakerLabel)
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Color.accentColor.opacity(0.12))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                        if let words = entry.associatedWords, !words.isEmpty {
                            Label("\(words.count)", systemImage: "text.book.closed")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.purple.opacity(0.12))
                                .foregroundStyle(Color.purple)
                                .clipShape(Capsule())
                                .help(words.map(\.word).joined(separator: ", "))
                        }
                        ForEach(entry.tags, id: \.self) { tag in
                            Button {
                                showTagPopover = true
                            } label: {
                                Text(tag.hasPrefix("#") ? tag : "#\(tag)")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(Color.secondary.opacity(0.12))
                                    .foregroundStyle(.secondary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(lang.text("点击管理标签", "Click to manage tags"))
                        }
                    }

                    // 原文
                    if !entry.originalText.isEmpty {
                        Text(entry.originalText)
                            .font(.system(.body, design: .default).weight(.medium))
                            .lineSpacing(3)
                    }

                    // 译文
                    if !entry.translation.isEmpty {
                        Text(entry.translation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    // 底部原片来源坐标与起止时间
                    HStack(spacing: 8) {
                        // 来源胶囊
                        HStack(spacing: 4) {
                            Text(lang.text("来源：", "Source: "))
                                .foregroundStyle(.secondary)

                            Button {
                                showSourcePopover = true
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "film")
                                        .font(.caption2)
                                    Text(entry.sourceMediaName.isEmpty ? lang.text("设置来源", "Set Source") : entry.sourceMediaName)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(isHoveringSource ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12))
                                .foregroundStyle(isHoveringSource ? Color.accentColor : Color.secondary)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .onHover { isHoveringSource = $0 }
                            .help(lang.text("点击修改来源（支持同步更新同来源句子）", "Click to edit source (supports batch updating)"))
                            .popover(isPresented: $showSourcePopover, arrowEdge: .bottom) {
                                SentenceSourceEditorPopover(
                                    initialSource: entry.sourceMediaName,
                                    availableSources: availableSources,
                                    matchingSentenceCount: matchingSourceCount,
                                    isPresented: $showSourcePopover,
                                    onSave: { newSource, applyToAll in
                                        Task {
                                            await onUpdateSource(newSource, applyToAll)
                                        }
                                    }
                                )
                            }

                            if entry.originalIndex > 0 {
                                Text("·")
                                    .foregroundStyle(.tertiary)
                                Text("原#\(entry.originalIndex)")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // 起止时间戳与时长
                        let duration = max(0, entry.endTime - entry.startTime)
                        let durationText = String(format: "%.1fs", duration)
                        Text("\(SentenceSegment.formatCoordinateTime(entry.startTime)) – \(SentenceSegment.formatCoordinateTime(entry.endTime)) (\(durationText))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .help(lang.text("原片区间：\(SentenceSegment.formatTimecode(entry.startTime)) – \(SentenceSegment.formatTimecode(entry.endTime))（时长 \(durationText)）", "Time range: \(SentenceSegment.formatTimecode(entry.startTime)) – \(SentenceSegment.formatTimecode(entry.endTime)) (\(durationText))"))

                        // 语境快照
                        if entry.contextBefore != nil || entry.contextAfter != nil {
                            Button {
                                showContextPopover = true
                            } label: {
                                Label(lang.text("语境", "Context"), systemImage: "bubble.left.and.bubble.right")
                                    .font(.caption2)
                            }
                            .buttonStyle(.borderless)
                            .popover(isPresented: $showContextPopover) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(lang.text("原片语境快照", "Context Snapshot"))
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                    if let before = entry.contextBefore, !before.isEmpty {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(lang.text("前文：", "Before:"))
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                            Text(before)
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    if let after = entry.contextAfter, !after.isEmpty {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(lang.text("后文：", "After:"))
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                            Text(after)
                                                .font(.callout)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(12)
                                .frame(minWidth: 260, maxWidth: 360)
                            }
                        }

                        Spacer()

                        // 入库日期
                        Label(Self.dateFormatter.string(from: entry.createdAt), systemImage: "calendar")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            // 右侧快捷操作按钮
            if !isEditing {
                HStack(spacing: 4) {
                    Button {
                        showTagPopover = true
                    } label: {
                        Image(systemName: entry.tags.isEmpty ? "tag" : "tag.fill")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(entry.tags.isEmpty ? Color.secondary : Color.accentColor)
                    .help(lang.text("管理标签", "Manage tags"))
                    .popover(isPresented: $showTagPopover) {
                        SentenceTagEditorPopover(
                            currentTags: entry.tags,
                            availableTags: availableTags,
                            onSave: { updated in
                                Task {
                                    await onUpdateTags(updated)
                                }
                            }
                        )
                    }

                    Button {
                        editSessionID = UUID()
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                    .help(lang.text("修改原文和译文", "Edit original and translation"))

                    Menu {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.originalText, forType: .string)
                            MainStatusCenter.shared.showSuccess(lang.text("已复制原文", "Copied original text"))
                        } label: {
                            Label(lang.text("复制原文", "Copy Original Text"), systemImage: "doc.on.doc")
                        }

                        if !entry.translation.isEmpty {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.translation, forType: .string)
                                MainStatusCenter.shared.showSuccess(lang.text("已复制译文", "Copied translation"))
                            } label: {
                                Label(lang.text("复制译文", "Copy Translation"), systemImage: "doc.on.doc")
                            }
                        }

                        if entry.wordTokens == nil || entry.wordTokens?.isEmpty == true {
                            Divider()
                            Button {
                                onAlignTokens?()
                            } label: {
                                Label(
                                    lang.text("对齐词级时间戳 (Whisper)", "Align Word Timestamps (Whisper)"),
                                    systemImage: "waveform.badge.magnifyingglass"
                                )
                            }
                            .disabled(SentenceLibraryAlignmentService.shared.isAligning)
                        }

                        Divider()

                        Button(role: .destructive, action: onDelete) {
                            Label(lang.text("从句库删除", "Delete from Library"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 24, height: 26)
                    }
                    .menuStyle(.borderlessButton)
                }
            }
        }
        .padding(10)
        .background(isActive ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.1), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            handleTap()
        }
        .onHover { isHoveringRow = $0 }
        .contextMenu {
            Button {
                onTogglePlay()
            } label: {
                Label(isCurrentlyPlaying ? lang.text("暂停", "Pause") : lang.text("试听此句", "Play Sentence"), systemImage: isCurrentlyPlaying ? "pause.fill" : "play.fill")
            }

            Button {
                showTagPopover = true
            } label: {
                Label(lang.text("管理标签…", "Manage Tags…"), systemImage: "tag")
            }

            Button {
                showSourcePopover = true
            } label: {
                Label(lang.text("修改来源…", "Edit Source…"), systemImage: "film")
            }

            Button(action: onToggleBookmark) {
                Label(
                    entry.isBookmarked ? lang.text("取消星标难句", "Unstar Sentence") : lang.text("加入星标难句", "Star Sentence"),
                    systemImage: entry.isBookmarked ? "star.slash" : "star"
                )
            }

            Button {
                editSessionID = UUID()
                isEditing = true
            } label: {
                Label(lang.text("修改原文和译文", "Edit Original & Translation"), systemImage: "pencil")
            }

            if entry.wordTokens == nil || entry.wordTokens?.isEmpty == true {
                Button {
                    onAlignTokens?()
                } label: {
                    Label(
                        lang.text("对齐词级时间戳 (Whisper)", "Align Word Timestamps (Whisper)"),
                        systemImage: "waveform.badge.magnifyingglass"
                    )
                }
                .disabled(SentenceLibraryAlignmentService.shared.isAligning)
            }

            Divider()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.originalText, forType: .string)
                MainStatusCenter.shared.showSuccess(lang.text("已复制原文", "Copied original text"))
            } label: {
                Label(lang.text("复制原文", "Copy Original Text"), systemImage: "doc.on.doc")
            }

            if !entry.translation.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.translation, forType: .string)
                    MainStatusCenter.shared.showSuccess(lang.text("已复制译文", "Copied translation"))
                } label: {
                    Label(lang.text("复制译文", "Copy Translation"), systemImage: "doc.on.doc")
                }
            }

            Divider()

            Button(role: .destructive, action: onDelete) {
                Label(lang.text("从句库删除", "Delete from Library"), systemImage: "trash")
            }
        }
    }
}

// MARK: - 句库行内编辑器

private struct SentenceLibraryInlineSubtitleEditor: View {
    private struct ActiveSave {
        let id: UUID
        let task: Task<Bool, Never>
    }

    @ObservedObject private var lang = LanguageManager.shared
    @State private var originalText: String
    @State private var translationText: String
    @State private var savedOriginalText: String
    @State private var savedTranslationText: String
    @State private var isResolved = false
    @State private var isSaving = false
    @State private var activeSave: ActiveSave?

    let onSave: (String, String) async -> Bool
    let onFinish: () -> Void
    let onCancel: () -> Void

    init(
        originalText: String,
        translationText: String,
        onSave: @escaping (String, String) async -> Bool,
        onFinish: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        _originalText = State(initialValue: originalText)
        _translationText = State(initialValue: translationText)
        _savedOriginalText = State(initialValue: originalText)
        _savedTranslationText = State(initialValue: translationText)
        self.onSave = onSave
        self.onFinish = onFinish
        self.onCancel = onCancel
    }

    var body: some View {
        HStack(spacing: 5) {
            SentenceLibraryInlineTextFields(
                originalText: $originalText,
                translationText: $translationText,
                originalPlaceholder: lang.text("原文…", "Original text…"),
                translationPlaceholder: lang.text("译文…", "Translation…"),
                onFieldBlur: scheduleSaveIfNeeded,
                onSubmit: finish,
                onCancel: cancel
            )
            .frame(maxWidth: .infinity, minHeight: 26)

            Button(action: finish) {
                Group {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "checkmark")
                    }
                }
                .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            .help(lang.text("保存修改", "Save changes"))
            .accessibilityLabel(lang.text("保存修改", "Save changes"))
        }
        .onExitCommand(perform: cancel)
        .onDisappear {
            scheduleSaveIfNeeded()
        }
    }

    private func scheduleSaveIfNeeded() {
        guard !isResolved,
              originalText != savedOriginalText || translationText != savedTranslationText else { return }
        Task { @MainActor in
            _ = await persistChanges()
        }
    }

    private func finish() {
        guard !isResolved else { return }
        Task { @MainActor in
            let succeeded = await persistChanges()
            guard succeeded else { return }
            isResolved = true
            onFinish()
        }
    }

    private func cancel() {
        guard !isResolved else { return }
        isResolved = true
        onCancel()
    }

    @MainActor
    private func persistChanges() async -> Bool {
        while !isResolved {
            if let activeSave {
                let succeeded = await activeSave.task.value
                if self.activeSave?.id == activeSave.id {
                    self.activeSave = nil
                }
                guard succeeded else { return false }
                continue
            }

            guard originalText != savedOriginalText || translationText != savedTranslationText else { return true }

            let original = originalText
            let translation = translationText
            let saveID = UUID()
            isSaving = true
            let task = Task { @MainActor in
                let succeeded = await onSave(original, translation)
                if succeeded {
                    savedOriginalText = original
                    savedTranslationText = translation
                }
                isSaving = false
                return succeeded
            }
            activeSave = ActiveSave(id: saveID, task: task)
            let succeeded = await task.value
            if self.activeSave?.id == saveID {
                self.activeSave = nil
            }
            guard succeeded else { return false }
        }
        return false
    }
}

private struct SentenceLibraryInlineTextFields: NSViewRepresentable {
    @Binding var originalText: String
    @Binding var translationText: String
    let originalPlaceholder: String
    let translationPlaceholder: String
    let onFieldBlur: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> EditorView {
        let view = EditorView()
        let originalField = makeTextField(
            placeholder: originalPlaceholder,
            accessibilityLabel: "原文",
            font: .systemFont(ofSize: NSFont.systemFontSize),
            coordinator: context.coordinator
        )
        let translationField = makeTextField(
            placeholder: translationPlaceholder,
            accessibilityLabel: "译文",
            font: .systemFont(ofSize: NSFont.systemFontSize),
            coordinator: context.coordinator
        )
        originalField.stringValue = originalText
        translationField.stringValue = translationText
        view.install(originalField: originalField, translationField: translationField)
        context.coordinator.originalField = originalField
        context.coordinator.translationField = translationField
        return view
    }

    func updateNSView(_ nsView: EditorView, context: Context) {
        context.coordinator.parent = self
        nsView.originalField?.placeholderString = originalPlaceholder
        nsView.translationField?.placeholderString = translationPlaceholder
        if let originalField = nsView.originalField, originalField.stringValue != originalText {
            originalField.stringValue = originalText
        }
        if let translationField = nsView.translationField, translationField.stringValue != translationText {
            translationField.stringValue = translationText
        }
    }

    private func makeTextField(
        placeholder: String,
        accessibilityLabel: String,
        font: NSFont,
        coordinator: Coordinator
    ) -> SentenceLibraryInlineTextField {
        let field = SentenceLibraryInlineTextField()
        field.placeholderString = placeholder
        field.font = font
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.delegate = coordinator
        field.target = coordinator
        field.action = #selector(Coordinator.submitFromControl(_:))
        field.setAccessibilityLabel(accessibilityLabel)
        return field
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SentenceLibraryInlineTextFields
        weak var originalField: SentenceLibraryInlineTextField?
        weak var translationField: SentenceLibraryInlineTextField?

        init(_ parent: SentenceLibraryInlineTextFields) {
            self.parent = parent
            super.init()
        }

        func controlTextDidChange(_ notification: Notification) {
            if let originalField {
                parent.originalText = originalField.stringValue
            }
            if let translationField {
                parent.translationText = translationField.stringValue
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onFieldBlur()
        }

        @objc func submitFromControl(_ sender: Any?) {
            parent.onSubmit()
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard let field = control as? SentenceLibraryInlineTextField,
                  field === originalField || field === translationField else {
                return false
            }

            switch commandSelector.description {
            case "insertTab:":
                moveFocus(from: field, backwards: false)
                return true
            case "insertBacktab:":
                moveFocus(from: field, backwards: true)
                return true
            case "insertNewline:", "insertNewlineIgnoringFieldEditor:":
                parent.onSubmit()
                return true
            case "cancelOperation:":
                parent.onCancel()
                return true
            default:
                return false
            }
        }

        func moveFocus(from field: SentenceLibraryInlineTextField?, backwards: Bool) {
            guard let field, let window = field.window else { return }
            let target: SentenceLibraryInlineTextField?
            if backwards {
                target = field === originalField ? translationField : originalField
            } else {
                target = field === originalField ? translationField : originalField
            }
            guard let target else { return }
            window.makeFirstResponder(target)
        }
    }

    final class EditorView: NSView {
        private(set) weak var originalField: SentenceLibraryInlineTextField?
        private(set) weak var translationField: SentenceLibraryInlineTextField?
        private let stackView = NSStackView()
        private var didSetInitialFocus = false
        func install(
            originalField: SentenceLibraryInlineTextField,
            translationField: SentenceLibraryInlineTextField
        ) {
            self.originalField = originalField
            self.translationField = translationField
            stackView.orientation = .horizontal
            stackView.spacing = 5
            stackView.distribution = .fillEqually
            stackView.addArrangedSubview(originalField)
            stackView.addArrangedSubview(translationField)
            stackView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stackView)
            NSLayoutConstraint.activate([
                stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
                stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
                stackView.topAnchor.constraint(equalTo: topAnchor),
                stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: 26)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !didSetInitialFocus else { return }
            didSetInitialFocus = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, let originalField = self.originalField else { return }
                window.makeFirstResponder(originalField)
            }
        }
    }
}

private final class SentenceLibraryInlineTextField: NSTextField {}

// MARK: - 缩略图缓存与加载

@MainActor
private enum SentenceLibraryThumbnailCache {
    static let images: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
}

private struct SentenceLibraryThumbnail: View {
    let previewURL: URL?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.08)
                    Image(systemName: "film")
                        .foregroundStyle(.secondary.opacity(0.6))
                }
            }
        }
        .task(id: previewURL) {
            image = nil
            guard let previewURL else { return }
            if let cached = SentenceLibraryThumbnailCache.images.object(forKey: previewURL as NSURL) {
                image = cached
                return
            }
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: previewURL, options: [.mappedIfSafe])
            }.value
            guard !Task.isCancelled, let data, let loaded = NSImage(data: data) else { return }
            let pixelCost = max(1, Int(loaded.size.width * loaded.size.height * 4))
            SentenceLibraryThumbnailCache.images.setObject(loaded, forKey: previewURL as NSURL, cost: pixelCost)
            image = loaded
        }
    }
}

// MARK: - 底部全局播放控制条 (Bottom Playback Console)

private struct SentenceLibraryPlaybackBar: View {
    @ObservedObject private var lang = LanguageManager.shared
    @ObservedObject var player: SentenceLibraryPlayer
    let selectedEntry: SentenceLibraryEntry?
    let selectedMediaURL: URL?
    let currentPosition: Int?
    let totalCount: Int
    let onModeChanged: (SentenceLibraryPlaybackMode) -> Void

    private var displayedEntry: SentenceLibraryEntry? {
        player.currentEntry ?? selectedEntry
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                // 上一句 / 播放暂停 / 下一句 控制组
                HStack(spacing: 6) {
                    Button {
                        player.playPrevious()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .disabled(totalCount == 0)
                    .help(lang.text("上一句", "Previous Sentence"))

                    Button {
                        player.togglePlayback(for: selectedEntry, mediaURL: selectedMediaURL)
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedEntry == nil && player.currentEntry == nil)
                    .help(player.isPlaying ? lang.text("暂停", "Pause") : lang.text("播放所选句子", "Play Selected Sentence"))

                    Button {
                        player.playNext()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .disabled(totalCount == 0)
                    .help(lang.text("下一句", "Next Sentence"))
                }

                // 当前时间
                Text(formatTime(player.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)

                // 进度滑块
                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(0.05, player.duration)
                )
                .controlSize(.small)
                .disabled(player.currentEntry == nil)

                // 总时长
                Text(formatTime(player.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)

                // 序号进度指示 (#1/42)
                Text("#\(currentPosition.map(String.init) ?? "—")/\(totalCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .trailing)

                // 播放模式切换 (单句 / 单句循环 / 全篇循环)
                Picker("", selection: Binding(
                    get: { player.playbackMode },
                    set: { onModeChanged($0) }
                )) {
                    ForEach(SentenceLibraryPlaybackMode.allCases) { mode in
                        Text(lang.text(mode.chineseName, mode.englishName)).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 90)
                .help(lang.text("切换试听循环模式", "Playback loop mode"))

                Divider()
                    .frame(height: 16)

                // 当前试听文本显示或使用提示
                HStack(spacing: 5) {
                    Image(systemName: player.isPlaying ? "waveform" : "text.bubble")
                        .font(.caption2)
                        .foregroundStyle(player.isPlaying ? Color.accentColor : Color.secondary)
                    Text(displayedEntry?.originalText ?? lang.text("双击句子或点击播放开始试听", "Double-click sentence or press play"))
                        .font(.caption)
                        .foregroundStyle(displayedEntry == nil ? .secondary : .primary)
                        .lineLimit(1)
                }
                .frame(minWidth: 160, alignment: .leading)
            }

            if let errorMessage = player.errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(StudyMateMediaStyle.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}

// MARK: - 弹窗与视图模型

private struct SentencePreviewRequest: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

private struct SentenceImagePreview: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lang = LanguageManager.shared
    let request: SentencePreviewRequest
    @State private var image: NSImage?
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(request.title.isEmpty ? lang.text("句子预览", "Sentence Preview") : request.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button(lang.text("关闭", "Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.92))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    lang.text("无法读取预览图片", "Unable to Read Preview"),
                    systemImage: "photo.badge.exclamationmark"
                )
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 500)
        .task(id: request.url) {
            image = nil
            isLoading = false
            if let cached = SentenceLibraryThumbnailCache.images.object(forKey: request.url as NSURL) {
                image = cached
                return
            }

            isLoading = true
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: request.url, options: [.mappedIfSafe])
            }.value
            guard !Task.isCancelled else { return }
            if let data, let loaded = NSImage(data: data) {
                let pixelCost = max(1, Int(loaded.size.width * loaded.size.height * 4))
                SentenceLibraryThumbnailCache.images.setObject(
                    loaded,
                    forKey: request.url as NSURL,
                    cost: pixelCost
                )
                image = loaded
            }
            isLoading = false
        }
    }
}

private struct SentenceLibraryCreationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lang = LanguageManager.shared
    @State private var name = ""
    let onCreate: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(lang.text("新建句库", "New Sentence Library"))
                .font(.title3.bold())
            TextField(lang.text("句库名称", "Library Name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            HStack {
                Spacer()
                Button(lang.text("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(lang.text("创建", "Create")) {
                    onCreate(name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

private struct SentenceLibraryRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lang = LanguageManager.shared
    @State private var name: String
    let onRename: (String) -> Void

    init(initialName: String, onRename: @escaping (String) -> Void) {
        self._name = State(initialValue: initialName)
        self.onRename = onRename
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(lang.text("重命名句库", "Rename Sentence Library"))
                .font(.title3.bold())
            TextField(lang.text("句库新名称", "New Library Name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            HStack {
                Spacer()
                Button(lang.text("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(lang.text("保存", "Save")) {
                    onRename(name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

private struct SentenceLibraryNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
