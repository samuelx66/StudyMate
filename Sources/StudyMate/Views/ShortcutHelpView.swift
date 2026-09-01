import SwiftUI

/// 帮助菜单中的快捷键总览。搜索同时匹配功能名称和快捷键文本。
public struct ShortcutHelpView: View {
    @ObservedObject private var lang = LanguageManager.shared
    @State private var searchText = ""

    public init() {}

    private var filteredShortcuts: [StudyMateShortcutDescriptor] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return StudyMateShortcutCatalog.all }
        return StudyMateShortcutCatalog.all.filter { shortcut in
            shortcut.name(for: lang.currentLanguage).localizedCaseInsensitiveContains(query)
                || shortcut.keyDisplay.localizedCaseInsensitiveContains(query)
                || shortcut.chineseName.localizedCaseInsensitiveContains(query)
                || shortcut.englishName.localizedCaseInsensitiveContains(query)
        }
    }

    public var body: some View {
        Group {
            if filteredShortcuts.isEmpty {
                ContentUnavailableView(
                    lang.text("没有匹配的快捷键", "No matching shortcuts"),
                    systemImage: "keyboard",
                    description: Text(lang.text("请尝试搜索功能名称或按键符号。", "Search by command name or key symbol."))
                )
            } else {
                List(filteredShortcuts) { shortcut in
                    HStack(spacing: 12) {
                        Text(shortcut.name(for: lang.currentLanguage))
                            .font(.system(size: 13, weight: .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(shortcut.keyDisplay)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.primary.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                            )
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationTitle(lang.text("快捷键", "Keyboard Shortcuts"))
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: Text(lang.text("搜索功能或快捷键", "Search commands or shortcuts"))
        )
        .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 600)
    }
}

#Preview("快捷键") {
    ShortcutHelpView()
}
