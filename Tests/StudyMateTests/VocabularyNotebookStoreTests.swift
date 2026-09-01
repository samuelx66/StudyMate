import XCTest
@testable import StudyMateKit

final class VocabularyNotebookStoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var store: VocabularyNotebookStore!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudyMate-VocabularyTests-\(UUID().uuidString)", isDirectory: true)
        store = VocabularyNotebookStore(rootURL: temporaryDirectory)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        store = nil
    }

    func testSearchOnlyMatchesWordAndFiltersBySourceAndTime() throws {
        let notebook = try store.createNotebook(name: "英语")
        let old = VocabularyWordEntry(
            word: "apple",
            addedAt: Date(timeIntervalSince1970: 1_000),
            exampleSentence: "needle appears only in the example",
            source: "lesson-a"
        )
        let recent = VocabularyWordEntry(
            word: "banana",
            addedAt: Date(timeIntervalSince1970: 2_000),
            exampleSentence: "fruit",
            source: "lesson-b"
        )
        try store.add(old, to: notebook.id)
        try store.add(recent, to: notebook.id)

        XCTAssertEqual(try store.entries(notebookID: notebook.id, searchText: "apple").map(\.word), ["apple"])
        XCTAssertTrue(try store.entries(notebookID: notebook.id, searchText: "needle").isEmpty)
        XCTAssertEqual(
            try store.entries(notebookID: notebook.id, source: "lesson-b").map(\.word),
            ["banana"]
        )
        XCTAssertEqual(
            try store.entries(
                notebookID: notebook.id,
                createdAfter: Date(timeIntervalSince1970: 1_500)
            ).map(\.word),
            ["banana"]
        )
        XCTAssertEqual(try store.sourceNames(notebookID: notebook.id), ["lesson-a", "lesson-b"])
    }

    func testSameWordIsUniquePerNotebookAndCanBeToggled() throws {
        let notebook = try store.createNotebook(name: "去重")
        let first = VocabularyWordEntry(
            word: "  Hello  ",
            addedAt: Date(timeIntervalSince1970: 100),
            exampleSentence: "first",
            source: "one"
        )
        let second = VocabularyWordEntry(
            word: "hello",
            addedAt: Date(timeIntervalSince1970: 200),
            exampleSentence: "updated",
            source: "two"
        )

        _ = try store.add(first, to: notebook.id)
        _ = try store.add(second, to: notebook.id)
        let saved = try XCTUnwrap(try store.entries(notebookID: notebook.id).first)
        XCTAssertEqual(try store.entries(notebookID: notebook.id).count, 1)
        XCTAssertEqual(saved.word, "hello")
        XCTAssertEqual(saved.exampleSentence, "updated")
        XCTAssertTrue(try store.contains(word: " HELLO ", in: notebook.id))
        XCTAssertTrue(try store.remove(word: "hello", from: notebook.id))
        XCTAssertFalse(try store.contains(word: "hello", in: notebook.id))
    }

    func testMoveEntriesAndProtectDefaultNotebook() throws {
        let defaultNotebook = try store.createNotebook(name: VocabularyNotebookStore.defaultNotebookName)
        let source = try store.createNotebook(name: "源")
        let destination = try store.createNotebook(name: "目标")
        let entry = VocabularyWordEntry(word: "move", exampleSentence: "move it", source: "test")
        try store.add(entry, to: source.id)

        XCTAssertThrowsError(try store.deleteNotebook(id: defaultNotebook.id)) { error in
            guard case VocabularyNotebookError.defaultNotebookCannotBeDeleted = error else {
                return XCTFail("Expected default-notebook protection, got \(error)")
            }
        }
        XCTAssertEqual(try store.moveEntries(ids: [entry.id], from: source.id, to: destination.id), 1)
        XCTAssertTrue(try store.entries(notebookID: source.id).isEmpty)
        XCTAssertEqual(try store.entries(notebookID: destination.id).map(\.word), ["move"])
    }

    func testBatchDeleteReportsTheTotalNumberOfRowsRemoved() throws {
        let notebook = try store.createNotebook(name: "批量删除")
        let first = VocabularyWordEntry(word: "first")
        let second = VocabularyWordEntry(word: "second")
        try store.add(first, to: notebook.id)
        try store.add(second, to: notebook.id)

        XCTAssertEqual(
            try store.deleteEntries(ids: [first.id, second.id, UUID()], from: notebook.id),
            2
        )
        XCTAssertTrue(try store.entries(notebookID: notebook.id).isEmpty)
    }

    func testMoveKeepsTheExistingDestinationEntryWhenWordsConflict() throws {
        let source = try store.createNotebook(name: "来源")
        let destination = try store.createNotebook(name: "目标")
        let sourceEntry = VocabularyWordEntry(
            word: "same",
            addedAt: Date(timeIntervalSince1970: 100),
            exampleSentence: "source sentence",
            source: "source"
        )
        let destinationEntry = VocabularyWordEntry(
            word: "SAME",
            addedAt: Date(timeIntervalSince1970: 200),
            exampleSentence: "destination sentence",
            source: "destination"
        )
        try store.add(sourceEntry, to: source.id)
        try store.add(destinationEntry, to: destination.id)

        XCTAssertEqual(try store.moveEntries(ids: [sourceEntry.id], from: source.id, to: destination.id), 1)
        let saved = try XCTUnwrap(try store.entries(notebookID: destination.id).first)
        XCTAssertEqual(saved.id, destinationEntry.id)
        XCTAssertEqual(saved.exampleSentence, "destination sentence")
        XCTAssertEqual(saved.source, "destination")
        XCTAssertTrue(try store.entries(notebookID: source.id).isEmpty)
    }

    func testRelativeDateFiltersUseCalendarDayBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 15))!
        let expectedSevenDayStart = calendar.date(from: DateComponents(year: 2026, month: 8, day: 26))!
        let expectedThirtyDayStart = calendar.date(from: DateComponents(year: 2026, month: 8, day: 3))!

        XCTAssertEqual(
            SentenceLibraryDateFilter.lastSevenDays.lowerBound(now: now, calendar: calendar),
            expectedSevenDayStart
        )
        XCTAssertEqual(
            SentenceLibraryDateFilter.lastThirtyDays.lowerBound(now: now, calendar: calendar),
            expectedThirtyDayStart
        )
    }

    @MainActor
    func testManagerToggleUsesDefaultNotebookAndPublishesResult() async throws {
        let suiteName = "StudyMate-VocabularyManagerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = VocabularyNotebookManager(store: store, defaults: defaults)
        let added = try await manager.toggleWord(
            word: "  ToggleMe  ",
            exampleSentence: "A sentence",
            source: "test"
        )
        XCTAssertTrue(added)
        XCTAssertEqual(manager.notebooks.count, 1)
        XCTAssertTrue(manager.notebooks[0].isDefault)
        XCTAssertTrue(manager.isWordSaved("toggleme"))
        XCTAssertEqual(try store.entries(notebookID: try XCTUnwrap(manager.currentNotebookID)).map(\.word), ["ToggleMe"])
        XCTAssertEqual(manager.statusMessage, "已加入生词本")
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(manager.isWordSaved("toggleme"))

        let removed = try await manager.toggleWord(word: "toggleme")
        XCTAssertFalse(removed)
        XCTAssertFalse(manager.isWordSaved("TOGGLEME"))
        XCTAssertTrue(try store.entries(notebookID: try XCTUnwrap(manager.currentNotebookID)).isEmpty)
        XCTAssertEqual(manager.statusMessage, "已从生词本移除")
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(manager.isWordSaved("toggleme"))
    }
}
