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
}
