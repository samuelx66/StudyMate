import SwiftUI
import AppKit

/// 快捷键总览与自定义管理窗口
/// 支持按键修改、一键重置默认、单独恢复默认、冲突检测以及修改项特别高亮显示。
public struct ShortcutHelpView: View {
    @ObservedObject private var lang = LanguageManager.shared
    @ObservedObject private var shortcutManager = StudyMateShortcutManager.shared

    @State private var searchText = ""
    @State private var filterTab: FilterTab = .all
    @State private var recordingShortcutID: StudyMateShortcutID? = nil
    @State private var activeKeyMonitor: Any? = nil
    @State private var isShowingResetAllAlert = false
    @State private var conflictAlertInfo: ConflictAlertInfo? = nil

    private enum FilterTab: Int, CaseIterable, Identifiable {
        case all = 0
        case customizedOnly = 1

        var id: Int { rawValue }
    }

    private struct ConflictAlertInfo: Identifiable {
        let id = UUID()
        let message: String
        let onConfirm: () -> Void
    }

    public init() {}

    private var allDescriptors: [StudyMateShortcutDescriptor] {
        StudyMateShortcutCatalog.all
    }

    private var filteredCategories: [(category: StudyMateShortcutCategory, shortcuts: [StudyMateShortcutDescriptor])] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return StudyMateShortcutCategory.allCases.compactMap { category in
            let inCategory = allDescriptors.filter { $0.category == category }
            let matching = inCategory.filter { shortcut in
                // 筛选 Tab
                if filterTab == .customizedOnly && !shortcutManager.isCustomized(shortcut.id) {
                    return false
                }
                // 搜索文本过滤
                guard !query.isEmpty else { return true }
                return shortcut.name(for: lang.currentLanguage).localizedCaseInsensitiveContains(query)
                    || shortcut.keyDisplay.localizedCaseInsensitiveContains(query)
                    || shortcut.defaultKeyDisplay.localizedCaseInsensitiveContains(query)
                    || shortcut.chineseName.localizedCaseInsensitiveContains(query)
                    || shortcut.englishName.localizedCaseInsensitiveContains(query)
                    || category.localized(with: lang).localizedCaseInsensitiveContains(query)
            }
            guard !matching.isEmpty else { return nil }
            return (category, matching)
        }
    }

    private var totalMatchingCount: Int {
        filteredCategories.reduce(0) { $0 + $1.shortcuts.count }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // MARK: - 顶部工具栏与分类过滤器
            HStack(spacing: 12) {
                Picker(lang.text("范围", "Scope"), selection: $filterTab) {
                    Text(lang.text("全部 (\(allDescriptors.count))", "All (\(allDescriptors.count))"))
                        .tag(FilterTab.all)
                    Text(
                        shortcutManager.customizedCount > 0
                            ? lang.text("已修改 (\(shortcutManager.customizedCount))", "Customized (\(shortcutManager.customizedCount))")
                            : lang.text("已修改", "Customized")
                    )
                    .tag(FilterTab.customizedOnly)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)

                Spacer()

                // 一键重置回默认快捷键
                Button(role: .destructive) {
                    isShowingResetAllAlert = true
                } label: {
                    Label(
                        lang.text("恢复全部默认", "Reset All to Defaults"),
                        systemImage: "arrow.counterclockwise"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(!shortcutManager.hasAnyCustomized)
                .help(lang.text("将所有自定义快捷键恢复为系统默认设置", "Reset all customized shortcuts to system defaults"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // MARK: - 快捷键列表
            Group {
                if filteredCategories.isEmpty {
                    ContentUnavailableView(
                        filterTab == .customizedOnly
                            ? lang.text("暂无已修改的快捷键", "No Customized Shortcuts")
                            : lang.text("没有匹配的快捷键", "No Matching Shortcuts"),
                        systemImage: filterTab == .customizedOnly ? "keyboard.badge.ellipsis" : "keyboard",
                        description: Text(
                            filterTab == .customizedOnly
                                ? lang.text("点击任意快捷键即可进行自定义修改。", "Click any shortcut in the list to customize it.")
                                : lang.text("请尝试搜索功能名称、分类或按键符号。", "Search by command name, category, or key symbol.")
                        )
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filteredCategories, id: \.category.id) { group in
                            Section {
                                ForEach(group.shortcuts) { shortcut in
                                    shortcutRow(shortcut: shortcut)
                                }
                            } header: {
                                HStack(spacing: 6) {
                                    Image(systemName: group.category.iconName)
                                        .foregroundStyle(Color.accentColor)
                                    Text(group.category.localized(with: lang))
                                        .font(.system(size: 12, weight: .bold))
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            }
        }
        .navigationTitle(lang.text("快捷键设置", "Keyboard Shortcuts"))
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: Text(lang.text("搜索功能、分类或快捷键…", "Search commands, categories, or shortcuts…"))
        )
        .overlay(alignment: .bottom) {
            WindowFloatingStatusToast(bottomPadding: 20)
        }
        .alert(lang.text("恢复默认快捷键", "Reset All Shortcuts"), isPresented: $isShowingResetAllAlert) {
            Button(lang.text("恢复全部默认", "Reset All to Defaults"), role: .destructive) {
                resetAllShortcuts()
            }
            Button(lang.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(lang.text("确定要将所有已修改的快捷键重置为系统默认值吗？此操作无法撤销。", "Are you sure you want to reset all customized shortcuts back to system defaults? This cannot be undone."))
        }
        .alert(item: $conflictAlertInfo) { info in
            Alert(
                title: Text(lang.text("快捷键冲突", "Shortcut Conflict")),
                message: Text(info.message),
                primaryButton: .default(Text(lang.text("替换并重新分配", "Replace & Reassign"))) {
                    info.onConfirm()
                },
                secondaryButton: .cancel(Text(lang.text("取消", "Cancel")))
            )
        }
        .onDisappear {
            stopRecording()
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520, idealHeight: 620)
    }

    // MARK: - 单行快捷键视图
    @ViewBuilder
    private func shortcutRow(shortcut: StudyMateShortcutDescriptor) -> some View {
        let isModified = shortcutManager.isCustomized(shortcut.id)
        let isRecording = recordingShortcutID == shortcut.id

        HStack(spacing: 12) {
            // 左侧：突出修改状态与功能名称
            HStack(spacing: 8) {
                if isModified {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(shortcut.name(for: lang.currentLanguage))
                        .font(.system(size: 13, weight: isModified ? .semibold : .regular))
                        .foregroundStyle(Color.primary)

                    if isModified {
                        Text(lang.text("默认: \(shortcut.defaultKeyDisplay)", "Default: \(shortcut.defaultKeyDisplay)"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // 右侧：标签、按键与操作
            HStack(spacing: 8) {
                // 特别突出显示：已修改状态胶囊徽章
                if isModified && !isRecording {
                    Text(lang.text("已修改", "Custom"))
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule()
                                .fill(Color.orange.opacity(0.18))
                        )
                        .overlay(
                            Capsule()
                                .stroke(Color.orange.opacity(0.4), lineWidth: 0.8)
                        )
                        .foregroundStyle(Color.orange)
                }

                // 录制状态 / 静态按键药丸
                if isRecording {
                    recordingPillView(for: shortcut)
                } else {
                    shortcutPillView(shortcut: shortcut, isModified: isModified)

                    // 编辑按钮
                    Button {
                        startRecording(for: shortcut.id)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .help(lang.text("修改此快捷键", "Edit this shortcut"))

                    // 单项恢复默认按钮
                    if isModified {
                        Button {
                            resetSingleShortcut(shortcut)
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(lang.text("恢复此快捷键为默认设置", "Reset this shortcut to default"))
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 静态按键药丸（特别突出显示已修改项）
    @ViewBuilder
    private func shortcutPillView(shortcut: StudyMateShortcutDescriptor, isModified: Bool) -> some View {
        Button {
            startRecording(for: shortcut.id)
        } label: {
            Text(shortcut.keyDisplay)
                .font(.system(size: 12, weight: isModified ? .bold : .semibold, design: .monospaced))
                .foregroundStyle(isModified ? Color.accentColor : Color.primary)
                .padding(.horizontal, isModified ? 9 : 7)
                .padding(.vertical, 3.5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isModified ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            isModified ? Color.accentColor : Color.primary.opacity(0.12),
                            lineWidth: isModified ? 1.5 : 0.5
                        )
                )
                .shadow(
                    color: isModified ? Color.accentColor.opacity(0.25) : Color.clear,
                    radius: isModified ? 3 : 0,
                    x: 0,
                    y: 1
                )
        }
        .buttonStyle(.plain)
        .help(lang.text("点击修改快捷键", "Click to edit shortcut"))
    }

    // MARK: - 正在录制按键药丸
    @ViewBuilder
    private func recordingPillView(for shortcut: StudyMateShortcutDescriptor) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)

                Text(lang.text("按下新按键…", "Press keys…"))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 2)
            )

            // 取消录制
            Button {
                stopRecording()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(lang.text("取消录制 (Esc)", "Cancel recording (Esc)"))
        }
    }

    // MARK: - 动作逻辑

    private func startRecording(for id: StudyMateShortcutID) {
        stopRecording()
        recordingShortcutID = id

        activeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

            // 按 Esc 取消录制
            if event.keyCode == 53 && modifiers.isEmpty {
                DispatchQueue.main.async {
                    self.stopRecording()
                }
                return nil
            }

            // 提取按键组合
            if let newBinding = ShortcutKeyBinding.from(event: event) {
                DispatchQueue.main.async {
                    self.applyRecordedBinding(newBinding, for: id)
                }
                return nil
            }

            return nil
        }
    }

    private func stopRecording() {
        if let monitor = activeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            activeKeyMonitor = nil
        }
        recordingShortcutID = nil
    }

    private func applyRecordedBinding(_ binding: ShortcutKeyBinding, for id: StudyMateShortcutID) {
        stopRecording()

        let currentDesc = StudyMateShortcutCatalog.descriptor(id)
        let currentName = currentDesc.name(for: lang.currentLanguage)

        // 检测是否存在按键冲突
        if let conflictID = shortcutManager.conflictingShortcut(for: binding, excluding: id) {
            let conflictDesc = StudyMateShortcutCatalog.descriptor(conflictID)
            let conflictName = conflictDesc.name(for: lang.currentLanguage)

            conflictAlertInfo = ConflictAlertInfo(
                message: lang.text(
                    "快捷键【\(binding.keyDisplay)】当前已被【\(conflictName)】使用。\n是否将其替换并重新分配给【\(currentName)】？",
                    "Shortcut 【\(binding.keyDisplay)】 is already in use by 【\(conflictName)】.\nReassign it to 【\(currentName)】?"
                ),
                onConfirm: {
                    self.shortcutManager.resetToDefault(for: conflictID)
                    self.shortcutManager.setCustomBinding(binding, for: id)
                    MainStatusCenter.shared.showSuccess(
                        self.lang.text(
                            "已将【\(currentName)】快捷键修改为 \(binding.keyDisplay)",
                            "Updated shortcut for 【\(currentName)】 to \(binding.keyDisplay)"
                        )
                    )
                }
            )
            return
        }

        // 无冲突直接更新
        shortcutManager.setCustomBinding(binding, for: id)
        MainStatusCenter.shared.showSuccess(
            lang.text(
                "已将【\(currentName)】快捷键修改为 \(binding.keyDisplay)",
                "Updated shortcut for 【\(currentName)】 to \(binding.keyDisplay)"
            )
        )
    }

    private func resetSingleShortcut(_ shortcut: StudyMateShortcutDescriptor) {
        shortcutManager.resetToDefault(for: shortcut.id)
        let name = shortcut.name(for: lang.currentLanguage)
        MainStatusCenter.shared.showSuccess(
            lang.text("已恢复【\(name)】为默认快捷键 (\(shortcut.defaultKeyDisplay))", "Reset 【\(name)】 to default shortcut (\(shortcut.defaultKeyDisplay))")
        )
    }

    private func resetAllShortcuts() {
        stopRecording()
        shortcutManager.resetAllToDefaults()
        MainStatusCenter.shared.showSuccess(
            lang.text("已恢复所有快捷键为默认设置", "All shortcuts reset to default settings")
        )
    }
}

#Preview("快捷键设置") {
    ShortcutHelpView()
}
