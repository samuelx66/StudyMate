import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// NSTextField exposes marked-text state during CJK IME composition. Binding
/// only committed changes prevents a half-composed syllable from starting a
/// dictionary query and then being immediately replaced by the IME.
private struct DictionarySearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        let onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            onSubmit()
            return true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(frame: .zero)
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.placeholderString = placeholder
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() != true, field.stringValue != text {
            field.stringValue = text
        }
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

@MainActor
private struct DictionaryResultListPane: View {
    @ObservedObject var engine: DictionaryEngine
    @ObservedObject private var lang = LanguageManager.shared
    let query: String
    @Binding var selectedResultKey: String?

    private var resultItems: [StudyMateDictionarySearchHit] {
        var seen = Set<String>()
        return engine.searchHits.filter { item in
            let normalized = item.key.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
            return !normalized.isEmpty && seen.insert(normalized).inserted
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(lang.text("搜索结果", "Results"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if engine.isSearching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider()

            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 25))
                        .foregroundStyle(.secondary)
                    Text(lang.text("输入单词开始查询", "Enter a word to search"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if resultItems.isEmpty && !engine.isSearching {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 25))
                        .foregroundStyle(.secondary)
                    Text(lang.text("没有匹配结果", "No matches"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedResultKey) {
                    ForEach(resultItems, id: \.key) { item in
                        Text(item.key)
                            .font(.system(size: 14))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .tag(Optional(item.key))
                            .contentShape(Rectangle())
                            .onTapGesture { selectedResultKey = item.key }
                    }
                }
                .listStyle(.sidebar)
                .disabled(engine.isSearching)
            }
        }
        .background(Color.primary.opacity(0.025))
    }
}

@MainActor
private struct DictionaryDefinitionPane: View {
    @ObservedObject var engine: DictionaryEngine
    @ObservedObject private var lang = LanguageManager.shared
    let query: String
    let selectedResultKey: String?
    let textScale: CGFloat
    let onLookupWord: (String) -> Void
    let onPlayAudio: (String) -> Void

