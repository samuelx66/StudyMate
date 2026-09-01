import SwiftUI

public struct VocabularyNotebookView: View {
    @ObservedObject var manager: VocabularyNotebookManager
    @ObservedObject private var lang = LanguageManager.shared

    @State private var searchText = ""
    @State private var dateFilter: SentenceLibraryDateFilter = .all
    @State private var selectedDate = Date()
    @State private var selectedSource = ""
    @State private var sortOrder: SentenceLibrarySortOrder = .newestFirst
    @State private var selectedEntryIDs: Set<UUID> = []
    @State private var showCreateSheet = false
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

    private var entryNumbers: [UUID: Int] {
        Dictionary(uniqueKeysWithValues: manager.entries.enumerated().map { ($1.id, $0 + 1) })
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle(lang.text("生词本", "Vocabulary"))
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            detail
        }
        .sheet(isPresented: $showCreateSheet) {
            VocabularyNotebookCreationView { name in
                Task {
                    try? await manager.createNotebook(name: name)
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
        }
        .onChange(of: manager.selectedSource) { _, value in
            if selectedSource != value { selectedSource = value }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { manager.currentNotebookID },
                set: { if let id = $0 { manager.selectNotebook(id) } }
            )) {
                ForEach(manager.notebooks) { notebook in
                    Label(notebook.name, systemImage: notebook.isDefault ? "book.closed.fill" : "book.closed")
                        .tag(notebook.id)
                }
            }
            .listStyle(.sidebar)
            .disabled(manager.isWorking)

            Divider()

            HStack(spacing: 12) {
                Button { showCreateSheet = true } label: {
                    Image(systemName: "plus")
                }
                .help(lang.text("新建生词本", "New Vocabulary Notebook"))
                .disabled(manager.isWorking)

                Spacer()

                Button(role: .destructive) { confirmNotebookDeletion = true } label: {
                    Image(systemName: "trash")
                }
                .disabled(!manager.canDeleteCurrentNotebook)
                .help(
                    manager.currentNotebook?.isDefault == true
                        ? lang.text("默认生词本不可删除", "The default notebook cannot be deleted")
                        : lang.text("删除当前生词本", "Delete Current Vocabulary Notebook")
                )
            }
            .buttonStyle(.plain)
            .padding(10)
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()

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
                    systemImage: "book.closed",
                    description: Text(lang.text(
                        "在查词弹出框中点击书签图标即可加入生词本。",
                        "Click the bookmark icon in the dictionary popover to add a word."
                    ))
                )
            } else {
                Table(manager.entries, selection: $selectedEntryIDs) {
                    TableColumn(lang.text("序号", "No.")) { entry in
                        VocabularyNotebookNumberCell(number: entryNumbers[entry.id] ?? 0)
                    }
                    .width(min: 42, ideal: 52, max: 64)

                    TableColumn(lang.text("添加时间", "Added")) { entry in
                        Text(Self.dateFormatter.string(from: entry.addedAt))
                            .lineLimit(1)
                    }
                    .width(min: 130, ideal: 155, max: 190)

                    TableColumn(lang.text("单词", "Word")) { entry in
                        Text(entry.word)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                    }
                    .width(min: 120, ideal: 170)

                    TableColumn(lang.text("例句", "Example")) { entry in
                        Text(entry.exampleSentence.isEmpty ? "—" : entry.exampleSentence)
                            .foregroundStyle(entry.exampleSentence.isEmpty ? .secondary : .primary)
                            .lineLimit(2)
                    }
                    .width(min: 220, ideal: 360)

                    TableColumn(lang.text("来源", "Source")) { entry in
                        Text(entry.source.isEmpty ? "—" : entry.source)
                            .foregroundStyle(entry.source.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                    }
                    .width(min: 100, ideal: 150)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .disabled(manager.isWorking)
            }

            if manager.isWorking || manager.statusMessage != nil || manager.lastErrorMessage != nil {
                Divider()
                HStack(spacing: 8) {
                    Spacer()
                    if manager.isWorking { ProgressView().controlSize(.small) }
                    if let message = manager.statusMessage ?? manager.lastErrorMessage {
                        if manager.lastErrorMessage == nil {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        }
                    }
                    if manager.lastErrorMessage != nil {
                        Button { manager.dismissErrorMessage() } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .help(lang.text("关闭提示", "Dismiss Message"))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
        }
        .navigationTitle(manager.currentNotebook?.name ?? lang.text("生词本", "Vocabulary"))
        .searchable(text: $searchText, placement: .toolbar, prompt: lang.text("搜索单词", "Search words"))
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $dateFilter) {
                Text(lang.text("全部日期", "All Dates")).tag(SentenceLibraryDateFilter.all)
                Text(lang.text("今天", "Today")).tag(SentenceLibraryDateFilter.today)
                Text(lang.text("近 7 天", "Last 7 Days")).tag(SentenceLibraryDateFilter.lastSevenDays)
                Text(lang.text("近 30 天", "Last 30 Days")).tag(SentenceLibraryDateFilter.lastThirtyDays)
                Text(lang.text("指定日期", "Specific Date")).tag(SentenceLibraryDateFilter.specificDay)
            }
            .labelsHidden()
            .frame(width: 130)

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
            .frame(width: 150)

            Picker("", selection: $sortOrder) {
                Text(lang.text("最新加入", "Newest First")).tag(SentenceLibrarySortOrder.newestFirst)
                Text(lang.text("最早加入", "Oldest First")).tag(SentenceLibrarySortOrder.oldestFirst)
            }
            .labelsHidden()
            .frame(width: 110)

            if !manager.entries.isEmpty {
                Button { selectedEntryIDs = visibleIDs } label: {
                    Label(lang.text("全选", "Select All"), systemImage: "checkmark.circle")
                }
                .disabled(selectedVisibleIDs.count == manager.entries.count)

                Button { selectedEntryIDs = selectedEntryIDs.symmetricDifference(visibleIDs) } label: {
                    Label(lang.text("反选", "Invert Selection"), systemImage: "arrow.triangle.2.circlepath")
                }
            }

            if !selectedVisibleIDs.isEmpty {
                Button(role: .destructive) { deleteSelectedEntries() } label: {
                    Label(
                        lang.text("删除（\(selectedVisibleIDs.count)）", "Delete (\(selectedVisibleIDs.count))"),
                        systemImage: "trash"
                    )
                }
                .disabled(manager.isWorking)

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
                    Label(
                        lang.text("移动（\(selectedVisibleIDs.count)）", "Move (\(selectedVisibleIDs.count))"),
                        systemImage: "arrow.right.doc.on.clipboard"
                    )
                }
                .disabled(manager.isWorking || manager.notebooks.count < 2)
            }

            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
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
        let ids = selectedVisibleIDs
        guard !ids.isEmpty else { return }
        Task {
            do {
                _ = try await manager.deleteEntries(ids: ids)
                selectedEntryIDs.subtract(ids)
            } catch { }
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

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct VocabularyNotebookCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lang = LanguageManager.shared
    @State private var name = ""
    let onCreate: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(lang.text("新建生词本", "New Vocabulary Notebook"))
                .font(.title3.weight(.semibold))
            TextField(lang.text("生词本名称", "Notebook Name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            HStack {
                Spacer()
                Button(lang.text("取消", "Cancel")) { dismiss() }
                Button(lang.text("创建", "Create"), action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        dismiss()
    }
}

private struct VocabularyNotebookNumberCell: View {
    let number: Int

    var body: some View {
        Text(verbatim: String(number))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
