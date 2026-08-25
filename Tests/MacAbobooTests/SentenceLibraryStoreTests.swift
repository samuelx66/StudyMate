import XCTest
import SQLite3
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

    func testEntriesCanFilterBySourceAndSortByImportTime() throws {
        let library = try store.createLibrary(name: "来源筛选")
        let first = SentenceLibraryEntry(
            originalText: "first",
            translation: "",
            sourceMediaName: "lesson-a.mp4",
            sourceMediaPath: "/lesson-a.mp4",
            startTime: 0,
            endTime: 1,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let second = SentenceLibraryEntry(
            originalText: "second",
            translation: "",
            sourceMediaName: "lesson-b.mp4",
            sourceMediaPath: "/lesson-b.mp4",
            startTime: 1,
            endTime: 2,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        try store.add(entries: [first, second], previewData: [:], to: library.id)

        XCTAssertEqual(
            try store.entries(libraryID: library.id, sourceMediaName: "lesson-a.mp4").map(\.id),
            [first.id]
        )
        XCTAssertEqual(
            try store.entries(libraryID: library.id, sortOrder: .oldestFirst).map(\.id),
            [first.id, second.id]
        )
        XCTAssertEqual(
            try store.entries(libraryID: library.id, sortOrder: .newestFirst).map(\.id),
            [second.id, first.id]
        )
        XCTAssertEqual(
            try store.sourceMediaNames(libraryID: library.id),
            ["lesson-a.mp4", "lesson-b.mp4"]
        )
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

    func testIndependentMediaIsStoredAndRemovedWithEntry() throws {
        let library = try store.createLibrary(name: "独立媒体句库")
        let entryID = UUID()
        let entry = SentenceLibraryEntry(
            id: entryID,
            originalText: "Portable media",
            translation: "独立媒体",
            sourceMediaName: "missing-source.mp4",
            sourceMediaPath: "/does/not/exist.mp4",
            startTime: 20,
            endTime: 21,
            mediaFilename: "\(entryID.uuidString).m4a"
        )
        let sourceURL = temporaryDirectory.appendingPathComponent("exported-clip.m4a")
        let mediaData = Data("self-contained clip".utf8)
        try mediaData.write(to: sourceURL)

        try store.add(
            entries: [entry],
            previewData: [:],
            to: library.id,
            mediaURLs: [entryID: sourceURL]
        )

        let saved = try XCTUnwrap(store.entries(libraryID: library.id).first)
        let storedURL = try XCTUnwrap(store.mediaURL(for: saved, libraryID: library.id))
        XCTAssertEqual(try Data(contentsOf: storedURL), mediaData)

        try store.deleteEntries(ids: [entryID], from: library.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storedURL.path))
    }

    func testVersionOneLibraryMigratesToIndependentMediaSchema() throws {
        let libraryID = UUID()
        let packageURL = store.packageURL(for: libraryID)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().string(from: Date())
        let manifest: [String: Any] = [
            "format": SentenceLibraryDescriptor.formatIdentifier,
            "version": 1,
            "id": libraryID.uuidString,
            "name": "旧版句库",
            "createdAt": now,
            "updatedAt": now
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: packageURL.appendingPathComponent("manifest.json"))

        var database: OpaquePointer?
        let databaseURL = packageURL.appendingPathComponent("Library.sqlite3")
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let schema = """
        CREATE TABLE entries (
            id TEXT PRIMARY KEY NOT NULL,
            original_text TEXT NOT NULL DEFAULT '',
            translation TEXT NOT NULL DEFAULT '',
            note TEXT NOT NULL DEFAULT '',
            source_media_name TEXT NOT NULL DEFAULT '',
            source_media_path TEXT NOT NULL DEFAULT '',
            start_time REAL NOT NULL,
            end_time REAL NOT NULL,
            created_at REAL NOT NULL,
            preview_filename TEXT
        );
        PRAGMA user_version=1;
        """
        XCTAssertEqual(sqlite3_exec(database, schema, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        database = nil

        XCTAssertTrue(try store.entries(libraryID: libraryID).isEmpty)
        let entry = SentenceLibraryEntry(
            originalText: "Migrated",
            translation: "已迁移",
            sourceMediaName: "old.mp4",
            sourceMediaPath: "/missing.mp4",
            startTime: 0,
            endTime: 1,
            mediaFilename: "migrated-\(UUID().uuidString).m4a"
        )
        let sourceURL = temporaryDirectory.appendingPathComponent("migrated.m4a")
        try Data("migrated-media".utf8).write(to: sourceURL)
        try store.add(entries: [entry], previewData: [:], to: libraryID, mediaURLs: [entry.id: sourceURL])
        XCTAssertNotNil(try store.mediaURL(for: XCTUnwrap(store.entries(libraryID: libraryID).first), libraryID: libraryID))
    }
}