    private var selectedEntries: [StudyMateDictionaryLookup] {
        guard let selectedResultKey, !selectedResultKey.isEmpty else { return engine.searchResults }
        let matches = engine.searchResults.filter {
            $0.key.compare(selectedResultKey, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        return matches.isEmpty ? engine.searchResults : matches
    }

    var body: some View {
        Group {
            if let error = engine.lastError, engine.searchHits.isEmpty, !engine.isBusy, !engine.isSearching {
                VStack(alignment: .leading, spacing: 10) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    Button(lang.text("关闭提示", "Dismiss")) { engine.clearError() }
                        .buttonStyle(.borderless)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if engine.dictionaries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text(lang.text("还没有词典", "No dictionaries yet")).font(.headline)
                    Text(lang.text("使用右上角菜单导入 .mdx；同目录的 .mdd 可以作为资源一同导入。", "Use the menu above to import an .mdx file. Matching .mdd files can be added as resources."))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 430)
                    if engine.isBusy {
                        ProgressView(value: engine.progress ?? 0, total: 1)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 300)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "book.pages")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(lang.text("输入单词开始查询", "Enter a word to search"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if engine.searchHits.isEmpty {
                if engine.isSearching || engine.isLoadingDefinition {
                    DictionaryDefinitionSkeleton()
                } else {
                    ContentUnavailableView(lang.text("没有匹配结果", "No matches"), systemImage: "magnifyingglass", description: Text(lang.text("尝试更短的关键词或切换词典。", "Try a shorter query or another dictionary.")))
                }
            } else if engine.searchResults.isEmpty {
                if engine.isLoadingDefinition {
                    DictionaryDefinitionSkeleton()
                } else if let error = engine.lastError {
                    Text(error)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ContentUnavailableView(lang.text("没有释义", "No definition"), systemImage: "book.closed", description: Text(lang.text("请选择左侧词条。", "Select a result on the left.")))
                }
            } else {
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(selectedResultKey ?? engine.definitionQuery ?? query)
                            .font(.title2.weight(.semibold))
                        if selectedEntries.count > 1 {
                            Text(lang.text("来自 \(selectedEntries.count) 本词典", "From \(selectedEntries.count) dictionaries"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 2)
                    DictionaryHTMLView(
                        entries: selectedEntries,
                        isCompact: false,
                        textScale: textScale,
                        onLookupWord: onLookupWord,
                        onPlayAudio: onPlayAudio
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

/// First-version dictionary window. It is intentionally independent of the
/// media player: the same Rust engine can later be hosted by mobile clients.
@MainActor
public struct DictionaryView: View {
    @StateObject private var engine: DictionaryEngine
    @ObservedObject private var lang = LanguageManager.shared
    @State private var query = ""
    @State private var selectedDictionaryID: String?
    @State private var selectedResultKey: String?
    @State private var dictionaryPendingDeletion: StudyMateDictionarySummary?
    @State private var textScale: CGFloat = 1.0
    @State private var queryHistory: [String] = []
    @State private var historyIndex = -1
    @State private var isApplyingHistory = false

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
            return lang.text("全部", "All")
        }
        return engine.dictionaries.first(where: { $0.id == selectedDictionaryID })?.title
            ?? lang.text("全部", "All")
    }

    /// Search results contain one row per dictionary. The native Dictionary
    /// layout presents a key-oriented list, while keeping all matching
    /// definitions in the detail pane.
    private var resultItems: [StudyMateDictionarySearchHit] {
        var seen = Set<String>()
        return engine.searchHits.filter { entry in
            let normalized = entry.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { return false }
            return seen.insert(normalized).inserted
        }
    }

    private var selectedDefinitionEntries: [StudyMateDictionaryLookup] {
        guard let selectedResultKey, !selectedResultKey.isEmpty else {
            return engine.searchResults
        }
        let matches = engine.searchResults.filter {
            $0.key.compare(selectedResultKey, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        return matches.isEmpty ? engine.searchResults : matches
    }

    private var canGoBack: Bool {
        historyIndex > 0 && historyIndex < queryHistory.count
    }

    private var canGoForward: Bool {
        historyIndex >= 0 && historyIndex + 1 < queryHistory.count
    }

    public var body: some View {
        VStack(spacing: 0) {
            dictionaryToolbar
            sourceFilterBar
            Divider()

            HSplitView {
                DictionaryResultListPane(
                    engine: engine,
                    query: query,
                    selectedResultKey: $selectedResultKey
                )
                    .frame(minWidth: 190, idealWidth: 250, maxWidth: 340)
                DictionaryDefinitionPane(
                    engine: engine,
                    query: query,
                    selectedResultKey: selectedResultKey,
                    textScale: textScale,
                    onLookupWord: { word in
                        query = word
                        recordQuery(word)
                        engine.search(query: word, dictionaryID: selectedDictionaryID, includeDetails: true, immediate: true)
                    },
                    onPlayAudio: { audioKey in
                        DictionaryInteractionCoordinator.shared.speak(audioKey)
                    }
                )
                    .frame(minWidth: 460)
            }

            dictionaryStatusBarNative
        }
        .frame(minWidth: 900, minHeight: 600)
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
                query = pending
            }
        }
        .onChange(of: engine.requestedQuery) { _, pending in
            guard let pending else { return }
            query = pending
            _ = engine.consumeRequestedQuery()
        }
        .onChange(of: engine.dictionaries) { _, newDicts in
            if let sel = selectedDictionaryID, !newDicts.contains(where: { $0.id == sel }) {
                selectedDictionaryID = nil
            }
        }
        .onChange(of: engine.searchHits) { _, newHits in
            let keys = newHits.map(\.key)
            if let selectedResultKey,
               keys.contains(where: { $0.compare(selectedResultKey, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
                return
            }
            selectedResultKey = resultItems.first?.key
        }
        .onChange(of: selectedResultKey) { _, newKey in
            guard let newKey else { return }
            engine.loadDefinition(for: newKey, dictionaryID: selectedDictionaryID)
        }
        .onChange(of: query) { _, newValue in
            if !isApplyingHistory {
                selectedResultKey = nil
            }
            engine.search(query: newValue, dictionaryID: selectedDictionaryID)
        }
        .onChange(of: selectedDictionaryID) { _, _ in
            selectedResultKey = nil
            engine.search(query: query, dictionaryID: selectedDictionaryID)
        }
    }

    private var dictionaryToolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .disabled(!canGoBack)
                .help(lang.text("显示上一个查询", "Show previous search"))

                Button(action: goForward) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .disabled(!canGoForward)
                .help(lang.text("显示下一个查询", "Show next search"))
            }
            .padding(3)
            .background(Color.primary.opacity(0.06), in: Capsule())

            Divider()
                .frame(height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(lang.text("词典", "Dictionary"))
                    .font(.headline)
                Text(resultCountTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 105, alignment: .leading)

            Spacer(minLength: 8)

            HStack(spacing: 0) {
                Button {
                    textScale = max(0.8, textScale - 0.1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .frame(width: 27, height: 27)
                }
                .buttonStyle(.borderless)
                .help(lang.text("缩小释义文字", "Decrease definition text size"))

                Divider()
                    .frame(height: 18)

                Button {
                    textScale = min(1.4, textScale + 0.1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .frame(width: 27, height: 27)
                }
                .buttonStyle(.borderless)
                .help(lang.text("放大释义文字", "Increase definition text size"))
            }
            .padding(.horizontal, 4)
            .background(Color.primary.opacity(0.06), in: Capsule())

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                DictionarySearchField(
                    text: $query,
                    placeholder: lang.text("搜索单词或短语", "Search a word or phrase"),
                    onSubmit: {
                        recordQuery(query)
                        engine.search(
                            query: query,
                            dictionaryID: selectedDictionaryID,
                            immediate: true
                        )
                    }
                )
                .frame(height: 20)
                if !query.isEmpty {
                    Button {
                        query = ""
                        selectedResultKey = nil
                        engine.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(lang.text("清除搜索", "Clear search"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: 285)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.09), lineWidth: 0.5))

            Menu {
                Button(action: importDictionary) {
                    Label(lang.text("导入 MDX/MDD 词典", "Import MDX/MDD dictionary"), systemImage: "plus")
                }
                if let selectedDictionaryID,
                   let dictionary = engine.dictionaries.first(where: { $0.id == selectedDictionaryID }) {
                    Divider()
                    Button(role: .destructive) {
                        dictionaryPendingDeletion = dictionary
                    } label: {
                        Label(lang.text("删除“\(dictionary.title)”", "Delete “\(dictionary.title)”"), systemImage: "trash")
                    }
                    .disabled(engine.isBusy)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17))
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .help(lang.text("词典管理", "Dictionary management"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial)
    }

    private var resultCountTitle: String {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return lang.text("查找单词", "Search a word")
        }
        if engine.isSearching {
            return lang.text("正在查找…", "Searching…")
        }
        return lang.text("找到 \(resultItems.count) 个结果", "\(resultItems.count) results")
    }

    private var sourceFilterBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    sourceChip(id: nil, title: lang.text("全部", "All"))
                    ForEach(engine.dictionaries) { dictionary in
                        sourceChip(id: dictionary.id, title: dictionary.title)
                    }
                }
                .padding(.horizontal, 12)
            }

            if engine.dictionaries.count > 5 {
                Image(systemName: "chevron.right.2")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 12)
            }
        }
        .frame(height: 38)
        .background(StudyMateMediaStyle.windowBackground)
    }

    private func sourceChip(id: String?, title: String) -> some View {
        let isSelected = selectedDictionaryID == id
        return Button {
            selectedDictionaryID = id
        } label: {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(isSelected ? Color.primary.opacity(0.13) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private var resultList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(lang.text("搜索结果", "Results"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if engine.isSearching {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            Divider()

            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 25))
                        .foregroundStyle(.secondary)
                    Text(lang.text("输入单词开始查询", "Enter a word to search"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if resultItems.isEmpty && !engine.isSearching {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 25))
                        .foregroundStyle(.secondary)
                    Text(lang.text("没有匹配结果", "No matches"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedResultKey) {
                    ForEach(resultItems, id: \.key) { item in
                        Text(item.key)
                            .font(.system(size: 14))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .tag(Optional(item.key))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedResultKey = item.key
                            }
                    }
                }
                .listStyle(.sidebar)
                .disabled(engine.isSearching)
            }
        }
        .background(Color.primary.opacity(0.025))
    }

    @ViewBuilder
    private var definitionPane: some View {
        if let error = engine.lastError, engine.searchHits.isEmpty, !engine.isBusy, !engine.isSearching {
            VStack(alignment: .leading, spacing: 10) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                Button(lang.text("关闭提示", "Dismiss")) {
                    engine.clearError()
                }
                .buttonStyle(.borderless)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if engine.dictionaries.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text(lang.text("还没有词典", "No dictionaries yet"))
                    .font(.headline)
                Text(lang.text(
                    "使用右上角菜单导入 .mdx；同目录的 .mdd 可以作为资源一同导入。",
                    "Use the menu above to import an .mdx file. Matching .mdd files can be added as resources."
                ))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 430)
                if engine.isBusy {
                    ProgressView(value: engine.progress ?? 0, total: 1)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 300)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "book.pages")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(lang.text("输入单词开始查询", "Enter a word to search"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if engine.searchHits.isEmpty {
            if engine.isSearching || engine.isLoadingDefinition {
                DictionaryDefinitionSkeleton()
            } else {
                ContentUnavailableView(
                    lang.text("没有匹配结果", "No matches"),
                    systemImage: "magnifyingglass",
                    description: Text(lang.text("尝试更短的关键词或切换词典。", "Try a shorter query or another dictionary."))
                )
            }
        } else if engine.searchResults.isEmpty {
            if engine.isLoadingDefinition {
                DictionaryDefinitionSkeleton()
            } else if let error = engine.lastError {
                Text(error)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView(
                    lang.text("没有释义", "No definition"),
                    systemImage: "book.closed",
                    description: Text(lang.text("请选择左侧词条。", "Select a result on the left."))
                )
            }
        } else {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(selectedResultKey ?? engine.definitionQuery ?? query)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                    if selectedDefinitionEntries.count > 1 {
                        Text(lang.text("来自 \(selectedDefinitionEntries.count) 本词典", "From \(selectedDefinitionEntries.count) dictionaries"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 2)

                DictionaryHTMLView(
                    entries: selectedDefinitionEntries,
                    isCompact: false,
                    textScale: textScale,
                    onLookupWord: { word in
                        query = word
                        recordQuery(word)
                        engine.search(query: word, dictionaryID: selectedDictionaryID, includeDetails: true, immediate: true)
                    },
                    onPlayAudio: { audioKey in
                        DictionaryInteractionCoordinator.shared.speak(audioKey)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var dictionaryStatusBarNative: some View {
        if engine.isBusy || engine.statusMessage != nil || engine.lastError != nil {
            Divider()
            HStack(spacing: 7) {
                if engine.isBusy {
                    ProgressView()
                        .controlSize(.small)
                    Text(engine.progressPhase ?? lang.text("正在处理词典…", "Processing dictionary…"))
                        .lineLimit(1)
                } else if let message = engine.statusMessage {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(message)
                        .lineLimit(1)
                } else if let error = engine.lastError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                Spacer()
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
            .background(StudyMateMediaStyle.panelBackground)
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
        selectedResultKey = nil
        isApplyingHistory = false
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
                        .disabled(engine.isBusy)
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
                    .disabled(engine.isBusy)
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

    /// Dismiss the confirmation UI first, then begin the mutation on the next
    /// MainActor turn. Starting the Rust request from the alert's gesture
    /// callback can race SwiftUI's alert teardown on macOS 26 and can leave
    /// the actor executor assertion in the button gesture path. The extra
    /// turn also lets the result WebView detach before its package is removed.
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
        .frame(width: 900, height: 600)
}
