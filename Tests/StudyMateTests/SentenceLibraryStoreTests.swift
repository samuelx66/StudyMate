import XCTest
@testable import StudyMateKit
import StudyMatePackage

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
        let contentURL = store.packageURL(for: library.id).appendingPathComponent("content.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: contentURL.path))
        let contentData = try Data(contentsOf: contentURL)
        let packageContent = try StudyMateLearningPackage.decode(StudyMatePackageContent.self, from: contentData)
        XCTAssertEqual(packageContent.entries.count, 2)
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

        // 测试原片序号时序排序（originalIndexFirst）：
        let third = SentenceLibraryEntry(
            originalIndex: 12,
            originalText: "third with orig 12",
            translation: "",
            sourceMediaName: "lesson-a.mp4",
            sourceMediaPath: "/lesson-a.mp4",
            startTime: 10,
            endTime: 12,
            createdAt: Date(timeIntervalSince1970: 300),
            mediaFilename: "third-\(UUID().uuidString).m4a"
        )
        let fourth = SentenceLibraryEntry(
            originalIndex: 88,
            originalText: "fourth with orig 88",
            translation: "",
            sourceMediaName: "lesson-a.mp4",
            sourceMediaPath: "/lesson-a.mp4",
            startTime: 50,
            endTime: 55,
            createdAt: Date(timeIntervalSince1970: 400),
            mediaFilename: "fourth-\(UUID().uuidString).m4a"
        )
        let thirdMediaURL = temporaryDirectory.appendingPathComponent("third.m4a")
        let fourthMediaURL = temporaryDirectory.appendingPathComponent("fourth.m4a")
        try Data("third audio".utf8).write(to: thirdMediaURL)
        try Data("fourth audio".utf8).write(to: fourthMediaURL)
        try store.add(entries: [fourth, third], previewData: [:], to: library.id, mediaURLs: [third.id: thirdMediaURL, fourth.id: fourthMediaURL])

        // 验证 originalIndexFirst：有原序号的按 originalIndex 升序，无原序号的排在后面
        let origSorted = try store.entries(libraryID: library.id, sortOrder: .originalIndexFirst)
        XCTAssertEqual(origSorted.map(\.id), [third.id, fourth.id, first.id, second.id])
    }

    func testUpdateEntryChangesTextAndRefreshesSearchIndex() throws {
        let library = try store.createLibrary(name: "可编辑句库")
        let entry = SentenceLibraryEntry(
            originalText: "The old sentence",
            translation: "旧译文",
            sourceMediaName: "lesson.mp4",
            sourceMediaPath: "/lesson.mp4",
            startTime: 0,
            endTime: 1,
            mediaFilename: "\(UUID().uuidString).m4a"
        )
        let mediaURL = temporaryDirectory.appendingPathComponent("editable.m4a")
        try Data("audio".utf8).write(to: mediaURL)
        try store.add(
            entries: [entry],
            previewData: [:],
            to: library.id,
            mediaURLs: [entry.id: mediaURL]
        )

        try store.updateEntry(
            id: entry.id,
            originalText: "The updated sentence",
            translation: "新的译文",
            in: library.id
        )

        let updated = try XCTUnwrap(store.entries(libraryID: library.id).first)
        XCTAssertEqual(updated.originalText, "The updated sentence")
        XCTAssertEqual(updated.translation, "新的译文")
        XCTAssertEqual(try store.entries(libraryID: library.id, searchText: "updated").map(\.id), [entry.id])
        XCTAssertEqual(try store.entries(libraryID: library.id, searchText: "新的").map(\.id), [entry.id])
        XCTAssertTrue(try store.entries(libraryID: library.id, searchText: "old").isEmpty)
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

    func testTagsManagementAndBatchOperations() throws {
        let library = try store.createLibrary(name: "标签测试句库")
        let id1 = UUID()
        let id2 = UUID()
        let entry1 = SentenceLibraryEntry(
            id: id1,
            originalText: "Sentence 1",
            translation: "句子1",
            sourceMediaName: "test.mp4",
            sourceMediaPath: "/tmp/test.mp4",
            startTime: 0,
            endTime: 1,
            mediaFilename: "\(id1.uuidString).m4a"
        )
        let entry2 = SentenceLibraryEntry(
            id: id2,
            originalText: "Sentence 2",
            translation: "句子2",
            sourceMediaName: "test.mp4",
            sourceMediaPath: "/tmp/test.mp4",
            startTime: 1,
            endTime: 2,
            mediaFilename: "\(id2.uuidString).m4a"
        )
        let mediaURL1 = temporaryDirectory.appendingPathComponent("test1.m4a")
        let mediaURL2 = temporaryDirectory.appendingPathComponent("test2.m4a")
        try Data("audio1".utf8).write(to: mediaURL1)
        try Data("audio2".utf8).write(to: mediaURL2)
        try store.add(
            entries: [entry1, entry2],
            previewData: [:],
            to: library.id,
            mediaURLs: [id1: mediaURL1, id2: mediaURL2]
        )

        // 1. Single entry updateTags
        try store.updateTags(id: entry1.id, tags: ["重点", "日常"], in: library.id)
        var allTags = try store.allTags(libraryID: library.id)
        XCTAssertEqual(allTags, ["日常", "重点"])

        // 2. Batch add tags (deduplicates "重点" on entry1)
        try store.batchAddTags(ids: [entry1.id, entry2.id], tags: ["口语", "重点"], in: library.id)
        let entriesAfterAdd = try store.entries(libraryID: library.id)
        let updated1 = try XCTUnwrap(entriesAfterAdd.first(where: { $0.id == entry1.id }))
        let updated2 = try XCTUnwrap(entriesAfterAdd.first(where: { $0.id == entry2.id }))
        XCTAssertEqual(updated1.tags, ["重点", "日常", "口语"])
        XCTAssertEqual(updated2.tags, ["口语", "重点"])

        allTags = try store.allTags(libraryID: library.id)
        XCTAssertEqual(allTags, ["口语", "日常", "重点"])

        // 3. Batch set tags
        try store.batchSetTags(ids: [entry1.id, entry2.id], tags: ["归档"], in: library.id)
        let entriesAfterSet = try store.entries(libraryID: library.id)
        XCTAssertEqual(entriesAfterSet.first(where: { $0.id == entry1.id })?.tags, ["归档"])
        XCTAssertEqual(entriesAfterSet.first(where: { $0.id == entry2.id })?.tags, ["归档"])

        allTags = try store.allTags(libraryID: library.id)
        XCTAssertEqual(allTags, ["归档"])
    }

    func testTypeFilterBookmarkedAndVocabularyOnly() throws {
        let library = try store.createLibrary(name: "类型筛选测试句库")
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        let card = StudyMatePackageVocabularyCard(
            word: "comprehension",
            phonetic: nil,
            definition: "理解"
        )

        let entry1 = SentenceLibraryEntry(
            id: id1,
            originalText: "This is a normal sentence.",
            translation: "普通句子",
            isBookmarked: false,
            associatedWords: nil,
            sourceMediaName: "test.mp4",
            sourceMediaPath: "/tmp/test.mp4",
            startTime: 0,
            endTime: 1,
            mediaFilename: "\(id1.uuidString).m4a"
        )
        let entry2 = SentenceLibraryEntry(
            id: id2,
            originalText: "This is a bookmarked sentence.",
            translation: "星标难句",
            isBookmarked: true,
            associatedWords: nil,
            sourceMediaName: "test.mp4",
            sourceMediaPath: "/tmp/test.mp4",
            startTime: 1,
            endTime: 2,
            mediaFilename: "\(id2.uuidString).m4a"
        )
        let entry3 = SentenceLibraryEntry(
            id: id3,
            originalText: "This sentence tests comprehension.",
            translation: "含生词句子",
            isBookmarked: false,
            associatedWords: [card],
            sourceMediaName: "test.mp4",
            sourceMediaPath: "/tmp/test.mp4",
            startTime: 2,
            endTime: 3,
            mediaFilename: "\(id3.uuidString).m4a"
        )

        let mediaURL1 = temporaryDirectory.appendingPathComponent("filter-test1.m4a")
        let mediaURL2 = temporaryDirectory.appendingPathComponent("filter-test2.m4a")
        let mediaURL3 = temporaryDirectory.appendingPathComponent("filter-test3.m4a")
        try Data("audio1".utf8).write(to: mediaURL1)
        try Data("audio2".utf8).write(to: mediaURL2)
        try Data("audio3".utf8).write(to: mediaURL3)

        try store.add(
            entries: [entry1, entry2, entry3],
            previewData: [:],
            to: library.id,
            mediaURLs: [id1: mediaURL1, id2: mediaURL2, id3: mediaURL3]
        )

        // 1. All filter
        let allEntries = try store.entries(libraryID: library.id, typeFilter: .all)
        XCTAssertEqual(allEntries.count, 3)

        // 2. Bookmarked only filter
        let bookmarkedEntries = try store.entries(libraryID: library.id, typeFilter: .bookmarkedOnly)
        XCTAssertEqual(bookmarkedEntries.count, 1)
        XCTAssertEqual(bookmarkedEntries.first?.id, id2)

        // 3. Vocabulary only filter
        let vocabEntries = try store.entries(libraryID: library.id, typeFilter: .withVocabularyOnly)
        XCTAssertEqual(vocabEntries.count, 1)
        XCTAssertEqual(vocabEntries.first?.id, id3)
        XCTAssertEqual(vocabEntries.first?.associatedWords?.first?.word, "comprehension")

        // 4. Batch update associated words
        try store.batchUpdateAssociatedWords([id1: [card]], in: library.id)
        let vocabEntriesAfterUpdate = try store.entries(libraryID: library.id, typeFilter: .withVocabularyOnly)
        XCTAssertEqual(vocabEntriesAfterUpdate.count, 2)
        XCTAssertTrue(vocabEntriesAfterUpdate.contains(where: { $0.id == id1 }))
        XCTAssertTrue(vocabEntriesAfterUpdate.contains(where: { $0.id == id3 }))
    }

    func testUpdateWordTokensAndContentJSONSync() throws {
        let library = try store.createLibrary(name: "词级时间戳同步测试句库")
        let entryID = UUID()
        let entry = SentenceLibraryEntry(
            id: entryID,
            originalText: "Hello world today",
            translation: "你好世界今天",
            isBookmarked: false,
            associatedWords: nil,
            sourceMediaName: "test.mp4",
            sourceMediaPath: "/tmp/test.mp4",
            startTime: 10,
            endTime: 12,
            mediaFilename: "\(entryID.uuidString).m4a"
        )
        let mediaURL = temporaryDirectory.appendingPathComponent("token-test.m4a")
        try Data("audio-bytes".utf8).write(to: mediaURL)

        try store.add(
            entries: [entry],
            previewData: [:],
            to: library.id,
            mediaURLs: [entryID: mediaURL]
        )

        // Verify initial state has nil word tokens
        let initialEntry = try XCTUnwrap(store.entries(libraryID: library.id).first)
        XCTAssertNil(initialEntry.wordTokens)

        // Update word tokens
        let tokens = [
            StudyMatePackageWordToken(text: "Hello", startTime: 0.0, endTime: 0.4, confidence: 0.95),
            StudyMatePackageWordToken(text: "world", startTime: 0.4, endTime: 0.8, confidence: 0.98),
            StudyMatePackageWordToken(text: "today", startTime: 0.8, endTime: 1.2, confidence: 0.92)
        ]
        try store.updateWordTokensAndText(
            id: entryID,
            originalText: "Hello world today",
            wordTokens: tokens,
            in: library.id
        )

        // Verify updated in database
        let updatedEntry = try XCTUnwrap(store.entries(libraryID: library.id).first)
        XCTAssertEqual(updatedEntry.wordTokens?.count, 3)
        XCTAssertEqual(updatedEntry.wordTokens?[0].text, "Hello")
        XCTAssertEqual(updatedEntry.wordTokens?[1].text, "world")
        XCTAssertEqual(updatedEntry.wordTokens?[2].text, "today")

        // Verify content.json sync
        let contentURL = store.packageURL(for: library.id).appendingPathComponent("content.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: contentURL.path))
        let contentData = try Data(contentsOf: contentURL)
        let packageContent = try JSONDecoder().decode(StudyMatePackageContent.self, from: contentData)
        XCTAssertEqual(packageContent.entries.first?.wordTokens?.count, 3)
        XCTAssertEqual(packageContent.entries.first?.wordTokens?[0].text, "Hello")
    }

    func testUpdateSourceMediaNameSingleAndBatch() throws {
        let library = try store.createLibrary(name: "来源测试句库")
        let entryID1 = UUID()
        let entryID2 = UUID()
        let entryID3 = UUID()
        let mediaURL1 = temporaryDirectory.appendingPathComponent("media1.m4a")
        let mediaURL2 = temporaryDirectory.appendingPathComponent("media2.m4a")
        let mediaURL3 = temporaryDirectory.appendingPathComponent("media3.m4a")
        try Data("audio 1".utf8).write(to: mediaURL1)
        try Data("audio 2".utf8).write(to: mediaURL2)
        try Data("audio 3".utf8).write(to: mediaURL3)

        let entry1 = SentenceLibraryEntry(
            id: entryID1,
            originalText: "Sentence 1",
            translation: "句子1",
            sourceMediaName: "Friends.S01E01.mp4",
            sourceMediaPath: "/media/Friends.S01E01.mp4",
            startTime: 0,
            endTime: 2,
            mediaFilename: "entry1.m4a"
        )
        let entry2 = SentenceLibraryEntry(
            id: entryID2,
            originalText: "Sentence 2",
            translation: "句子2",
            sourceMediaName: "Friends.S01E01.mp4",
            sourceMediaPath: "/media/Friends.S01E01.mp4",
            startTime: 2,
            endTime: 4,
            mediaFilename: "entry2.m4a"
        )
        let entry3 = SentenceLibraryEntry(
            id: entryID3,
            originalText: "Sentence 3",
            translation: "句子3",
            sourceMediaName: "Friends.S01E02.mp4",
            sourceMediaPath: "/media/Friends.S01E02.mp4",
            startTime: 0,
            endTime: 2,
            mediaFilename: "entry3.m4a"
        )

        try store.add(
            entries: [entry1, entry2, entry3],
            previewData: [:],
            to: library.id,
            mediaURLs: [entryID1: mediaURL1, entryID2: mediaURL2, entryID3: mediaURL3]
        )

        // 1. Single entry update without applying to all
        let updatedSingleCount = try store.updateSourceMediaName(
            entryID: entryID1,
            oldSourceName: "Friends.S01E01.mp4",
            newSourceName: "老友记 单独句",
            applyToAllWithSameSource: false,
            in: library.id
        )
        XCTAssertEqual(updatedSingleCount, 1)

        var entries = try store.entries(libraryID: library.id)
        XCTAssertEqual(entries.first(where: { $0.id == entryID1 })?.sourceMediaName, "老友记 单独句")
        XCTAssertEqual(entries.first(where: { $0.id == entryID2 })?.sourceMediaName, "Friends.S01E01.mp4")

        // 2. Batch update for all entries matching oldSourceName
        let updatedBatchCount = try store.updateSourceMediaName(
            entryID: entryID2,
            oldSourceName: "Friends.S01E01.mp4",
            newSourceName: "老友记 第一集",
            applyToAllWithSameSource: true,
            in: library.id
        )
        XCTAssertEqual(updatedBatchCount, 1)

        entries = try store.entries(libraryID: library.id)
        XCTAssertEqual(entries.first(where: { $0.id == entryID2 })?.sourceMediaName, "老友记 第一集")

        // 3. Batch update specific IDs
        let updatedIDsCount = try store.batchUpdateSourceMediaName(
            ids: [entryID1, entryID3],
            newSourceName: "老友记 精选",
            in: library.id
        )
        XCTAssertEqual(updatedIDsCount, 2)

        entries = try store.entries(libraryID: library.id)
        XCTAssertEqual(entries.first(where: { $0.id == entryID1 })?.sourceMediaName, "老友记 精选")
        XCTAssertEqual(entries.first(where: { $0.id == entryID3 })?.sourceMediaName, "老友记 精选")

        // 4. Verify content.json sync
        let contentURL = store.packageURL(for: library.id).appendingPathComponent("content.json")
        let contentData = try Data(contentsOf: contentURL)
        let packageContent = try StudyMateLearningPackage.decode(StudyMatePackageContent.self, from: contentData)
        let entry1JSON = packageContent.entries.first(where: { $0.id == entryID1 })
        XCTAssertEqual(entry1JSON?.source?.mediaTitle, "老友记 精选")
    }

    func testRenameLibraryAndEntryCount() throws {
        let library = try store.createLibrary(name: "原始库名")
        XCTAssertEqual(store.entryCount(libraryID: library.id), 0)

        let entryID = UUID()
        let audioURL = temporaryDirectory.appendingPathComponent("test.m4a")
        try Data("dummy audio".utf8).write(to: audioURL)
        let entry = SentenceLibraryEntry(
            id: entryID,
            originalText: "Hello world",
            translation: "你好世界",
            sourceMediaName: "test.mp4",
            sourceMediaPath: "/test.mp4",
            startTime: 0,
            endTime: 1,
            mediaFilename: "\(entryID.uuidString).m4a"
        )
        try store.add(entries: [entry], previewData: [:], to: library.id, mediaURLs: [entryID: audioURL])
        XCTAssertEqual(store.entryCount(libraryID: library.id), 1)

        try store.renameLibrary(id: library.id, newName: "新句库名称")
        let libraries = store.listLibraries()
        let renamed = libraries.first(where: { $0.id == library.id })
        XCTAssertEqual(renamed?.name, "新句库名称")

        let manifest = store.readManifest(at: store.packageURL(for: library.id))
        XCTAssertEqual(manifest?.name, "新句库名称")
    }
}

