import XCTest
import SwiftUI
import AppKit
@testable import StudyMateKit

@MainActor
final class ShortcutManagerTests: XCTestCase {
    override func setUp() async throws {
        StudyMateShortcutManager.shared.resetAllToDefaults()
    }

    override func tearDown() async throws {
        StudyMateShortcutManager.shared.resetAllToDefaults()
    }

    func testShortcutKeyBindingDisplay() {
        let cmdL = ShortcutKeyBinding(key: "l", isCommand: true)
        XCTAssertEqual(cmdL.keyDisplay, "⌘L")

        let cmdShiftV = ShortcutKeyBinding(key: "v", isCommand: true, isShift: true)
        XCTAssertEqual(cmdShiftV.keyDisplay, "⇧⌘V")

        let optCmd1 = ShortcutKeyBinding(key: "1", isCommand: true, isOption: true)
        XCTAssertEqual(optCmd1.keyDisplay, "⌥⌘1")

        let space = ShortcutKeyBinding(key: "space")
        XCTAssertEqual(space.keyDisplay, "空格")

        let ctrlOptLeft = ShortcutKeyBinding(key: "leftArrow", isOption: true, isControl: true)
        XCTAssertEqual(ctrlOptLeft.keyDisplay, "⌃⌥←")
    }

    func testShortcutKeyBindingCodable() throws {
        let binding = ShortcutKeyBinding(key: "k", isCommand: true, isShift: true, isOption: true)
        let data = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(ShortcutKeyBinding.self, from: data)
        XCTAssertEqual(binding, decoded)
    }

    func testCatalogAllCountAndCategories() {
        XCTAssertEqual(StudyMateShortcutCatalog.all.count, 65)
        for shortcut in StudyMateShortcutCatalog.all {
            XCTAssertFalse(shortcut.chineseName.isEmpty)
            XCTAssertFalse(shortcut.englishName.isEmpty)
            XCTAssertFalse(shortcut.defaultKeyDisplay.isEmpty)
            XCTAssertEqual(shortcut.keyDisplay, shortcut.defaultKeyDisplay)
        }
    }

    func testCustomShortcutModificationAndReset() {
        let manager = StudyMateShortcutManager.shared
        XCTAssertFalse(manager.hasAnyCustomized)
        XCTAssertEqual(manager.customizedCount, 0)
        XCTAssertFalse(manager.isCustomized(.playPause))

        let newBinding = ShortcutKeyBinding(key: "p", isCommand: true)
        manager.setCustomBinding(newBinding, for: .playPause)

        XCTAssertTrue(manager.hasAnyCustomized)
        XCTAssertEqual(manager.customizedCount, 1)
        XCTAssertTrue(manager.isCustomized(.playPause))
        XCTAssertEqual(manager.binding(for: .playPause), newBinding)
        XCTAssertEqual(manager.keyDisplay(for: .playPause), "⌘P")

        // 重置单个
        manager.resetToDefault(for: .playPause)
        XCTAssertFalse(manager.isCustomized(.playPause))
        XCTAssertFalse(manager.hasAnyCustomized)
        XCTAssertEqual(manager.binding(for: .playPause), StudyMateShortcutCatalog.defaultBinding(for: .playPause))
    }

    func testConflictDetection() {
        let manager = StudyMateShortcutManager.shared
        // ⌘O 默认用于 openMedia
        let cmdO = ShortcutKeyBinding(key: "o", isCommand: true)
        let conflict = manager.conflictingShortcut(for: cmdO, excluding: .openMedia)
        XCTAssertNil(conflict)

        // 查找与其它命令冲突
        let conflictWithOther = manager.conflictingShortcut(for: cmdO, excluding: .openSentenceLibrary)
        XCTAssertEqual(conflictWithOther, .openMedia)
    }

    func testResetAllToDefaults() {
        let manager = StudyMateShortcutManager.shared
        manager.setCustomBinding(ShortcutKeyBinding(key: "1", isCommand: true), for: .playPause)
        manager.setCustomBinding(ShortcutKeyBinding(key: "2", isCommand: true), for: .mute)
        XCTAssertEqual(manager.customizedCount, 2)

        manager.resetAllToDefaults()
        XCTAssertEqual(manager.customizedCount, 0)
        XCTAssertFalse(manager.hasAnyCustomized)
    }
}
