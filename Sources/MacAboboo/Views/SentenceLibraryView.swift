import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct SentenceLibraryView: View {
    @ObservedObject var manager: SentenceLibraryManager
    @ObservedObject private var lang = LanguageManager.shared
    @StateObject private var libraryPlayer: SentenceLibraryPlayer

    @State private var searchText = ""
    @State private var dateFilter: SentenceLibraryDateFilter = .all
    @State private var selectedDate = Date()
    @State private var selectedEntryIDs: Set<UUID> = []
    @State private var selectedEntryID: UUID?
    @State private var previewRequest: SentencePreviewRequest?
    @State private var showCreateSheet = false
    @State private var confirmLibraryDeletion = false
    @State private var notice: SentenceLibraryNotice?

    public init(manager: SentenceLibraryManager) {
        self.manager = manager
        self._libraryPlayer = StateObject(wrappedValue: SentenceLibraryPlayer())
    }

    private var selectedEntry: SentenceLibraryEntry? {
        manager.entries.first { $0.id == selectedEntryID }
    }

    public var body: some View {
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

                Divider()

                HStack(spacing: 12) {
                    Button { showCreateSheet = true } label: {
                        Image(systemName: "plus")
                    }
                    .help(lang.text("新建句库", "New Library"))

                    Button { chooseLibraryToImport() } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .help(lang.text("导入句库", "Import Library"))

                    Button { chooseLibraryExportDestination() } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(manager.currentLibrary == nil || manager.isWorking)
                    .help(lang.text("导出当前句库", "Export Current Library"))

                    Spacer()

                    Button(role: .destructive) { confirmLibraryDeletion = true } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(manager.currentLibrary == nil || manager.isWorking)
                    .help(lang.text("删除当前句库", "Delete Current Library"))
                }
                .buttonStyle(.plain)
                .padding(10)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(lang.text("搜索原文或译文…", "Search original or translation…"), text: $searchText)
                        .textFieldStyle(.plain)

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

                    if !selectedEntryIDs.isEmpty {
                        Button(role: .destructive) { deleteSelectedEntries() } label: {
                            Label(lang.text("删除（\(selectedEntryIDs.count)）", "Delete (\(selectedEntryIDs.count))"), systemImage: "trash")
                        }
                        .disabled(manager.isWorking)
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                SentenceLibraryPlaybackBar(
                    player: libraryPlayer,
                    selectedEntry: selectedEntry
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
                            ForEach(manager.entries) { entry in
                                SentenceLibraryEntryRow(
                                    entry: entry,
                                    previewURL: manager.previewURL(for: entry),
                                    isActive: selectedEntryID == entry.id,
                                    isChecked: selectedEntryIDs.contains(entry.id),
                                    onToggleCheck: { toggleSelection(entry.id) },
                                    onSelect: { selectedEntryID = entry.id },
                                    onPlay: {
                                        selectedEntryID = entry.id
                                        libraryPlayer.play(entry)
                                    },
                                    onPreview: {
                                        if let previewURL = manager.previewURL(for: entry) {
                                            selectedEntryID = entry.id
                                            previewRequest = SentencePreviewRequest(url: previewURL, title: entry.originalText)
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
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear {
            manager.updateFilter(searchText: searchText, dateFilter: dateFilter, selectedDate: selectedDate)
        }
        .onDisappear {
            libraryPlayer.stop()
        }
        .onChange(of: searchText) { _, value in
            manager.updateFilter(searchText: value, dateFilter: dateFilter, selectedDate: selectedDate)
            selectedEntryIDs.formIntersection(manager.entries.map(\.id))
        }
        .onChange(of: dateFilter) { _, value in
            manager.updateFilter(searchText: searchText, dateFilter: value, selectedDate: selectedDate)
            selectedEntryIDs.formIntersection(manager.entries.map(\.id))
        }
        .onChange(of: selectedDate) { _, value in
            guard dateFilter == .specificDay else { return }
            manager.updateFilter(searchText: searchText, dateFilter: dateFilter, selectedDate: value)
        }
        .onChange(of: manager.currentLibraryID) { _, _ in
            selectedEntryIDs.removeAll()
            selectedEntryID = nil
            libraryPlayer.stop()
        }
        .onChange(of: manager.entries.map(\.id)) { _, currentIDs in
            selectedEntryIDs.formIntersection(currentIDs)
            if let selectedEntryID, !currentIDs.contains(selectedEntryID) {
                self.selectedEntryID = nil
                libraryPlayer.stop()
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            SentenceLibraryCreationSheet { name in
                do {
                    try manager.createLibrary(name: name)
                } catch {
                    notice = SentenceLibraryNotice(title: lang.text("无法新建句库", "Unable to Create Library"), message: error.localizedDescription)
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
                do {
                    try manager.deleteCurrentLibrary()
                } catch {
                    notice = SentenceLibraryNotice(title: lang.text("删除失败", "Delete Failed"), message: error.localizedDescription)
                }
            }
        } message: {
            Text(lang.text("句库中的句子和预览图片都会被删除。", "All sentences and preview images in this library will be deleted."))
        }
        .alert(item: $notice) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text(lang.text("好", "OK"))))
        }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedEntryIDs.contains(id) { selectedEntryIDs.remove(id) }
        else { selectedEntryIDs.insert(id) }
    }

    private func deleteSelectedEntries() {
        let ids = selectedEntryIDs
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

    private func chooseLibraryExportDestination() {
        guard let library = manager.currentLibrary else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "mablib") ?? .data]
        panel.nameFieldStringValue = library.name + ".mablib"
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    try await manager.exportCurrentLibrary(to: url)
                    notice = SentenceLibraryNotice(
                        title: lang.text("句库导出完成", "Library Exported"),
                        message: url.path
                    )
                } catch {
                    notice = SentenceLibraryNotice(title: lang.text("导出失败", "Export Failed"), message: error.localizedDescription)
                }
            }
        }
    }

    private func chooseLibraryToImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "mablib") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    try await manager.importLibrary(from: url)
                } catch {
                    notice = SentenceLibraryNotice(title: lang.text("导入失败", "Import Failed"), message: error.localizedDescription)
                }
            }
        }
    }
}

