import SwiftUI
import UniformTypeIdentifiers

public struct VocabularyNotebookView: View {
    @ObservedObject var manager: VocabularyNotebookManager
    @ObservedObject private var lang = LanguageManager.shared
    @ObservedObject private var speaker = WordPronunciationSpeaker.shared

    @State private var searchText = ""
    @State private var dateFilter: SentenceLibraryDateFilter = .all
    @State private var selectedDate = Date()
    @State private var selectedSource = ""
    @State private var sortOrder: SentenceLibrarySortOrder = .newestFirst
    @State private var selectedEntryIDs: Set<UUID> = []
    @State private var selectedEntryID: UUID?
    @State private var showCreateSheet = false
    @State private var showRenameSheet = false
    @State private var showAddWordSheet = false
    @State private var notebookToRename: VocabularyNotebookDescriptor?
    @State private var confirmNotebookDeletion = false
    @State private var confirmMove = false
    @State private var pendingMoveDestinationID: UUID?

    public init(manager: VocabularyNotebookManager) {
        self.manager = manager
    }

    private var visibleIDs: Set<UUID> {
        Set(manager.entries.map(\.id))
    }

    private var selectedVisibleIDs: Set<UUID> {
        selectedEntryIDs.intersection(visibleIDs)
    }

    public var body: some View {
        NavigationSplitView {
            // MARK: - 左侧生词本列表 (Sidebar)
            VStack(spacing: 0) {
                List(selection: Binding(
                    get: { manager.currentNotebookID },
                    set: { if let id = $0 { manager.selectNotebook(id) } }
                )) {
                    ForEach(manager.notebooks) { notebook in
                        HStack(spacing: 8) {
                            Label(notebook.name, systemImage: notebook.isDefault ? "book.closed.fill" : "book.closed")
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            let count = manager.notebookCounts[notebook.id] ?? (notebook.id == manager.currentNotebookID ? manager.entries.count : 0)
                            Text("\(count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                        .tag(notebook.id)
                        .contextMenu {
                            Button {
                                notebookToRename = notebook
                                showRenameSheet = true
                            } label: {
                                Label(lang.text("重命名生词本…", "Rename Notebook…"), systemImage: "pencil")
                            }

                            Button {
                                exportEntries(ids: nil)
                            } label: {
                                Label(lang.text("导出生词本… (.txt)", "Export Notebook… (.txt)"), systemImage: "square.and.arrow.up")
                            }

                            Divider()

                            Button(role: .destructive) {
                                if notebook.id == manager.currentNotebookID {
                                    confirmNotebookDeletion = true
                                } else {
                                    manager.selectNotebook(notebook.id)
                                    confirmNotebookDeletion = true
                                }
                            } label: {
                                Label(lang.text("删除生词本", "Delete Notebook"), systemImage: "trash")
                            }
                            .disabled(notebook.isDefault)
                        }
                    }
                }
                .listStyle(.sidebar)
                .disabled(manager.isWorking)

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
                    .help(lang.text("新建生词本", "New Vocabulary Notebook"))

                    Button {
                        if let current = manager.currentNotebook {
                            notebookToRename = current
                            showRenameSheet = true
                        }
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .disabled(manager.isWorking || manager.currentNotebook == nil)
                    .help(lang.text("重命名当前生词本", "Rename Current Notebook"))

                    Spacer()

                    Button(role: .destructive) {
                        confirmNotebookDeletion = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .disabled(!manager.canDeleteCurrentNotebook)
                    .help(
                        manager.currentNotebook?.isDefault == true
                            ? lang.text("默认生词本不可删除", "The default notebook cannot be deleted")
                            : lang.text("删除当前生词本", "Delete Current Vocabulary Notebook")
                    )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .navigationTitle(lang.text("生词本", "Vocabulary"))
            .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
        } detail: {
            // MARK: - 主详情视图 (Detail Area)
            VStack(spacing: 0) {
                // 顶部工具栏 (Header Bar)
                HStack(spacing: 10) {
                    // 主行动：手动添加生词
                    Button {
                        showAddWordSheet = true
                    } label: {
                        Label(lang.text("添加生词", "Add Word"), systemImage: "plus")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(manager.isWorking || manager.currentNotebook == nil)
                    .help(lang.text("手动录入新单词及例句", "Manually add a new word with examples"))

                    // 统计提示徽标
                    HStack(spacing: 4) {
                        Image(systemName: "character.book.closed")
                            .foregroundStyle(Color.accentColor)
                        Text(lang.text("共 \(manager.entries.count) 个生词", "\(manager.entries.count) Words"))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)

                    Spacer(minLength: 8)

                    // 来源筛选器 (Source Menu)
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

                    // 日期筛选器 (Date Menu)
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
                    .help(lang.text("按加入生词本日期过滤", "Filter by date added"))

                    if dateFilter == .specificDay {
                        DatePicker("", selection: $selectedDate, displayedComponents: .date)
                            .labelsHidden()
                            .frame(width: 105)
                    }

                    // 排序方式 (Sort Menu)
                    Menu {
                        Button {
                            sortOrder = .newestFirst
                        } label: {
                            HStack {
                                Text(lang.text("最新加入", "Newest First"))
                                if sortOrder == .newestFirst { Image(systemName: "checkmark") }
                            }
                        }

                        Button {
                            sortOrder = .oldestFirst
                        } label: {
                            HStack {
                                Text(lang.text("最早加入", "Oldest First"))
                                if sortOrder == .oldestFirst { Image(systemName: "checkmark") }
                            }
                        }

                        Button {
                            sortOrder = .originalIndexFirst
                        } label: {
                            HStack {
                                Text(lang.text("字母 A-Z", "Alphabetical (A-Z)"))
                                if sortOrder == .originalIndexFirst { Image(systemName: "checkmark") }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down")
                            Text(sortOrderTitle)
                        }
                        .font(.callout)
                    }
                    .menuStyle(.borderlessButton)
                    .help(lang.text("调整生词排序规则", "Change sorting order"))

                    // 更多功能菜单
                    Menu {
                        Section(lang.text("导出", "Export")) {
                            Button {
                                exportEntries(ids: selectedVisibleIDs.isEmpty ? nil : selectedVisibleIDs)
                            } label: {
                                Label(lang.text("导出生词本… (.txt)", "Export Notebook… (.txt)"), systemImage: "square.and.arrow.up")
                            }
                            .disabled(manager.isWorking || manager.entries.isEmpty)
                        }

                        if !manager.entries.isEmpty {
                            Section(lang.text("选择操作", "Selection")) {
                                Button {
                                    selectedEntryIDs = visibleIDs
                                } label: {
                                    Label(lang.text("全选所有可见生词", "Select All Visible"), systemImage: "checkmark.circle")
                                }

                                Button {
                                    selectedEntryIDs = selectedEntryIDs.symmetricDifference(visibleIDs)
                                } label: {
                                    Label(lang.text("反选当前选区", "Invert Selection"), systemImage: "arrow.triangle.2.circlepath")
                                }

                                if !selectedVisibleIDs.isEmpty {
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
                    .help(lang.text("更多操作", "More actions"))

                    if manager.isWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))

                // MARK: - 多选专属批量操作条 (Batch Action Bar)
                if !selectedVisibleIDs.isEmpty {
                    Divider()
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                            Text(lang.text("已选择 \(selectedVisibleIDs.count) 个生词", "\(selectedVisibleIDs.count) Selected"))
                                .font(.callout.weight(.semibold))
                        }
                        .padding(.trailing, 4)

                        Button {
                            selectedEntryIDs = visibleIDs
                        } label: {
                            Text(lang.text("全选", "All"))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(selectedVisibleIDs.count == manager.entries.count)

                        Button {
                            selectedEntryIDs = selectedEntryIDs.symmetricDifference(visibleIDs)
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

                        // 批量朗读所选单词
                        Button {
                            speakSelectedWords()
                        } label: {
                            Label(lang.text("朗读所选", "Speak Selected"), systemImage: "speaker.wave.2")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        // 批量移动到其他生词本
                        if manager.notebooks.count > 1 {
                            Menu {
                                ForEach(manager.notebooks.filter { $0.id != manager.currentNotebookID }) { notebook in
                                    Button {
                                        pendingMoveDestinationID = notebook.id
                                        confirmMove = true
                                    } label: {
                                        Label(notebook.name, systemImage: "book.closed")
                                    }
                                }
                            } label: {
                                Label(lang.text("移动到", "Move To"), systemImage: "arrow.right.doc.on.clipboard")
                            }
                            .menuStyle(.borderedButton)
                            .controlSize(.small)
                            .disabled(manager.isWorking)
                        }

                        // 批量导出纯文本
                        Button {
                            exportEntries(ids: selectedVisibleIDs)
                        } label: {
                            Label(lang.text("导出所选", "Export Selected"), systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(manager.isWorking)

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

                // MARK: - 生词列表区 (Cards List)
                if manager.isLoadingEntries && manager.entries.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(lang.text("正在加载生词本…", "Loading vocabulary…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if manager.entries.isEmpty {
                    ContentUnavailableView(
                        lang.text("生词本中没有匹配的单词", "No Matching Words"),
                        systemImage: "character.book.closed",
                        description: Text(lang.text(
                            "可以在学习时查词加入生词本，或点击左上角“添加生词”手动录入。",
                            "Add words while studying or click “Add Word” above to record new vocabulary."
                        ))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let otherNotebooks = manager.notebooks.filter { $0.id != manager.currentNotebookID }
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(Array(manager.entries.enumerated()), id: \.element.id) { offset, entry in
                                VocabularyWordCardRow(
                                    entry: entry,
                                    number: offset + 1,
                                    isActive: selectedEntryID == entry.id,
                                    isChecked: selectedEntryIDs.contains(entry.id),
                                    isSpeaking: speaker.speakingWordID == entry.id,
                                    onToggleCheck: { toggleSelection(entry.id) },
                                    onSelect: { selectedEntryID = entry.id },
                                    onSpeak: {
                                        speaker.speak(word: entry.word, entryID: entry.id)
                                    },
                                    onDelete: {
                                        deleteEntries(ids: [entry.id])
                                    },
                                    onMoveTo: { targetID in
                                        Task {
                                            try? await manager.moveEntries(ids: [entry.id], to: targetID)
                                        }
                                    },
                                    notebooks: otherNotebooks
                                )
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .navigationTitle(manager.currentNotebook?.name ?? lang.text("生词本", "Vocabulary"))
            .searchable(text: $searchText, placement: .toolbar, prompt: lang.text("搜索单词或例句…", "Search words or examples…"))
            .overlay(alignment: .bottom) {
                WindowFloatingStatusToast(bottomPadding: 24)
            }
        }
        .frame(minWidth: 840, minHeight: 560)
        .sheet(isPresented: $showCreateSheet) {
            VocabularyNotebookCreationView { name in
                Task {
                    try? await manager.createNotebook(name: name)
                }
            }
        }
        .sheet(isPresented: $showRenameSheet) {
            if let target = notebookToRename {
                VocabularyNotebookRenameSheet(initialName: target.name) { newName in
                    Task {
                        try? await manager.renameNotebook(id: target.id, newName: newName)
                    }
                }
            }
        }
        .sheet(isPresented: $showAddWordSheet) {
            VocabularyWordCreationSheet { word, example, source in
                Task {
                    try? await manager.addWord(word: word, exampleSentence: example, source: source)
                }
            }
        }
        .confirmationDialog(
            lang.text("删除当前生词本？", "Delete Current Vocabulary Notebook?"),
            isPresented: $confirmNotebookDeletion,
            titleVisibility: .visible
        ) {
            Button(lang.text("删除", "Delete"), role: .destructive) {
                Task {
                    try? await manager.deleteCurrentNotebook()
                    selectedEntryIDs.removeAll()
                }
            }
            Button(lang.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(lang.text(
                "当前生词本中的所有单词都会被删除。默认生词本不能删除。",
                "All words in this notebook will be deleted. The default notebook cannot be deleted."
            ))
        }
        .confirmationDialog(
            lang.text("移动选中的生词？", "Move Selected Words?"),
            isPresented: $confirmMove,
            titleVisibility: .visible
        ) {
            if let pendingMoveDestinationID,
               let destination = manager.notebooks.first(where: { $0.id == pendingMoveDestinationID }) {
                Button(lang.text("移动到 \(destination.name)", "Move to \(destination.name)")) {
                    moveSelectedEntries(to: destination.id)
                }
            }
            Button(lang.text("取消", "Cancel"), role: .cancel) {
                pendingMoveDestinationID = nil
            }
        } message: {
            if let destination = pendingMoveDestinationID.flatMap({ id in manager.notebooks.first(where: { $0.id == id }) }) {
                Text(lang.text(
                    "选中的生词会移动到“\(destination.name)”，并从当前生词本移除。",
                    "The selected words will move to \(destination.name) and be removed from the current notebook."
                ))
            }
        }
        .onChange(of: searchText) { _, value in updateFilter(searchText: value) }
        .onChange(of: dateFilter) { _, value in updateFilter(dateFilter: value) }
        .onChange(of: selectedDate) { _, value in updateFilter(selectedDate: value) }
        .onChange(of: selectedSource) { _, value in updateFilter(source: value) }
        .onChange(of: sortOrder) { _, value in updateFilter(sortOrder: value) }
        .onChange(of: manager.entries) { _, entries in
            selectedEntryIDs.formIntersection(Set(entries.map(\.id)))
        }
        .onChange(of: manager.currentNotebookID) { _, _ in
            selectedSource = manager.selectedSource
            selectedEntryIDs.removeAll()
            selectedEntryID = nil
        }
        .onChange(of: manager.selectedSource) { _, value in
            if selectedSource != value { selectedSource = value }
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

    private var sortOrderTitle: String {
        switch sortOrder {
        case .newestFirst: return lang.text("最新加入", "Newest First")
        case .oldestFirst: return lang.text("最早加入", "Oldest First")
        case .originalIndexFirst: return lang.text("字母 A-Z", "Alphabetical")
        }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedEntryIDs.contains(id) {
            selectedEntryIDs.remove(id)
        } else {
            selectedEntryIDs.insert(id)
        }
    }

    private func speakSelectedWords() {
        let selectedWords = manager.entries.filter { selectedEntryIDs.contains($0.id) }
        guard let first = selectedWords.first else { return }
        speaker.speak(word: first.word, entryID: first.id)
    }

    private func updateFilter(
        searchText: String? = nil,
        dateFilter: SentenceLibraryDateFilter? = nil,
        selectedDate: Date? = nil,
        source: String? = nil,
        sortOrder: SentenceLibrarySortOrder? = nil
    ) {
        manager.updateFilter(
            searchText: searchText ?? self.searchText,
            dateFilter: dateFilter ?? self.dateFilter,
            selectedDate: selectedDate ?? self.selectedDate,
            source: source ?? self.selectedSource,
            sortOrder: sortOrder ?? self.sortOrder
        )
    }

    private func deleteSelectedEntries() {
        deleteEntries(ids: selectedVisibleIDs)
    }

    private func deleteEntries(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let removesActive = selectedEntryID.map(ids.contains) ?? false
        Task {
            do {
                _ = try await manager.deleteEntries(ids: ids)
                selectedEntryIDs.subtract(ids)
                if removesActive { selectedEntryID = nil }
            } catch { }
        }
    }

    private func exportEntries(ids: Set<UUID>? = nil) {
        let targetEntries: [VocabularyWordEntry]
        let defaultFilenameSuffix: String
        if let ids, !ids.isEmpty {
            targetEntries = manager.entries.filter { ids.contains($0.id) }
            defaultFilenameSuffix = "-已选生词"
        } else {
            targetEntries = manager.entries
            defaultFilenameSuffix = ""
        }
        guard !targetEntries.isEmpty else { return }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.plainText]
        let baseName = manager.currentNotebook?.name ?? lang.text("生词本", "Vocabulary")
        panel.nameFieldStringValue = "\(baseName)\(defaultFilenameSuffix).txt"
        panel.message = lang.text(
            "导出生词本记录为纯文本文件（每行：单词、原文例句、译文例句、来源，以制表符分隔）",
            "Export vocabulary records to plain text (each line: word, original example, translated example, source, tab-separated)"
        )
        panel.prompt = lang.text("导出", "Export")

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        Task {
            do {
                _ = try await manager.exportToPlainText(
                    entries: targetEntries,
                    destinationURL: destinationURL
                )
            } catch {}
        }
    }

    private func moveSelectedEntries(to destinationID: UUID) {
        let ids = selectedVisibleIDs
        guard !ids.isEmpty else { return }
        Task {
            do {
                _ = try await manager.moveEntries(ids: ids, to: destinationID)
                selectedEntryIDs.subtract(ids)
                pendingMoveDestinationID = nil
            } catch { }
        }
    }
}

// MARK: - 生词卡片视图组件 (Vocabulary Word Card Row)

private struct VocabularyWordCardRow: View {
    @ObservedObject private var lang = LanguageManager.shared
    let entry: VocabularyWordEntry
    let number: Int
    let isActive: Bool
    let isChecked: Bool
    let isSpeaking: Bool
    let onToggleCheck: () -> Void
    let onSelect: () -> Void
    let onSpeak: () -> Void
    let onDelete: () -> Void
    let onMoveTo: (UUID) -> Void
    let notebooks: [VocabularyNotebookDescriptor]

    @State private var isHoveringRow = false
    @State private var lastClickTime: Date?

    private func handleTap() {
        let now = Date()
        let interval = NSEvent.doubleClickInterval
        if let last = lastClickTime, now.timeIntervalSince(last) < interval {
            lastClickTime = nil
            onSpeak()
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

    private var parsedExample: (original: String, translation: String) {
        VocabularyExportFormatter.parseExampleSentence(entry.exampleSentence)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // 左侧控制列：勾选复选框 + 序号 + 独立朗读发音按钮
            VStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { isChecked }, set: { _ in onToggleCheck() }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()

                Button(action: onSpeak) {
                    Image(systemName: isSpeaking ? "speaker.wave.2.circle.fill" : "speaker.wave.2.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(isSpeaking ? Color.accentColor : (isHoveringRow || isActive ? Color.primary : Color.secondary.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .help(lang.text("朗读单词发音", "Pronounce Word"))
            }
            .frame(width: 24)

            // 序号
            Text("#\(number)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
                .padding(.top, 2)

            // 中部主体：单词大标题 + 来源胶囊 + 原文例句 + 译文例句
            VStack(alignment: .leading, spacing: 6) {
                // 第一行：单词 + 来源胶囊 + 入库日期
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.word)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(Color.primary)

                    if !entry.source.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "film")
                                .font(.caption2)
                            Text(entry.source)
                                .lineLimit(1)
                        }
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Label(Self.dateFormatter.string(from: entry.addedAt), systemImage: "calendar")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // 第二行：例句展示（原文例句 + 译文例句）
                let (originalExample, translatedExample) = parsedExample
                if !originalExample.isEmpty || !translatedExample.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        if !originalExample.isEmpty {
                            Text(originalExample)
                                .font(.body)
                                .lineSpacing(2)
                                .foregroundStyle(Color.primary.opacity(0.9))
                        }
                        if !translatedExample.isEmpty {
                            Text(translatedExample)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 1)
                } else {
                    Text(lang.text("暂无例句", "No example sentence"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            // 右侧快捷操作列
            HStack(spacing: 4) {
                Button(action: onSpeak) {
                    Image(systemName: "speaker.wave.2")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isSpeaking ? Color.accentColor : Color.secondary)
                .help(lang.text("朗读单词发音", "Pronounce Word"))

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.word, forType: .string)
                    MainStatusCenter.shared.showSuccess(lang.text("已复制单词“\(entry.word)”", "Copied word “\(entry.word)”"))
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.secondary)
                .help(lang.text("复制单词", "Copy Word"))

                Menu {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.word, forType: .string)
                        MainStatusCenter.shared.showSuccess(lang.text("已复制单词“\(entry.word)”", "Copied word “\(entry.word)”"))
                    } label: {
                        Label(lang.text("复制单词", "Copy Word"), systemImage: "doc.on.doc")
                    }

                    if !parsedExample.original.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(parsedExample.original, forType: .string)
                            MainStatusCenter.shared.showSuccess(lang.text("已复制原文例句", "Copied original example"))
                        } label: {
                            Label(lang.text("复制原文例句", "Copy Original Example"), systemImage: "text.quote")
                        }
                    }

                    if !parsedExample.translation.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(parsedExample.translation, forType: .string)
                            MainStatusCenter.shared.showSuccess(lang.text("已复制译文例句", "Copied translated example"))
                        } label: {
                            Label(lang.text("复制译文例句", "Copy Translated Example"), systemImage: "text.quote")
                        }
                    }

                    if !notebooks.isEmpty {
                        Divider()
                        Menu(lang.text("移动到其他生词本…", "Move to Notebook…")) {
                            ForEach(notebooks) { notebook in
                                Button(notebook.name) {
                                    onMoveTo(notebook.id)
                                }
                            }
                        }
                    }

                    Divider()

                    Button(role: .destructive, action: onDelete) {
                        Label(lang.text("从生词本删除", "Delete from Vocabulary"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 26)
                }
                .menuStyle(.borderlessButton)
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
            Button(action: onSpeak) {
                Label(lang.text("朗读单词发音", "Pronounce Word"), systemImage: "speaker.wave.2")
            }

            Divider()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.word, forType: .string)
                MainStatusCenter.shared.showSuccess(lang.text("已复制单词“\(entry.word)”", "Copied word “\(entry.word)”"))
            } label: {
                Label(lang.text("复制单词", "Copy Word"), systemImage: "doc.on.doc")
            }

            if !parsedExample.original.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(parsedExample.original, forType: .string)
                    MainStatusCenter.shared.showSuccess(lang.text("已复制原文例句", "Copied original example"))
                } label: {
                    Label(lang.text("复制原文例句", "Copy Original Example"), systemImage: "text.quote")
                }
            }

            if !notebooks.isEmpty {
                Divider()
                Menu(lang.text("移动到其他生词本…", "Move to Notebook…")) {
                    ForEach(notebooks) { notebook in
                        Button(notebook.name) {
                            onMoveTo(notebook.id)
                        }
                    }
                }
            }

            Divider()

            Button(role: .destructive, action: onDelete) {
                Label(lang.text("从生词本删除", "Delete from Vocabulary"), systemImage: "trash")
            }
        }
    }
}

// MARK: - 弹窗组件

private struct VocabularyNotebookCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lang = LanguageManager.shared
    @State private var name = ""
    let onCreate: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(lang.text("新建生词本", "New Vocabulary Notebook"))
                .font(.title3.bold())
            TextField(lang.text("生词本名称", "Notebook Name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(create)
            HStack {
                Spacer()
                Button(lang.text("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(lang.text("创建", "Create"), action: create)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        dismiss()
    }
}

private struct VocabularyNotebookRenameSheet: View {
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
            Text(lang.text("重命名生词本", "Rename Vocabulary Notebook"))
                .font(.title3.bold())
            TextField(lang.text("生词本新名称", "New Notebook Name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(save)
            HStack {
                Spacer()
                Button(lang.text("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(lang.text("保存", "Save"), action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onRename(trimmed)
        dismiss()
    }
}

private struct VocabularyWordCreationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lang = LanguageManager.shared
    @State private var word = ""
    @State private var originalExample = ""
    @State private var translatedExample = ""
    @State private var source = ""
    let onAdd: (String, String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(lang.text("添加新生词", "Add New Vocabulary"))
                .font(.title3.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text(lang.text("单词：", "Word:"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField(lang.text("输入要添加的生词（必填）", "Enter word (required)"), text: $word)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(lang.text("原文例句：", "Original Example:"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField(lang.text("输入例句原文（选填）", "Enter original sentence (optional)"), text: $originalExample)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(lang.text("例句译文：", "Translated Example:"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField(lang.text("输入例句译文（选填）", "Enter translation (optional)"), text: $translatedExample)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(lang.text("来源：", "Source:"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField(lang.text("例如：老友记 S01E01 或 自学积累", "e.g. Friends S01E01"), text: $source)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button(lang.text("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(lang.text("添加", "Add")) {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func save() {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWord.isEmpty else { return }
        let trimmedOrig = originalExample.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTrans = translatedExample.trimmingCharacters(in: .whitespacesAndNewlines)
        let exampleCombined: String
        if !trimmedOrig.isEmpty && !trimmedTrans.isEmpty {
            exampleCombined = "\(trimmedOrig)\n\(trimmedTrans)"
        } else if !trimmedOrig.isEmpty {
            exampleCombined = trimmedOrig
        } else {
            exampleCombined = trimmedTrans
        }
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        onAdd(trimmedWord, exampleCombined, trimmedSource)
        dismiss()
    }
}
