import XCTest
@testable import MacAbobooKit

final class SentenceLibraryStoreTests: XCTestCase {
    func testSpecificDayFilterUsesExactCalendarDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let selectedDate = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 23,
            hour: 15,
            minute: 30
        )))

        let lower = try XCTUnwrap(SentenceLibraryDateFilter.specificDay.lowerBound(
            selectedDate: selectedDate,
            calendar: calendar
        ))
        let upper = try XCTUnwrap(SentenceLibraryDateFilter.specificDay.upperBound(
            selectedDate: selectedDate,
            calendar: calendar
        ))

        XCTAssertEqual(calendar.component(.hour, from: lower), 0)
        XCTAssertEqual(calendar.dateComponents([.day], from: lower, to: upper).day, 1)
    }

    private var temporaryDirectory: URL!
    private var store: SentenceLibraryStore!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-SentenceLibraryTests-\(UUID().uuidString)", isDirectory: true)
        store = SentenceLibraryStore(rootURL: temporaryDirectory)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        store = nil
    }

    func testCreateSearchDateFilterAndDeleteEntries() throws {
        let library = try store.createLibrary(name: "学习句库")
        let oldEntry = SentenceLibraryEntry(
            originalText: "An older sentence",
            translation: "较早的句子",
            sourceMediaName: "old.mp4",
            sourceMediaPath: "/old.mp4",
            startTime: 1,
            endTime: 2,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let newEntryID = UUID()
        let newEntry = SentenceLibraryEntry(
            id: newEntryID,
            originalText: "A searchable sentence",
            translation: "可以检索的字幕",
            sourceMediaName: "new.mp4",
            sourceMediaPath: "/new.mp4",
            startTime: 3,
            endTime: 5,
            createdAt: Date(timeIntervalSince1970: 2_000),
            previewFilename: "\(newEntryID.uuidString).jpg"
        )
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xD9])

        try store.add(entries: [oldEntry, newEntry], previewData: [newEntry.id: imageData], to: library.id)

        XCTAssertEqual(try store.entries(libraryID: library.id).count, 2)
        XCTAssertEqual(try store.entries(libraryID: library.id, searchText: "检索").map(\.id), [newEntry.id])
        XCTAssertEqual(
            try store.entries(libraryID: library.id, createdAfter: Date(timeIntervalSince1970: 1_500)).map(\.id),
            [newEntry.id]
        )
        XCTAssertEqual(
            try store.entries(
                libraryID: library.id,
                createdAfter: Date(timeIntervalSince1970: 1_500),
                createdBefore: Date(timeIntervalSince1970: 2_500)
            ).map(\.id),
            [newEntry.id]
        )
        XCTAssertTrue(try store.entries(
            libraryID: library.id,
            createdAfter: Date(timeIntervalSince1970: 2_001),
            createdBefore: Date(timeIntervalSince1970: 3_000)
        ).isEmpty)
        let previewURL = try XCTUnwrap(store.previewURL(for: newEntry, libraryID: library.id))
        XCTAssertEqual(try Data(contentsOf: previewURL), imageData)

        try store.deleteEntries(ids: [newEntry.id], from: library.id)
        XCTAssertEqual(try store.entries(libraryID: library.id).map(\.id), [oldEntry.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: previewURL.path))
    }

    func testExportedPackageCanBeImportedByAnotherStore() throws {
        let library = try store.createLibrary(name: "可携带句库")
        let entry = SentenceLibraryEntry(
            originalText: "Portable",
            translation: "可携带",
            sourceMediaName: "lesson.m4a",
            sourceMediaPath: "/lesson.m4a",
            startTime: 0,
            endTime: 1,
            createdAt: Date()
        )
        try store.add(entries: [entry], previewData: [:], to: library.id)

        let exportedURL = temporaryDirectory.appendingPathComponent("Exported.mablib", isDirectory: true)
        try store.exportLibrary(id: library.id, to: exportedURL)

        let importRoot = temporaryDirectory.appendingPathComponent("Imported", isDirectory: true)
        let importingStore = SentenceLibraryStore(rootURL: importRoot)
        let imported = try importingStore.importLibrary(from: exportedURL)

        XCTAssertEqual(imported.id, library.id)
        let importedEntry = try XCTUnwrap(importingStore.entries(libraryID: imported.id).first)
        XCTAssertEqual(importedEntry.id, entry.id)
        XCTAssertEqual(importedEntry.originalText, entry.originalText)
        XCTAssertEqual(importedEntry.translation, entry.translation)
        XCTAssertEqual(importedEntry.sourceMediaName, entry.sourceMediaName)
        XCTAssertEqual(importedEntry.createdAt.timeIntervalSince1970, entry.createdAt.timeIntervalSince1970, accuracy: 0.001)
    }
}