private struct SentenceLibraryEntryRow: View {
    @ObservedObject private var lang = LanguageManager.shared
    let entry: SentenceLibraryEntry
    let previewURL: URL?
    let isActive: Bool
    let isChecked: Bool
    let onToggleCheck: () -> Void
    let onSelect: () -> Void
    let onPlay: () -> Void
    let onPreview: () -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(get: { isChecked }, set: { _ in onToggleCheck() }))
                .toggleStyle(.checkbox)
                .labelsHidden()

            HStack(alignment: .top, spacing: 12) {
                Button(action: onPreview) {
                    Group {
                        if let previewURL, let image = NSImage(contentsOf: previewURL) {
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

                VStack(alignment: .leading, spacing: 5) {
                    if !entry.originalText.isEmpty {
                        Text(entry.originalText)
                            .font(.body)
                    }
                    if !entry.translation.isEmpty {
                        Text(entry.translation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Label(Self.dateFormatter.string(from: entry.createdAt), systemImage: "calendar")
                        if !entry.sourceMediaName.isEmpty {
                            Label(entry.sourceMediaName, systemImage: "play.rectangle")
                                .lineLimit(1)
                        }
                        Text("\(SentenceSegment.formatTimecode(entry.startTime)) – \(SentenceSegment.formatTimecode(entry.endTime))")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onPlay)
            .onTapGesture(count: 1, perform: onSelect)
        }
        .padding(10)
        .background(isActive ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1)
        }
    }
}

private struct SentenceLibraryPlaybackBar: View {
    @ObservedObject private var lang = LanguageManager.shared
    @ObservedObject var player: SentenceLibraryPlayer
    let selectedEntry: SentenceLibraryEntry?

    private var displayedEntry: SentenceLibraryEntry? {
        player.currentEntry ?? selectedEntry
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    player.togglePlayback(for: selectedEntry)
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

                Text(displayedEntry?.originalText ?? lang.text("单击选择句子，双击即可播放", "Click to select, double-click to play"))
                    .font(.caption)
                    .foregroundStyle(displayedEntry == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .frame(minWidth: 180, alignment: .leading)
            }

            if let errorMessage = player.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
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

            if let image = NSImage(contentsOf: request.url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.92))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ContentUnavailableView(
                    lang.text("无法读取预览图片", "Unable to Read Preview"),
                    systemImage: "photo.badge.exclamationmark"
                )
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 500)
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
