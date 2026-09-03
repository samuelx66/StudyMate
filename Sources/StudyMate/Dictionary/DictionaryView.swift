import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Resolves the row that should be selected for a query without depending on
/// SwiftUI view timing. Exact keys win over prefix matches, while a selected
/// dictionary scopes the candidates before matching. In “All” mode the
/// returned hit remains the source of truth for the owning dictionary.
enum DictionaryCandidateSelection {
    static func resolve(
        query: String,
        candidates: [StudyMateDictionarySearchHit],
        dictionaryID: String?
    ) -> StudyMateDictionarySearchHit? {
        let scoped = candidates.filter { dictionaryID == nil || $0.dictionaryID == dictionaryID }
        guard !scoped.isEmpty else { return nil }

        let canonicalQuery = canonicalKey(query)
        // Preserve the dictionary's original key casing when the MDX contains
        // both variants (for example `Relate` and `relate`). This must happen
        // before the case-insensitive fallback, otherwise a short proper-name
        // entry can hide the full ordinary-word definition.
        if let exactCase = scoped.first(where: { canonicalKey($0.key) == canonicalQuery }) {
            return exactCase
        }
        let normalizedQuery = normalizedKey(query)
        return scoped.first(where: { normalizedKey($0.key) == normalizedQuery }) ?? scoped.first
    }

