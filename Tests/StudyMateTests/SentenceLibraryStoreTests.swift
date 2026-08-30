import XCTest
@testable import StudyMateKit

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
            .appendingPathComponent("StudyMate-SentenceLibraryTests-\(UUID().uuidString)", isDirectory: true)
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
        let oldEntryID = UUID()
        let oldMediaURL = temporaryDirectory.appendingPathComponent("old-source.m4a")
        let newMediaURL = temporaryDirectory.appendingPathComponent("new-source.m4a")
        try Data("old audio".utf8).write(to: oldMediaURL)
        try Data("new audio".utf8).write(to: newMediaURL)
        let oldEntry = SentenceLibraryEntry(
            id: oldEntryID,
            originalText: "An older sentence",
            translation: "较早的句子",
            sourceMediaName: "old.mp4",
            sourceMediaPath: "/old.mp4",
            startTime: 1,
            endTime: 2,
            createdAt: Date(timeIntervalSince1970: 1_000),
            mediaFilename: "\(oldEntryID.uuidString).m4a"
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
            mediaFilename: "\(newEntryID.uuidString).m4a",
            previewFilename: "\(newEntryID.uuidString).jpg"
        )
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xD9])

        try store.add(
            entries: [oldEntry, newEntry],
            previewData: [newEntry.id: imageData],
            to: library.id,
            mediaURLs: [oldEntry.id: oldMediaURL, newEntry.id: newMediaURL]
        )

        XCTAssertEqual(try store.entries(libraryID: library.id).count, 2)
        XCTAssertEqual(try store.entries(libraryID: library.id, searchText: "检索").map(\.id), [newEntry.id])
        XCTAssertEqual(try store.entries(libraryID: library.id, searchText: "searchable").map(\.id), [newEntry.id])
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
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.mediaURL(for: newEntry, libraryID: library.id)?.path ?? ""
        ))
    }

    func testEntriesCanFilterBySourceAndSortByImportTime() throws {
        let library = try store.createLibrary(name: "来源筛选")
        let firstMediaURL = temporaryDirectory.appendingPathComponent("first-source.m4a")
        let secondMediaURL = temporaryDirectory.appendingPathComponent("second-source.m4a")
        try Data("first audio".utf8).write(to: firstMediaURL)
        try Data("second audio".utf8).write(to: secondMediaURL)
        let first = SentenceLibraryEntry(
            originalText: "first",
            translation: "",
            sourceMediaName: "lesson-a.mp4",
            sourceMediaPath: "/lesson-a.mp4",
            startTime: 0,
            endTime: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            mediaFilename: "first-\(UUID().uuidString).m4a"
        )
        let second = SentenceLibraryEntry(
            originalText: "second",
            translation: "",
            sourceMediaName: "lesson-b.mp4",
            sourceMediaPath: "/lesson-b.mp4",
            startTime: 1,
            endTime: 2,
            createdAt: Date(timeIntervalSince1970: 200),
            mediaFilename: "second-\(UUID().uuidString).m4a"
        )
        try store.add(
            entries: [first, second],
            previewData: [:],
            to: library.id,
            mediaURLs: [first.id: firstMediaURL, second.id: secondMediaURL]
        )

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

    func testLegacyLibraryVersionsAreMigratedInPlace() throws {
        let libraryID = UUID()
        let packageURL = store.packageURL(for: libraryID)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().string(from: Date())
        let manifest: [String: Any] = [
            "format": SentenceLibraryDescriptor.formatIdentifier,
            "version": 1,
            "id": libraryID.uuidString,
            "name": "不支持的句库",
            "createdAt": now,
            "updatedAt": now
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: packageURL.appendingPathComponent("manifest.json"))

        XCTAssertEqual(store.listLibraries().map(\.id), [libraryID])
        XCTAssertEqual(try store.entries(libraryID: libraryID).count, 0)
        let migratedManifest = try Data(contentsOf: packageURL.appendingPathComponent("manifest.json"))
        let migratedObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: migratedManifest) as? [String: Any])
        XCTAssertEqual(migratedObject["version"] as? Int, SentenceLibraryDescriptor.currentFormatVersion)
    }

    func testDefaultLibraryCannotBeDeleted() throws {
        let library = try store.createLibrary(name: "默认句库")
        XCTAssertThrowsError(try store.deleteLibrary(id: library.id)) { error in
            guard case SentenceLibraryError.defaultLibraryCannotBeDeleted = error else {
                return XCTFail("Expected default-library protection, got \(error)")
            }
        }
        XCTAssertEqual(store.listLibraries().map(\.id), [library.id])
    }

    func testMoveEntriesPreservesTextMediaAndPreview() throws {
        let source = try store.createLibrary(name: "源句库")
        let destination = try store.createLibrary(name: "目标句库")
        let entryID = UUID()
        let entry = SentenceLibraryEntry(
            id: entryID,
            originalText: "Move me",
            translation: "移动我",
            note: "note",
            sourceMediaName: "lesson.mp4",
            sourceMediaPath: "/lesson.mp4",
            startTime: 1,
            endTime: 2,
            createdAt: Date(timeIntervalSince1970: 1234),
            mediaFilename: "\(entryID.uuidString).m4a",
            previewFilename: "\(entryID.uuidString).jpg"
        )
        let mediaURL = temporaryDirectory.appendingPathComponent("source.m4a")
        let mediaData = Data("portable audio".utf8)
        try mediaData.write(to: mediaURL)
        let previewData = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try store.add(
            entries: [entry],
            previewData: [entry.id: previewData],
            to: source.id,
            mediaURLs: [entry.id: mediaURL]
        )

        try store.moveEntries(ids: [entry.id], from: source.id, to: destination.id)

        XCTAssertTrue(try store.entries(libraryID: source.id).isEmpty)
        let moved = try XCTUnwrap(store.entries(libraryID: destination.id).first)
        XCTAssertEqual(moved.originalText, entry.originalText)
        XCTAssertEqual(moved.translation, entry.translation)
        XCTAssertEqual(moved.note, entry.note)
        XCTAssertEqual(moved.sourceMediaName, entry.sourceMediaName)
        let movedMediaURL = try XCTUnwrap(store.mediaURL(for: moved, libraryID: destination.id))
        XCTAssertEqual(try Data(contentsOf: movedMediaURL), mediaData)
        let movedPreviewURL = try XCTUnwrap(store.previewURL(for: moved, libraryID: destination.id))
        XCTAssertEqual(try Data(contentsOf: movedPreviewURL), previewData)
    }
}
