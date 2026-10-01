import Foundation
import SwiftUI
import AppKit

/// 全局快捷键统一管理器
/// 负责自定义快捷键持久化存储、动态映射、冲突检测以及全局事件匹配。
@MainActor
public final class StudyMateShortcutManager: ObservableObject {
    public static let shared = StudyMateShortcutManager()

    private let defaultsKey = "StudyMate.CustomShortcuts.v1"

    @Published public private(set) var customBindings: [StudyMateShortcutID: ShortcutKeyBinding] = [:]

    private init() {
        loadCustomBindings()
    }

    private func loadCustomBindings() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        do {
            let rawMap = try JSONDecoder().decode([String: ShortcutKeyBinding].self, from: data)
            var result: [StudyMateShortcutID: ShortcutKeyBinding] = [:]
            for (k, v) in rawMap {
                if let id = StudyMateShortcutID(rawValue: k) {
                    result[id] = v
                }
            }
            self.customBindings = result
        } catch {
            print("Failed to decode custom shortcuts: \(error)")
        }
    }

    private func persist() {
        let rawMap = Dictionary(uniqueKeysWithValues: customBindings.map { ($0.key.rawValue, $0.value) })
        do {
            let data = try JSONEncoder().encode(rawMap)
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } catch {
            print("Failed to encode custom shortcuts: \(error)")
        }
    }

    /// 是否存在任何已自定义修改的快捷键
    public var hasAnyCustomized: Bool {
        !customBindings.isEmpty
    }

    /// 已自定义修改的快捷键数量
    public var customizedCount: Int {
        customBindings.count
    }

    /// 检查指定快捷键是否被修改过
    public func isCustomized(_ id: StudyMateShortcutID) -> Bool {
        customBindings[id] != nil
    }

    /// 获取当前有效的按键绑定（优先自定义，回退默认）
    public func binding(for id: StudyMateShortcutID) -> ShortcutKeyBinding {
        if let custom = customBindings[id] {
            return custom
        }
        return StudyMateShortcutCatalog.defaultBinding(for: id)
    }

    /// 获取默认的按键绑定
    public func defaultBinding(for id: StudyMateShortcutID) -> ShortcutKeyBinding {
        StudyMateShortcutCatalog.defaultBinding(for: id)
    }

    /// 获取当前快捷键的显示文本（如 ⌘O, ⌥⌘1, 空格 等）
    public func keyDisplay(for id: StudyMateShortcutID) -> String {
        binding(for: id).keyDisplay
    }

    /// 获取 SwiftUI 菜单可绑定的 KeyboardShortcut 实例
    public func keyboardShortcut(for id: StudyMateShortcutID) -> KeyboardShortcut? {
        binding(for: id).keyboardShortcut
    }

    /// 冲突检测：查找指定按键绑定是否已被其它命令占用
    public func conflictingShortcut(
        for binding: ShortcutKeyBinding,
        excluding targetID: StudyMateShortcutID? = nil
    ) -> StudyMateShortcutID? {
        for desc in StudyMateShortcutCatalog.all {
            if let targetID, desc.id == targetID {
                continue
            }
            if self.binding(for: desc.id) == binding {
                return desc.id
            }
        }
        return nil
    }

    /// 设置自定义按键绑定
    public func setCustomBinding(_ binding: ShortcutKeyBinding, for id: StudyMateShortcutID) {
        customBindings[id] = binding
        persist()
        objectWillChange.send()
    }

    /// 重置单个快捷键为默认设置
    public func resetToDefault(for id: StudyMateShortcutID) {
        guard customBindings.removeValue(forKey: id) != nil else { return }
        persist()
        objectWillChange.send()
    }

    /// 一键重置所有快捷键为默认设置
    public func resetAllToDefaults() {
        guard !customBindings.isEmpty else { return }
        customBindings.removeAll()
        persist()
        objectWillChange.send()
    }

    /// 匹配系统键盘事件是否命中指定快捷键
    public func matches(event: NSEvent, for id: StudyMateShortcutID) -> Bool {
        guard let eventBinding = ShortcutKeyBinding.from(event: event) else { return false }
        return binding(for: id) == eventBinding
    }
}
