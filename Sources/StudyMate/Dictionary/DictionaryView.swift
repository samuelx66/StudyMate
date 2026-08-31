import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// First-version dictionary window. It is intentionally independent of the
/// media player: the same Rust engine can later be hosted by mobile clients.
public struct DictionaryView: View {
    @StateObject private var engine: DictionaryEngine
    @ObservedObject private var lang = LanguageManager.shared
    @State private var query = ""
    @State private var selectedDictionaryID: String?
    @State private var dictionaryPendingDeletion: StudyMateDictionarySummary?

    @MainActor
    public init() {
        self.init(engine: .shared)
    }

    @MainActor
    public init(engine: DictionaryEngine) {
        _engine = StateObject(wrappedValue: engine)
    }

    private var selectedTitle: String {
        guard let selectedDictionaryID else {
            return lang.text("全部词典", "All dictionaries")
        }
        return engine.dictionaries.first(where: { $0.id == selectedDictionaryID })?.title
            ?? lang.text("全部词典", "All dictionaries")
    }

    public var body: some View {
        HSplitView {
            dictionarySidebar
                .frame(minWidth: 200, idealWidth: 230, maxWidth: 280)
            dictionaryContent
        }
        .background(StudyMateMediaStyle.windowBackground)
        .alert(
            lang.text("确认删除词典？", "Delete Dictionary?"),
            isPresented: Binding(
                get: { dictionaryPendingDeletion != nil },
                set: { if !$0 { dictionaryPendingDeletion = nil } }
            ),
            presenting: dictionaryPendingDeletion
        ) { dict in
            Button(lang.text("删除", "Delete"), role: .destructive) {
                let targetID = dict.id
                dictionaryPendingDeletion = nil
                if selectedDictionaryID == targetID {
                    selectedDictionaryID = nil
                }
                engine.deleteDictionary(id: targetID)
            }
            Button(lang.text("取消", "Cancel"), role: .cancel) {
                dictionaryPendingDeletion = nil
            }
        } message: { dict in
            Text(lang.text(
                "确定要从 StudyMate 中删除词典“\(dict.title)”吗？此操作无法撤销。",
                "Are you sure you want to delete “\(dict.title)” from StudyMate? This action cannot be undone."
            ))
        }
        .task {
            engine.refresh()
            if let pending = engine.consumeRequestedQuery() {
                query = pending
                engine.search(query: pending, dictionaryID: selectedDictionaryID)
            }
        }
        .onChange(of: engine.requestedQuery) { _, pending in
            guard let pending else { return }
            query = pending
            _ = engine.consumeRequestedQuery()
            engine.search(query: pending, dictionaryID: selectedDictionaryID)
        }
        .onChange(of: engine.dictionaries) { _, newDicts in
            if let sel = selectedDictionaryID, !newDicts.contains(where: { $0.id == sel }) {
                selectedDictionaryID = nil
            }
        }
        .onChange(of: query) { _, newValue in
            engine.search(query: newValue, dictionaryID: selectedDictionaryID)
        }
        .onChange(of: selectedDictionaryID) { _, _ in
            engine.search(query: query, dictionaryID: selectedDictionaryID)
        }
    }

