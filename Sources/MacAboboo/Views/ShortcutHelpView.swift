import SwiftUI

/// 帮助菜单中的快捷键总览。搜索同时匹配功能名称和快捷键文本。
public struct ShortcutHelpView: View {
    @ObservedObject private var lang = LanguageManager.shared
    @State private var searchText = ""

    public init() {}

    private var filteredShortcuts: [MacAbobooShortcutDescriptor] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return MacAbobooShortcutCatalog.all }
        return MacAbobooShortcutCatalog.all.filter { shortcut in
            shortcut.name(for: lang.currentLanguage).localizedCaseInsensitiveContains(query)
                || shortcut.keyDisplay.localizedCaseInsensitiveContains(query)
                || shortcut.chineseName.localizedCaseInsensitiveContains(query)
                || shortcut.englishName.localizedCaseInsensitiveContains(query)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField(
                    lang.text("搜索功能或快捷键", "Search commands or shortcuts"),
                    text: $searchText
                )
                .textFieldStyle(.plain)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(MacAbobooShortcutCatalog.help(
                        lang.text("清除搜索", "Clear search"),
                        shortcut: .clearSearch
                    ))
                }
            }
            .padding(9)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .bottom) {
                Divider()
            }

            HStack(spacing: 12) {
                Text(lang.text("功能", "Command"))
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(lang.text("快捷键", "Shortcut"))
                    .font(.caption.bold())
                    .frame(width: 140, alignment: .trailing)
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            if filteredShortcuts.isEmpty {
                ContentUnavailableView(
                    lang.text("没有匹配的快捷键", "No matching shortcuts"),
                    systemImage: "keyboard",
                    description: Text(lang.text("请尝试搜索功能名称或按键符号。", "Search by command name or key symbol."))
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredShortcuts) { shortcut in
                            HStack(spacing: 12) {
                                Text(shortcut.name(for: lang.currentLanguage))
                                    .font(.callout)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text(shortcut.keyDisplay)
                                    .font(.system(.callout, design: .monospaced).weight(.medium))
                                    .foregroundColor(.secondary)
                                    .frame(width: 140, alignment: .trailing)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())

                            Divider()
                                .padding(.leading, 14)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

#Preview("快捷键") {
    ShortcutHelpView()
}
