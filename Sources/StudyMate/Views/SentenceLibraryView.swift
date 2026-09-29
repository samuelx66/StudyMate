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
            VStack(spacing: 0) {
                List(selection: Binding(
                    get: { manager.currentLibraryID },
                    set: { if let id = $0 { manager.selectLibrary(id) } }
                )) {
                    ForEach(manager.libraries) { library in
                        Label(library.name, systemImage: "books.vertical")
                            .tag(library.id)
                    }
                }
                .listStyle(.sidebar)

                Divider()

                HStack(spacing: 12) {
                    Button { showCreateSheet = true } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(manager.isWorking)
                    .help(lang.text("新建句库", "New Library"))

                    Spacer()

                    Button(role: .destructive) { confirmLibraryDeletion = true } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(!manager.canDeleteCurrentLibrary)
                    .help(
                        manager.currentLibrary?.isDefault == true
                            ? lang.text("默认句库不可删除", "The default library cannot be deleted")
                            : lang.text("删除当前句库", "Delete Current Library")
                    )
                }
                .buttonStyle(.plain)
                .padding(10)
            }
            .navigationTitle(lang.text("句库", "Libraries"))
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        enterStudyMode()
                    } label: {
                        if isPreparingStudy {
                            HStack(spacing: 5) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(lang.text("正在准备学习材料…", "Preparing study materials…"))
                            }
                        } else {
                            Label(lang.text("进入学习", "Enter Study"), systemImage: "graduationcap.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPreparingStudy || manager.isWorking || manager.entries.isEmpty)
                    .help(lang.text("以 5 大学习模式开始复习当前句库", "Start studying current library with 5 study modes"))

                    Picker("", selection: Binding(
                        get: { manager.typeFilter },
                        set: { manager.setTypeFilter($0) }
                    )) {
                        Text(SentenceLibraryTypeFilter.all.localized(with: lang)).tag(SentenceLibraryTypeFilter.all)
                        Text(SentenceLibraryTypeFilter.bookmarkedOnly.localized(with: lang)).tag(SentenceLibraryTypeFilter.bookmarkedOnly)
                        Text(SentenceLibraryTypeFilter.withVocabularyOnly.localized(with: lang)).tag(SentenceLibraryTypeFilter.withVocabularyOnly)
                    }
                    .labelsHidden()
                    .frame(width: 112)

                    Picker("", selection: $dateFilter) {
                        Text(lang.text("全部日期", "All Dates")).tag(SentenceLibraryDateFilter.all)
                        Text(lang.text("今天", "Today")).tag(SentenceLibraryDateFilter.today)
                        Text(lang.text("近 7 天", "Last 7 Days")).tag(SentenceLibraryDateFilter.lastSevenDays)
                        Text(lang.text("近 30 天", "Last 30 Days")).tag(SentenceLibraryDateFilter.lastThirtyDays)
                        Text(lang.text("指定日期", "Specific Date")).tag(SentenceLibraryDateFilter.specificDay)
                    }
                    .labelsHidden()
                    .frame(width: 110)

                    if dateFilter == .specificDay {
                        DatePicker("", selection: $selectedDate, displayedComponents: .date)
                            .labelsHidden()
                            .frame(width: 120)
                    }

                    Picker("", selection: $selectedSource) {
                        Text(lang.text("全部来源", "All Sources")).tag("")
                        ForEach(manager.availableSources, id: \.self) { source in
                            Text(source).tag(source)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)

                    Picker("", selection: Binding(
                        get: { manager.sortOrder },
                        set: { manager.setSortOrder($0) }
                    )) {
                        Text(SentenceLibrarySortOrder.newestFirst.localized(with: lang)).tag(SentenceLibrarySortOrder.newestFirst)
                        Text(SentenceLibrarySortOrder.oldestFirst.localized(with: lang)).tag(SentenceLibrarySortOrder.oldestFirst)
                        Text(SentenceLibrarySortOrder.originalIndexFirst.localized(with: lang)).tag(SentenceLibrarySortOrder.originalIndexFirst)
                    }
                    .labelsHidden()
                    .frame(width: 105)

                    Spacer(minLength: 8)

                    Button {
                        chooseLearningPackageImport()
                    } label: {
                        Label(lang.text("导入学习包…", "Import Package…"), systemImage: "archivebox")
                    }
                    .disabled(manager.isWorking)
                    .help(lang.text("导入 iPhone / iPad 学习包", "Import an iPhone / iPad learning package"))

                    Button {
                        chooseLearningPackageExport()
                    } label: {
                        Label(lang.text("导出学习包…", "Export Package…"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(manager.isWorking || manager.entries.isEmpty)
                    .help(lang.text("导出当前筛选结果为 .mabstudy", "Export the current result as .mabstudy"))

                    if !manager.entries.isEmpty {
                        Button { selectAllVisibleEntries() } label: {
                            Label(lang.text("全选", "Select All"), systemImage: "checkmark.circle")
                        }
                        .disabled(selectedVisibleCount == manager.entries.count)

                        Button { invertVisibleEntrySelection() } label: {
                            Label(lang.text("反选", "Invert Selection"), systemImage: "arrow.triangle.2.circlepath")
                        }
                    }

                    if selectedVisibleCount > 0 {
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
                            Label(lang.text("导出（\(selectedVisibleCount)）", "Export (\(selectedVisibleCount))"), systemImage: "square.and.arrow.up")
                        }
                        .disabled(manager.isWorking || selectedVisibleCount == 0)

                        Button {
                            showBatchTagPopover = true
                        } label: {
                            Label(lang.text("标签（\(selectedVisibleCount)）", "Tags (\(selectedVisibleCount))"), systemImage: "tag")
                        }
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

                        Button {
                            showBatchSourcePopover = true
                        } label: {
                            Label(lang.text("来源（\(selectedVisibleCount)）", "Source (\(selectedVisibleCount))"), systemImage: "play.rectangle")
                        }
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
                                    lang.text("对齐时间戳（\(missingSelectedEntries.count)）", "Align Timestamps (\(missingSelectedEntries.count))"),
                                    systemImage: "waveform.badge.magnifyingglass"
                                )
                            }
                            .disabled(manager.isWorking || SentenceLibraryAlignmentService.shared.isAligning)
                            .help(lang.text("使用 Whisper 为选中的句子批量补齐词级时间戳", "Batch align word timestamps using Whisper for selected sentences"))
                        }

                        Button(role: .destructive) { deleteSelectedEntries() } label: {
                            Label(lang.text("删除（\(selectedVisibleCount)）", "Delete (\(selectedVisibleCount))"), systemImage: "trash")
                        }
                        .disabled(manager.isWorking)

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
                            Label(lang.text("移动（\(selectedVisibleCount)）", "Move (\(selectedVisibleCount))"), systemImage: "arrow.right.doc.on.clipboard")
                        }
                        .disabled(manager.isWorking || manager.libraries.count < 2)
                    }

                    if let progress = manager.operationProgress {
                        ProgressView(value: progress.fraction)
                            .frame(width: 130)
                        Text(progress.phase)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))

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
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    }
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                }

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

                Divider()

                if manager.entries.isEmpty {
                    ContentUnavailableView(
                        lang.text("句库中没有匹配的句子", "No Matching Sentences"),
                        systemImage: "text.book.closed",
                        description: Text(lang.text("从断句列表勾选句子后加入当前句库。", "Select sentences in the segment list and add them to the current library."))
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(Array(manager.entries.enumerated()), id: \.element.id) { offset, entry in
                                SentenceLibraryEntryRow(
                                    entry: entry,
                                    number: offset + 1,
                                    previewURL: manager.previewURL(for: entry),
                                    isActive: selectedEntryID == entry.id,
                                    isChecked: selectedEntryIDs.contains(entry.id),
                                    availableTags: manager.availableTags,
                                    availableSources: manager.availableSources,
                                    matchingSourceCount: entry.sourceMediaName.isEmpty ? 0 : manager.entries.filter { $0.sourceMediaName == entry.sourceMediaName }.count,
                                    onToggleCheck: { toggleSelection(entry.id) },
                                    onToggleBookmark: {
                                        Task {
                                            try? await manager.toggleBookmark(id: entry.id)
                                        }
                                    },
                                    onSelect: {
                                        selectedEntryID = entry.id
                                        libraryPlayer.play(entry, mediaURL: manager.mediaURL(for: entry))
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
                        .padding(10)
                    }
                }
            }
            .navigationTitle(manager.currentLibrary?.name ?? lang.text("句库", "Sentence Library"))
            .searchable(
                text: $searchText,
                placement: .toolbar,
                prompt: Text(lang.text("搜索原文或译文…", "Search original or translation…"))
            )
        }
        .frame(minWidth: 820, minHeight: 560)
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

        isPreparingStudy = true
        MainStatusCenter.shared.showInfo(
            lang.text("正在准备学习材料…", "Preparing study materials…")
        )

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

private struct SentenceLibraryEntryRow: View {
    @ObservedObject private var lang = LanguageManager.shared
    let entry: SentenceLibraryEntry
    let number: Int
    let previewURL: URL?
    let isActive: Bool
    let isChecked: Bool
    let availableTags: [String]
    let availableSources: [String]
    let matchingSourceCount: Int
    let onToggleCheck: () -> Void
    let onToggleBookmark: () -> Void
    let onSelect: () -> Void
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

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { isChecked }, set: { _ in onToggleCheck() }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()

                Button(action: onToggleBookmark) {
                    Image(systemName: entry.isBookmarked ? "star.fill" : "star")
                        .foregroundStyle(entry.isBookmarked ? Color.yellow : Color.secondary.opacity(0.4))
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help(entry.isBookmarked ? lang.text("取消星标难句", "Unstar") : lang.text("加入星标难句", "Star"))
            }

            HStack(alignment: .top, spacing: 12) {
                Text("#\(number)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .leading)

                Button(action: onPreview) {
                    SentenceLibraryThumbnail(previewURL: previewURL)
                        .frame(width: 132, height: 74)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .bottomTrailing) {
                            if previewURL != nil {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.caption2.weight(.semibold))
                                    .padding(5)
                                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                                    .padding(5)
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(previewURL == nil)
                .help(previewURL == nil ? "" : lang.text("点击放大预览", "Click to enlarge preview"))

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
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            if !entry.effectiveSpeakerLabel.isEmpty {
                                Text(entry.effectiveSpeakerLabel)
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.12))
                                    .foregroundStyle(Color.accentColor)
                                    .clipShape(Capsule())
                            }
                            if let words = entry.associatedWords, !words.isEmpty {
                                Label("\(words.count)", systemImage: "text.book.closed")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
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

                        if !entry.originalText.isEmpty {
                            Text(entry.originalText)
                                .font(.body)
                        }
                        if !entry.translation.isEmpty {
                            Text(entry.translation)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Label(Self.dateFormatter.string(from: entry.createdAt), systemImage: "calendar")

                            // 原片坐标元数据标识：来源：阿甘正传.mp4 · #88 (00:15:23)
                            HStack(spacing: 4) {
                                Text(lang.text("来源：", "Source: "))
                                    .foregroundStyle(.secondary)

                                Button {
                                    showSourcePopover = true
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "play.rectangle")
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

                            // 句子起止时间戳与时长（完整保留时间范围，直观显示句子时长）
                            let duration = max(0, entry.endTime - entry.startTime)
                            let durationText = String(format: "%.1fs", duration)
                            Text("\(SentenceSegment.formatCoordinateTime(entry.startTime)) – \(SentenceSegment.formatCoordinateTime(entry.endTime)) (\(durationText))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .help(lang.text("原片区间：\(SentenceSegment.formatTimecode(entry.startTime)) – \(SentenceSegment.formatTimecode(entry.endTime))（时长 \(durationText)）", "Time range: \(SentenceSegment.formatTimecode(entry.startTime)) – \(SentenceSegment.formatTimecode(entry.endTime)) (\(durationText))"))

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
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 1, perform: onSelect)
                }

                Spacer(minLength: 0)
            }

            if !isEditing {
                Button {
                    showTagPopover = true
                } label: {
                    Image(systemName: entry.tags.isEmpty ? "tag" : "tag.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(entry.tags.isEmpty ? Color.secondary : Color.accentColor)
                .help(lang.text("管理标签", "Manage tags"))
                .accessibilityLabel(lang.text("管理标签", "Manage tags"))
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
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .help(lang.text("修改原文和译文", "Edit original and translation"))
                .accessibilityLabel(lang.text("修改原文和译文", "Edit original and translation"))
            }
        }
        .padding(10)
        .background(isActive ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1)
        }
        .contextMenu {
            Button {
                showTagPopover = true
            } label: {
                Label(lang.text("管理标签…", "Manage Tags…"), systemImage: "tag")
            }

            Button {
                showSourcePopover = true
            } label: {
                Label(lang.text("修改来源…", "Edit Source…"), systemImage: "play.rectangle")
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

/// 句库行内编辑器：Tab 在原文与译文之间循环，回车或完成按钮提交，
/// 字段失焦时先自动保存当前内容；Esc 或取消按钮放弃本次未保存修改。
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
                // The user may have edited the other field while this write
                // was in flight. Re-check the current draft before finishing.
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
            // Loop once more so a newer draft created during the write is
            // persisted before Enter or the checkmark closes the editor.
        }
        return false
    }
}

/// SwiftUI 的 TextField 在 macOS 上会优先把 Tab 交给系统焦点遍历，
/// 因而无法可靠地执行两个句库输入框之间的循环。这里用原生 NSTextField
/// 在 keyDown 层截获 Tab、Enter 和 Escape，再把普通文字输入交回系统。
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
            // AppKit sends this notification from the shared field editor
            // (NSTextView), not necessarily from the NSTextField itself.
            // Always read both controls so the SwiftUI draft cannot remain
            // stale while the visible native editor has already changed.
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

        /// A single-line NSTextField sends its action for the Return key. This
        /// complements doCommandBy, which is the reliable path for Tab but is
        /// not called for Return by every AppKit field-editor configuration.
        @objc func submitFromControl(_ sender: Any?) {
            parent.onSubmit()
        }

        /// NSTextField hands Tab and Return to its field editor. Handling the
        /// command here is the reliable AppKit path; NSTextField.keyDown and a
        /// window-level event monitor do not receive those commands consistently.
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

private final class SentenceLibraryInlineTextField: NSTextField {
}

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
                    Image(systemName: "waveform")
                        .foregroundStyle(.secondary)
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
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    player.togglePlayback(for: selectedEntry, mediaURL: selectedMediaURL)
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 14)
                }
                .buttonStyle(.borderless)
                .disabled(selectedEntry == nil)
                .help(player.isPlaying ? lang.text("暂停", "Pause") : lang.text("播放所选句子", "Play selected sentence"))

                Text(formatTime(player.currentTime))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(0.05, player.duration)
                )
                .disabled(player.currentEntry == nil)

                Text(formatTime(player.duration))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .leading)

                Text("#\(currentPosition.map(String.init) ?? "—")/\(totalCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)

                Picker("", selection: Binding(
                    get: { player.playbackMode },
                    set: { onModeChanged($0) }
                )) {
                    ForEach(SentenceLibraryPlaybackMode.allCases) { mode in
                        Text(lang.text(mode.chineseName, mode.englishName)).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 92)

                Text(displayedEntry?.originalText ?? lang.text("单击选择句子，双击即可播放", "Click to select, double-click to play"))
                    .font(.caption)
                    .foregroundStyle(displayedEntry == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .frame(minWidth: 180, alignment: .leading)
            }

            if let errorMessage = player.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(StudyMateMediaStyle.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}

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
                .frame(width: 340)
            HStack {
                Spacer()
                Button(lang.text("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(lang.text("创建", "Create")) {
                    onCreate(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
    }
}

private struct SentenceLibraryNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