    static func canonicalKey(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func normalizedKey(_ value: String) -> String {
        canonicalKey(value)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

private struct DictionaryDefinitionSkeleton: View {
    @ObservedObject private var lang = LanguageManager.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.10))
                .frame(width: 190, height: 22)
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(index == 0 ? 0.09 : 0.06))
                    .frame(maxWidth: index == 2 ? 320 : .infinity, minHeight: 13, maxHeight: 13)
            }
            Text(lang.text("正在加载释义…", "Loading definition…"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Spacer()
        }
        .padding(24)
        .redacted(reason: .placeholder)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 释义详情展示面板 (Definition Content View)
@MainActor
private struct DictionaryDefinitionPane: View {
    @ObservedObject var engine: DictionaryEngine
    @ObservedObject private var lang = LanguageManager.shared
    @ObservedObject private var dictionaryAppearanceSettings = DictionaryAppearanceSettings.shared
    let query: String
    let selectedResultID: String?
    let selectedDictionaryID: String?
    @Binding var textScale: CGFloat
    let onLookupWord: (String) -> Void
    let onPlayAudio: (String) -> Void

    private var selectedEntries: [StudyMateDictionaryLookup] {
        guard let selectedResultID,
              let selectedHit = engine.searchHits.first(where: { $0.id == selectedResultID }),
              !selectedHit.key.isEmpty else { return engine.searchResults }
        let selectedResultKey = selectedHit.key
        let matches = engine.searchResults.filter {
            $0.key.compare(selectedResultKey, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        let candidates = matches.isEmpty ? engine.searchResults : matches
        if let selectedDictionaryID {
            return candidates.filter { $0.dictionaryID == selectedDictionaryID }
        }
        return candidates
    }

    var body: some View {
        Group {
            if let error = engine.lastError, engine.searchHits.isEmpty, !engine.isBusy, !engine.isSearching {
                VStack(alignment: .leading, spacing: 10) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(StudyMateMediaStyle.warning)
                        .textSelection(.enabled)
                    Button(lang.text("关闭提示", "Dismiss")) { engine.clearError() }
                        .buttonStyle(.borderless)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if engine.dictionaries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                    Text(lang.text("还没有词典", "No dictionaries yet")).font(.headline)
                    Text(lang.text("点击右上角菜单导入 .mdx 文件；同目录的 .mdd 会作为资源一同导入。", "Use the menu in the top-right to import .mdx files. Matching .mdd files will be included automatically."))
                        .multilineTextAlignment(.center)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 420)
                    if engine.isBusy {
                        ProgressView(value: engine.progress ?? 0, total: 1)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 260)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "book.pages")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text(lang.text("输入单词开始查询", "Enter a word to search"))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if engine.searchHits.isEmpty {
                if engine.isSearching || engine.isLoadingDefinition {
                    DictionaryDefinitionSkeleton()
                } else {
                    ContentUnavailableView(lang.text("没有匹配结果", "No matches"), systemImage: "magnifyingglass", description: Text(lang.text("尝试更短的关键词或切换词典。", "Try a shorter query or another dictionary.")))
                }
            } else if selectedEntries.isEmpty {
                if engine.isLoadingDefinition {
                    DictionaryDefinitionSkeleton()
                } else if let error = engine.lastError {
                    Text(error)
                        .foregroundStyle(StudyMateMediaStyle.warning)
                        .textSelection(.enabled)
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ContentUnavailableView(lang.text("当前词典无此词释义", "No definition in selected dictionary"), systemImage: "book.closed", description: Text(lang.text("可尝试切换到“全部”或其他词典。", "Try switching to “All” or another dictionary.")))
                }
            } else {
                DictionaryHTMLView(
                    entries: selectedEntries,
                    isCompact: false,
                    allowsJavaScript: true,
                    textScale: textScale,
                    adaptsToSystemAppearance: dictionaryAppearanceSettings.adaptsToSystemAppearance,
                    onLookupWord: onLookupWord,
                    onPlayAudio: onPlayAudio,
                    onPlayDictionaryAudio: { dictionaryID, key in
                        DictionaryInteractionCoordinator.shared.playDictionaryAudio(
                            dictionaryID: dictionaryID,
                            key: key
                        )
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// macOS 26 原生词典工作台 (100% Native NavigationSplitView & macOS 26 Toolbar)
@MainActor
public struct DictionaryView: View {
    @StateObject private var engine: DictionaryEngine
    @ObservedObject private var lang = LanguageManager.shared
    @State private var query = ""
    @State private var selectedDictionaryID: String?
    @State private var selectedResultID: String?
    @State private var dictionaryPendingDeletion: StudyMateDictionarySummary?
    @State private var textScale: CGFloat = 1.0
    @State private var queryHistory: [String] = []
    @State private var historyIndex = -1
    @State private var isApplyingHistory = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    @MainActor
    public init() {
        self.init(engine: .shared)
    }

    @MainActor
    public init(engine: DictionaryEngine) {
        _engine = StateObject(wrappedValue: engine)
    }

    private var resultItems: [StudyMateDictionarySearchHit] {
        return engine.searchHits.filter { entry in
            let normalized = entry.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { return false }
            return true
        }
    }

    private var canGoBack: Bool {
        historyIndex > 0 && historyIndex < queryHistory.count
    }

    private var canGoForward: Bool {
        historyIndex >= 0 && historyIndex + 1 < queryHistory.count
    }

    private var activeSelectedDictionary: StudyMateDictionarySummary? {
        guard let selectedDictionaryID else { return nil }
        return engine.dictionaries.first { $0.id == selectedDictionaryID }
    }

    private var subtitleText: String {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return lang.text("查找单词", "Search a word")
        }
        if engine.isSearching {
            return lang.text("正在查找…", "Searching…")
        }
        if let original = engine.lemmaOriginalQuery,
           let resolved = engine.definitionQuery,
           resolved.caseInsensitiveCompare(original) != .orderedSame {
            return lang.text("找到 \(resultItems.count) 个（词形还原：\(resolved)）", "\(resultItems.count) matches (base form: \(resolved))")
        }
        return lang.text("找到 \(resultItems.count) 个", "\(resultItems.count) matches")
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // 1. 左侧原生侧边栏 (macOS 26 Native Sidebar List)
            sidebarList
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } detail: {
            // 2. 右侧主体 (macOS 26 Native Detail + Toolbar)
            VStack(spacing: 0) {
                // 横向词典来源切换栏
                sourceTabsBar

                // 词条详情正文 (WebKit HTML)
                DictionaryDefinitionPane(
                    engine: engine,
                    query: query,
                    selectedResultID: selectedResultID,
                    selectedDictionaryID: selectedDictionaryID,
                    textScale: $textScale,
                    onLookupWord: { word in
                        let oldQuery = query
                        query = word
                        recordQuery(word)
                        // The query change handler owns ordinary full-window
                        // searches. Force a search only when a dictionary
                        // link resolves to the same visible query; otherwise
                        // the previous implementation issued a key search,
                        // an all-details lookup, and then another definition
                        // lookup for the first selected row.
                        if oldQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                            .caseInsensitiveCompare(word.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame {
                            selectedResultID = nil
                            engine.search(query: word, dictionaryID: selectedDictionaryID, immediate: true)
                        }
                    },
                    onPlayAudio: { audioKey in
                        DictionaryInteractionCoordinator.shared.speakPreferred(audioKey)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 底部状态栏反馈
                dictionaryStatusBarNative
            }
            .navigationTitle(lang.text("词典", "Dictionary"))
            .navigationSubtitle(subtitleText)
            .toolbar {
                // 历史导航组
                ToolbarItemGroup(placement: .navigation) {
                    ControlGroup {
                        Button(action: goBack) {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(!canGoBack)
                        .accessibilityLabel(lang.text("上一个查询", "Previous search"))
                        .help(lang.text("显示上一个查询", "Show previous search"))

                        Button(action: goForward) {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(!canGoForward)
                        .accessibilityLabel(lang.text("下一个查询", "Next search"))
                        .help(lang.text("显示下一个查询", "Show next search"))
                    }
                }

                // 字号缩放器 [ 小 | 大 ]
                ToolbarItem(placement: .primaryAction) {
                    ControlGroup {
                        Button {
                            textScale = max(0.7, textScale - 0.1)
                        } label: {
                            Text(lang.text("小", "A-"))
                        }
                        .help(lang.text("缩小释义文字", "Decrease definition text size"))

                        Button {
                            textScale = min(1.8, textScale + 0.1)
                        } label: {
                            Text(lang.text("大", "A+"))
                        }
                        .help(lang.text("放大释义文字", "Increase definition text size"))
                    }
                }

                // 词典管理菜单
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(action: importDictionary) {
                            Label(lang.text("导入 MDX/MDD 词典…", "Import MDX/MDD Dictionary…"), systemImage: "plus")
                        }
                        if let activeSelectedDictionary {
                            Divider()
                            Button(role: .destructive) {
                                dictionaryPendingDeletion = activeSelectedDictionary
                            } label: {
                                Label(lang.text("删除“\(activeSelectedDictionary.title)”", "Delete “\(activeSelectedDictionary.title)”"), systemImage: "trash")
                            }
                            .disabled(engine.isBusy)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(lang.text("词典管理", "Dictionary management"))
                    .help(lang.text("词典管理", "Dictionary Management"))
                }
            }
            .searchable(
                text: $query,
                placement: .toolbar,
                prompt: Text(lang.text("搜索单词或短语", "Search a word or phrase"))
            )
            .onSubmit(of: .search) {
                recordQuery(query)
                engine.search(
                    query: query,
                    dictionaryID: selectedDictionaryID,
                    immediate: true
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 880, minHeight: 580)
        .alert(
            lang.text("确认删除词典？", "Delete Dictionary?"),
            isPresented: Binding(
                get: { dictionaryPendingDeletion != nil },
                set: { if !$0 { dictionaryPendingDeletion = nil } }
            ),
            presenting: dictionaryPendingDeletion
        ) { dict in
            Button(lang.text("删除", "Delete"), role: .destructive) {
                confirmDeletion(of: dict.id)
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
                applyRequestedLookup(pending)
            }
        }
        .onChange(of: engine.lookupRequestID) { _, _ in
            guard let pending = engine.consumeRequestedQuery() else { return }
            applyRequestedLookup(pending)
        }
        .onChange(of: engine.dictionaries) { _, newDicts in
            if let sel = selectedDictionaryID, !newDicts.contains(where: { $0.id == sel }) {
                selectedDictionaryID = nil
            }
        }
        .onChange(of: engine.searchHits) { _, _ in
            synchronizeSelectedCandidate()
        }
        .onChange(of: engine.searchRevision) { _, _ in
            // A repeated query can publish an array equal to the previous
            // one, which does not trigger the array-based onChange above.
            // The revision is the search lifecycle signal, so selection is
            // also synchronized whenever a search completes.
            synchronizeSelectedCandidate()
        }
        .onChange(of: selectedResultID) { _, newID in
            guard let newID,
                  let selected = resultItems.first(where: { $0.id == newID }) else { return }
            // 在“全部”模式（selectedDictionaryID 为 nil）下，向 loadDefinition 传入 nil
            // 从而触发底层 lookupAll，聚合加载所有已导入词典中该词的完整释义。
            engine.loadDefinition(
                for: selected.key,
                dictionaryID: selectedDictionaryID
            )
        }
        .onChange(of: query) { _, newValue in
            if !isApplyingHistory {
                selectedResultID = nil
            }
            engine.search(query: newValue, dictionaryID: selectedDictionaryID)
        }
        .onChange(of: selectedDictionaryID) { _, _ in
            // Candidate rows are scoped by dictionary in the Rust query. A
            // source switch must therefore run a new key search instead of
            // reusing rows from the previous source and only reloading its
            // selected definition.
            selectedResultID = nil
            engine.search(
                query: query,
                dictionaryID: selectedDictionaryID,
                immediate: true
            )
        }
        .onDisappear {
            DictionaryInteractionCoordinator.shared.dictionaryWindowDidClose()
        }
    }

    // 1. 原生 Sidebar 词条列表
    @ViewBuilder
    private var sidebarList: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "character.book.closed")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text(lang.text("输入单词开始查询", "Enter a word to search"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if resultItems.isEmpty && !engine.isSearching {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text(lang.text("未找到匹配项", "No matches found"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(resultItems, id: \.id, selection: $selectedResultID) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.key)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if selectedDictionaryID == nil {
                        Text(item.dictionaryTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .tag(item.id)
            }
            .listStyle(.sidebar)
        }
    }

    // 2. 词典来源标签栏
    private var sourceTabsBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    tabItem(id: nil, title: lang.text("全部", "All"))
                    ForEach(Array(engine.dictionaries.prefix(8))) { dictionary in
                        tabItem(id: dictionary.id, title: dictionary.title)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
            }

            if engine.dictionaries.count > 8 {
                Menu {
                    ForEach(Array(engine.dictionaries.dropFirst(8))) { dictionary in
                        Button {
                            selectedDictionaryID = dictionary.id
                        } label: {
                            Label(dictionary.title, systemImage: selectedDictionaryID == dictionary.id ? "checkmark" : "book.closed")
                        }
                    }
                } label: {
                    Image(systemName: "chevron.right.2")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .padding(.trailing, 12)
                .help(lang.text("更多词典", "More dictionaries"))
            }
        }
        .frame(height: 34)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func tabItem(id: String?, title: String) -> some View {
        let isSelected = selectedDictionaryID == id
        return Button {
            selectedDictionaryID = id
        } label: {
            Text(title)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.10))
            }
        }
        .help(title)
    }

    @ViewBuilder
    private var dictionaryStatusBarNative: some View {
        if engine.isBusy || engine.statusMessage != nil || engine.lastError != nil {
            Divider()
            HStack(spacing: 7) {
                Spacer(minLength: 0)
                if engine.isBusy {
                    ProgressView()
                        .controlSize(.small)
                    Text(engine.progressPhase ?? lang.text("正在处理词典…", "Processing dictionary…"))
                        .lineLimit(1)
                } else if let message = engine.statusMessage {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(StudyMateMediaStyle.success)
                    Text(message)
                        .lineLimit(1)
                } else if let error = engine.lastError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(StudyMateMediaStyle.warning)
                    Text(error)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                if let fraction = engine.progress, engine.isBusy {
                    Text("\(Int(fraction * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button {
                    engine.clearError()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help(lang.text("关闭提示", "Dismiss message"))
            }
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    private func recordQuery(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isApplyingHistory else { return }
        if historyIndex >= 0, historyIndex < queryHistory.count,
           queryHistory[historyIndex].caseInsensitiveCompare(trimmed) == .orderedSame {
            return
        }
        if historyIndex + 1 < queryHistory.count {
            queryHistory.removeSubrange((historyIndex + 1)..<queryHistory.count)
        }
        queryHistory.append(trimmed)
        historyIndex = queryHistory.count - 1
    }

    private func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        applyHistoryQuery(queryHistory[historyIndex])
    }

    private func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        applyHistoryQuery(queryHistory[historyIndex])
    }

    private func applyHistoryQuery(_ value: String) {
        isApplyingHistory = true
        query = value
        selectedResultID = nil
        isApplyingHistory = false
    }

    private func applyRequestedLookup(_ pending: String) {
        let clean = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        recordQuery(clean)
        isApplyingHistory = true
        query = clean
        selectedResultID = nil
        isApplyingHistory = false
        // Opening the standalone window is an explicit lookup lifecycle
        // event. Start a fresh key search even when the popover already left
        // the same hits/results in the shared engine; the search revision
        // below will select the exact candidate when the response arrives.
        engine.search(
            query: clean,
            dictionaryID: selectedDictionaryID,
            immediate: true
        )
    }

    private func synchronizeSelectedCandidate() {
        let candidates = resultItems
        guard let candidate = DictionaryCandidateSelection.resolve(
            query: query,
            candidates: candidates,
            dictionaryID: selectedDictionaryID
        ) else {
            if selectedResultID != nil {
                selectedResultID = nil
            }
            return
        }

        let selectedCandidate = candidates.first { $0.id == selectedResultID }
        let selectedCandidateIsInScope = selectedCandidate.map {
            selectedDictionaryID == nil || $0.dictionaryID == selectedDictionaryID
        } ?? false
        if !selectedCandidateIsInScope {
            selectedResultID = candidate.id
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
        guard mdxFiles.count == 1 else {
            engine.reportError(lang.text(
                "一次只能导入一个 MDX 文件；可同时选择它配套的多个 MDD 分卷。",
                "Import one MDX file at a time; you may select all of its MDD volumes together."
            ))
            return
        }
        let explicitlySelectedMDDs = panel.urls.filter { $0.pathExtension.lowercased() == "mdd" }
        // Always merge the user's explicit selection with conventional sibling
        // volumes. Users often select the first MDD manually while the later
        // `.1.mdd`, `.2.mdd` volumes remain unselected in the panel.
        let discoveredMDDs = matchingMDDs(for: mdx)
        let mdd = mergeMDDs(explicitlySelectedMDDs, with: discoveredMDDs, for: mdx)
        engine.importDictionary(mdx: mdx, mdd: mdd)
    }

    /// MDict dictionaries commonly split their resources into
    /// `<name>.mdd`, `<name>.1.mdd`, ... files. Keep explicit user selections
    /// untouched, but when only the MDX is selected automatically collect all
    /// matching resource volumes in a deterministic order.
    private func matchingMDDs(for mdx: URL) -> [URL] {
        let fileManager = FileManager.default
        let directory = mdx.deletingLastPathComponent()
        let baseName = mdx.deletingPathExtension().lastPathComponent
        let lowerBaseName = baseName.lowercased()

        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            // A security-scoped MDX URL does not always grant enumeration of
            // its parent directory. Probe conventional volumes directly so
            // TLD.1.mdd and later volumes are still imported.
            return (0...64).compactMap { number in
                let filename = number == 0
                    ? "\(baseName).mdd"
                    : "\(baseName).\(number).mdd"
                let candidate = directory.appendingPathComponent(filename)
                return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
            }
        }

        let conventionalMatches = urls
            .compactMap { url -> (url: URL, order: Int)? in
                guard url.pathExtension.lowercased() == "mdd",
                      let isRegularFile = try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                      isRegularFile == true else { return nil }
                let stem = url.deletingPathExtension().lastPathComponent
                let lowerStem = stem.lowercased()
                if lowerStem == lowerBaseName {
                    return (url, 0)
                }
                let prefix = lowerBaseName + "."
                guard lowerStem.hasPrefix(prefix),
                      let order = Int(lowerStem.dropFirst(prefix.count)),
                      order >= 0 else { return nil }
                return (url, order + 1)
            }
            .sorted { lhs, rhs in
                if lhs.order != rhs.order { return lhs.order < rhs.order }
                return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
            }
            .map { $0.url }

        if !conventionalMatches.isEmpty {
            return conventionalMatches
        }

        // A few MDX packages keep their resources in a descriptive MDD name
        // such as `resources.mdd` instead of matching the MDX stem. When no
        // conventional volume exists, include same-directory MDD files so
        // scripts can resolve dependencies such as jQuery and dictionary
        // configuration. This fallback is intentionally disabled when normal
        // volumes were found to avoid importing unrelated dictionaries.
        return urls
            .filter { $0.pathExtension.lowercased() == "mdd" }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
    }

    private func mergeMDDs(_ explicit: [URL], with discovered: [URL], for mdx: URL) -> [URL] {
        let baseName = mdx.deletingPathExtension().lastPathComponent
        var unique: [URL] = []
        var seen = Set<String>()
        for url in discovered + explicit {
            guard url.pathExtension.caseInsensitiveCompare("mdd") == .orderedSame else { continue }
            let identity = url.resolvingSymlinksInPath().standardizedFileURL.path
            let normalizedIdentity = identity.precomposedStringWithCanonicalMapping.lowercased()
            guard seen.insert(normalizedIdentity).inserted else { continue }
            unique.append(url)
        }

        let lowerBaseName = baseName.lowercased()
        return unique.sorted { lhs, rhs in
            let lhsOrder = mddVolumeOrder(lhs, baseName: lowerBaseName)
            let rhsOrder = mddVolumeOrder(rhs, baseName: lowerBaseName)
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            let comparison = lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
            return comparison == .orderedAscending ||
                (comparison == .orderedSame && lhs.path < rhs.path)
        }
    }

    private func mddVolumeOrder(_ url: URL, baseName: String) -> Int {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        guard !baseName.isEmpty else { return Int.max }
        if stem == baseName { return 0 }
        let prefix = baseName + "."
        guard stem.hasPrefix(prefix),
              let number = Int(stem.dropFirst(prefix.count)),
              number >= 0 else { return Int.max }
        return number + 1
    }

    @MainActor
    private func confirmDeletion(of id: String) {
        dictionaryPendingDeletion = nil
        if selectedDictionaryID == id {
            selectedDictionaryID = nil
        }
        let dictionaryEngine = engine
        Task { @MainActor in
            await Task.yield()
            dictionaryEngine.deleteDictionary(id: id)
        }
    }
}

#Preview("StudyMate Dictionary") {
    DictionaryView()
        .frame(width: 1000, height: 680)
}
