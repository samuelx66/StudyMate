import XCTest
@testable import StudyMateKit

final class DictionarySourceSettingsTests: XCTestCase {
    private func dictionary(_ id: String) -> StudyMateDictionarySummary {
        StudyMateDictionarySummary(
            id: id,
            title: id.capitalized,
            encoding: "UTF-8",
            format: "MDX",
            entryCount: 0,
            resourceCount: 0,
            importedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "StudyMate.DictionarySourceSettingsTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    func testNewDictionariesAreEnabledAndFollowInstalledOrder() {
        let settings = DictionarySourceSettings(defaults: makeDefaults())
        let dictionaries = [dictionary("first"), dictionary("second")]

        settings.synchronize(with: dictionaries)

        XCTAssertEqual(settings.orderedDictionaryIDs, ["first", "second"])
        XCTAssertEqual(settings.enabledDictionaryIDs, ["first", "second"])
        XCTAssertEqual(settings.enabledDictionaries(from: dictionaries).map(\.id), ["first", "second"])
    }

    func testDisabledDictionaryIsExcludedButRemainsInOrderList() {
        let settings = DictionarySourceSettings(defaults: makeDefaults())
        let dictionaries = [dictionary("first"), dictionary("second")]
        settings.synchronize(with: dictionaries)

        settings.setEnabled(false, for: "first")

        XCTAssertFalse(settings.isEnabled("first"))
        XCTAssertEqual(settings.orderedDictionaryIDs, ["first", "second"])
        XCTAssertEqual(settings.enabledDictionaries(from: dictionaries).map(\.id), ["second"])
    }

    func testMovePersistsPriorityAndNewDictionaryIsAppended() {
        let defaults = makeDefaults()
        let settings = DictionarySourceSettings(defaults: defaults)
        let initial = [dictionary("first"), dictionary("second"), dictionary("third")]
        settings.synchronize(with: initial)

        settings.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        settings.synchronize(with: initial + [dictionary("fourth")])

        XCTAssertEqual(settings.orderedDictionaryIDs, ["third", "first", "second", "fourth"])
        XCTAssertTrue(settings.isEnabled("fourth"))

        let reloaded = DictionarySourceSettings(defaults: defaults)
        reloaded.synchronize(with: initial + [dictionary("fourth")])
        XCTAssertEqual(reloaded.orderedDictionaryIDs, settings.orderedDictionaryIDs)
    }

    func testRemovedDictionaryIsDroppedFromPersistedChoices() {
        let settings = DictionarySourceSettings(defaults: makeDefaults())
        let initial = [dictionary("first"), dictionary("second")]
        settings.synchronize(with: initial)
        settings.setEnabled(false, for: "second")

        settings.synchronize(with: [dictionary("first")])

        XCTAssertEqual(settings.orderedDictionaryIDs, ["first"])
        XCTAssertEqual(settings.enabledDictionaryIDs, ["first"])
    }

    func testLookupScopeDefaultsToNilAndPersistsID() {
        let defaults = makeDefaults()
        let settings = DictionarySourceSettings(defaults: defaults)
        let initial = [dictionary("dict1"), dictionary("dict2")]
        settings.synchronize(with: initial)

        // 默认值应为 nil（代表“全部”）
        XCTAssertNil(settings.lookupScopeDictionaryID)

        // 设置为特定词典
        settings.setLookupScopeDictionaryID("dict1")
        XCTAssertEqual(settings.lookupScopeDictionaryID, "dict1")

        // 重启后应从 UserDefaults 恢复
        let reloaded = DictionarySourceSettings(defaults: defaults)
        XCTAssertEqual(reloaded.lookupScopeDictionaryID, "dict1")

        // 切换回全部 (nil 或空字符串)
        settings.setLookupScopeDictionaryID(nil)
        XCTAssertNil(settings.lookupScopeDictionaryID)
        let reloadedAfterClear = DictionarySourceSettings(defaults: defaults)
        XCTAssertNil(reloadedAfterClear.lookupScopeDictionaryID)
    }

    func testRemovedDictionaryResetsLookupScopeToNil() {
        let defaults = makeDefaults()
        let settings = DictionarySourceSettings(defaults: defaults)
        let initial = [dictionary("dict1"), dictionary("dict2")]
        settings.synchronize(with: initial)
        settings.setLookupScopeDictionaryID("dict2")
        XCTAssertEqual(settings.lookupScopeDictionaryID, "dict2")

        // 移除词典 dict2 时，查词范围自动回退到 nil（全部）
        settings.remove(dictionaryID: "dict2")
        XCTAssertNil(settings.lookupScopeDictionaryID)

        // 同步中若所选词典已不在列表中，自动回退到 nil（全部）
        settings.setLookupScopeDictionaryID("dict1")
        settings.synchronize(with: [dictionary("dict3")])
        XCTAssertNil(settings.lookupScopeDictionaryID)
    }
}
