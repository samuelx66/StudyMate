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
            VStack(spacing: 0) {
                searchBar
                Divider()
                results
            }
        }
        .background(StudyMateMediaStyle.windowBackground)
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
        .onChange(of: query) { _, newValue in
            engine.search(query: newValue, dictionaryID: selectedDictionaryID)
        }
        .onChange(of: selectedDictionaryID) { _, _ in
            engine.search(query: query, dictionaryID: selectedDictionaryID)
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
                }
            }
            .listStyle(.sidebar)

            if engine.isBusy {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(lang.text("正在导入词典…", "Importing dictionary…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(engine.searchResults) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.key)
                                    .font(.system(size: 17, weight: .semibold))
                                Spacer()
                                Text(entry.dictionaryTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(Self.plainText(entry.text))
                                .font(.system(size: 14))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(14)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(16)
            }
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

    private static func plainText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

#Preview("StudyMate Dictionary") {
    DictionaryView()
        .frame(width: 900, height: 600)
}