    private var dictionaryContent: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            results
            dictionaryStatusBar
        }
    }

    @ViewBuilder
    private var dictionaryStatusBar: some View {
        if let message = engine.statusMessage {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(StudyMateMediaStyle.panelBackground)
        } else if let error = engine.lastError {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.primary)
                Spacer()
                Button(lang.text("清除", "Dismiss")) {
                    engine.clearError()
                }
                .buttonStyle(.borderless)
                .font(.caption2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(StudyMateMediaStyle.panelBackground)
        }
    }

    private var dictionarySidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(lang.text("词典", "Dictionaries"), systemImage: "book.closed")
                    .font(.headline)
                Spacer()
                Button(action: importDictionary) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help(lang.text("导入 MDX/MDD 词典", "Import an MDX/MDD dictionary"))
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            List(selection: $selectedDictionaryID) {
                Text(lang.text("全部词典", "All dictionaries"))
                    .tag(String?.none)
                ForEach(engine.dictionaries) { dictionary in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dictionary.title)
                            .lineLimit(1)
                        Text("\(dictionary.entryCount) \(lang.text("词条", "entries"))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .tag(Optional(dictionary.id))
                    .contextMenu {
                        Button(role: .destructive) {
                            dictionaryPendingDeletion = dictionary
                        } label: {
                            Label(lang.text("删除词典", "Delete Dictionary"), systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            if let selectedDictionaryID,
               let selectedDict = engine.dictionaries.first(where: { $0.id == selectedDictionaryID }) {
                HStack {
                    Button(role: .destructive) {
                        dictionaryPendingDeletion = selectedDict
                    } label: {
                        Label(lang.text("删除词典", "Delete Dictionary"), systemImage: "trash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(lang.text("删除当前选中的词典", "Delete selected dictionary"))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }

            if engine.isBusy {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(engine.progressPhase ?? lang.text("正在处理词典…", "Processing dictionary…"))
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    if let fraction = engine.progress {
                        ProgressView(value: fraction, total: 1.0)
                            .progressViewStyle(.linear)
                        HStack {
                            Spacer()
                            Text("\(Int(fraction * 100))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                lang.text("输入单词或短语", "Search a word or phrase"),
                text: $query
            )
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .onSubmit {
                engine.search(query: query, dictionaryID: selectedDictionaryID)
            }
            if !query.isEmpty {
                Button {
                    query = ""
                    engine.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            Menu {
                Text(selectedTitle)
                Divider()
                Button(lang.text("全部词典", "All dictionaries")) {
                    selectedDictionaryID = nil
                }
                ForEach(engine.dictionaries) { dictionary in
                    Button(dictionary.title) {
                        selectedDictionaryID = dictionary.id
                    }
                }
            } label: {
                Label(selectedTitle, systemImage: "book")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var results: some View {
        if let error = engine.lastError {
            VStack(alignment: .leading, spacing: 10) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                Button(lang.text("关闭提示", "Dismiss")) {
                    engine.clearError()
                }
                .buttonStyle(.borderless)
            }
            .padding(20)
            Spacer()
        } else if engine.dictionaries.isEmpty {
            if engine.isBusy {
                VStack(spacing: 16) {
                    ProgressView(value: engine.progress ?? 0, total: 1.0)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 280)
                    Text(engine.progressPhase ?? lang.text("正在导入词典…", "Importing dictionary…"))
                        .font(.headline)
                    if let progress = engine.progress {
                        Text("\(Int(progress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text(lang.text("还没有词典", "No dictionaries yet"))
                        .font(.headline)
                    Text(lang.text(
                        "点击左侧加号导入 .mdx；同目录的 .mdd 会自动作为资源导入。",
                        "Use the + button to import an .mdx file. Matching .mdd files can be selected as resources."
                    ))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 430)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "character.book.closed")
                    .font(.system(size: 38))
                    .foregroundStyle(.secondary)
                Text(lang.text("输入单词开始查询", "Enter a word to search"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if engine.searchResults.isEmpty {
            ContentUnavailableView(
                lang.text("没有匹配结果", "No matches"),
                systemImage: "magnifyingglass",
                description: Text(lang.text("尝试更短的关键词或切换词典。", "Try a shorter query or another dictionary."))
            )
        } else {
            DictionaryHTMLView(
                entries: engine.searchResults,
                isCompact: false,
                onLookupWord: { word in
                    query = word
                    engine.search(query: word, dictionaryID: selectedDictionaryID)
                },
                onPlayAudio: { audioKey in
                    DictionaryInteractionCoordinator.shared.speak(audioKey)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func importDictionary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "mdx") ?? .data,
            UTType(filenameExtension: "mdd") ?? .data
        ]
        guard panel.runModal() == .OK else { return }
        let mdxFiles = panel.urls.filter { $0.pathExtension.lowercased() == "mdx" }
        guard let mdx = mdxFiles.first else {
            engine.reportError(lang.text("请选择至少一个 MDX 文件。", "Select at least one MDX file."))
            return
        }
        var mdd = panel.urls.filter { $0.pathExtension.lowercased() == "mdd" }
        if mdd.isEmpty {
            let sibling = mdx.deletingPathExtension().appendingPathExtension("mdd")
            if FileManager.default.fileExists(atPath: sibling.path) {
                mdd = [sibling]
            }
        }
        engine.importDictionary(mdx: mdx, mdd: mdd)
    }
}

#Preview("StudyMate Dictionary") {
    DictionaryView()
        .frame(width: 900, height: 600)
}
