import XCTest
@testable import StudyMateKit

@MainActor
final class SentenceLibraryManagerTests: XCTestCase {
    func testUpdateEntryRefreshesVisibleSnapshotBeforeReturning() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudyMate-SentenceLibraryManagerTests-(UUID().uuidString)", isDirectory: true)
        let store = SentenceLibraryStore(rootURL: root)
        let defaultsSuite = "StudyMate-SentenceLibraryManagerTests-(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
            try? FileManager.default.removeItem(at: root)
        }

        let library = try store.createLibrary(name: "句库编辑测试")
        let entry = SentenceLibraryEntry(
            originalText: "原文旧值",
            translation: "译文旧值",
            sourceMediaName: "lesson.mp4",
            sourceMediaPath: "/lesson.mp4",
            startTime: 0,
            endTime: 1,
            mediaFilename: "(UUID().uuidString).m4a"
        )
        let mediaURL = root.appendingPathComponent("entry.m4a")
        try Data("media".utf8).write(to: mediaURL)
        try store.add(entries: [entry], previewData: [:], to: library.id, mediaURLs: [entry.id: mediaURL])

        let manager = SentenceLibraryManager(store: store, defaults: defaults)
        try await waitUntil {
            manager.currentLibraryID == library.id && manager.entries.contains(where: { $0.id == entry.id })
        }

        try await manager.updateEntry(
            id: entry.id,
            originalText: "原文新值",
            translation: "译文新值"
        )

        let visibleEntry = try XCTUnwrap(manager.entries.first(where: { $0.id == entry.id }))
        XCTAssertEqual(visibleEntry.originalText, "原文新值")
        XCTAssertEqual(visibleEntry.translation, "译文新值")
        let persistedEntry = try XCTUnwrap(store.entries(libraryID: library.id).first(where: { $0.id == entry.id }))
        XCTAssertEqual(persistedEntry.originalText, "原文新值")
        XCTAssertEqual(persistedEntry.translation, "译文新值")
    }

    func testUpdateEntryFromPlaybackUpdatesDatabaseMemoryAndShowsStatusBarSuccess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudyMate-PlaybackSyncTests-\(UUID().uuidString)", isDirectory: true)
        let store = SentenceLibraryStore(rootURL: root)
        let defaultsSuite = "StudyMate-PlaybackSyncTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
            try? FileManager.default.removeItem(at: root)
        }

        let library = try store.createLibrary(name: "回写测试句库")
        let entry = SentenceLibraryEntry(
            originalText: "Original Before",
            translation: "译文前",
            sourceMediaName: "lesson.mp4",
            sourceMediaPath: "/lesson.mp4",
            startTime: 0,
            endTime: 1,
            mediaFilename: "\(UUID().uuidString).m4a"
        )
        let mediaURL = root.appendingPathComponent("entry.m4a")
        try Data("media".utf8).write(to: mediaURL)
        try store.add(entries: [entry], previewData: [:], to: library.id, mediaURLs: [entry.id: mediaURL])

        let manager = SentenceLibraryManager(store: store, defaults: defaults)
        try await waitUntil {
            manager.currentLibraryID == library.id && manager.entries.contains(where: { $0.id == entry.id })
        }

        try await manager.updateEntryFromPlayback(
            id: entry.id,
            originalText: "Original After",
            translation: "译文后",
            sentenceIndex: 1,
            in: library.id
        )

        let visibleEntry = try XCTUnwrap(manager.entries.first(where: { $0.id == entry.id }))
        XCTAssertEqual(visibleEntry.originalText, "Original After")
        XCTAssertEqual(visibleEntry.translation, "译文后")
        let persistedEntry = try XCTUnwrap(store.entries(libraryID: library.id).first(where: { $0.id == entry.id }))
        XCTAssertEqual(persistedEntry.originalText, "Original After")
        XCTAssertEqual(persistedEntry.translation, "译文后")
        XCTAssertNotNil(MainStatusCenter.shared.successMessage)
    }

    func testUpdateSourceMediaNameUpdatesSelectedSourceAndAvailableSources() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudyMate-SourceUpdateTests-\(UUID().uuidString)", isDirectory: true)
        let store = SentenceLibraryStore(rootURL: root)
        let defaultsSuite = "StudyMate-SourceUpdateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
            try? FileManager.default.removeItem(at: root)
        }

        let library = try store.createLibrary(name: "来源更新测试")
        let entry1 = SentenceLibraryEntry(
            originalText: "Sentence 1",
            translation: "句子 1",
            sourceMediaName: "02",
            sourceMediaPath: "/02.mp4",
            startTime: 0,
            endTime: 1,
            mediaFilename: "\(UUID().uuidString).m4a"
        )
        let entry2 = SentenceLibraryEntry(
            originalText: "Sentence 2",
            translation: "句子 2",
            sourceMediaName: "02",
            sourceMediaPath: "/02.mp4",
            startTime: 1,
            endTime: 2,
            mediaFilename: "\(UUID().uuidString).m4a"
        )
        let mediaURL1 = root.appendingPathComponent("e1.m4a")
        let mediaURL2 = root.appendingPathComponent("e2.m4a")
        try Data("m1".utf8).write(to: mediaURL1)
        try Data("m2".utf8).write(to: mediaURL2)
        try store.add(entries: [entry1, entry2], previewData: [:], to: library.id, mediaURLs: [entry1.id: mediaURL1, entry2.id: mediaURL2])

        let manager = SentenceLibraryManager(store: store, defaults: defaults)
        try await waitUntil {
            manager.currentLibraryID == library.id && manager.entries.count == 2 && manager.availableSources.contains("02")
        }

        manager.setSelectedSource("02")
        XCTAssertEqual(manager.selectedSource, "02")

        try await manager.updateSourceMediaName(
            entryID: entry1.id,
            oldSourceName: "02",
            newSourceName: "ACT1-02",
            applyToAllWithSameSource: true
        )

        try await waitUntil {
            manager.selectedSource == "ACT1-02" && manager.availableSources.contains("ACT1-02") && !manager.availableSources.contains("02")
        }
        XCTAssertEqual(manager.selectedSource, "ACT1-02")
        XCTAssertTrue(manager.entries.allSatisfy { $0.sourceMediaName == "ACT1-02" })
    }

    func testBatchUpdateSourceMediaNameUpdatesSelectedSourceAndAvailableSources() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudyMate-BatchSourceUpdateTests-\(UUID().uuidString)", isDirectory: true)
        let store = SentenceLibraryStore(rootURL: root)
        let defaultsSuite = "StudyMate-BatchSourceUpdateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
            try? FileManager.default.removeItem(at: root)
        }

        let library = try store.createLibrary(name: "批量来源更新测试")
        let entry1 = SentenceLibraryEntry(
            originalText: "Sentence A",
            translation: "句子 A",
            sourceMediaName: "OldSource",
            sourceMediaPath: "/old.mp4",
            startTime: 0,
            endTime: 1,
            mediaFilename: "\(UUID().uuidString).m4a"
        )
        let mediaURL1 = root.appendingPathComponent("ea.m4a")
        try Data("ma".utf8).write(to: mediaURL1)
        try store.add(entries: [entry1], previewData: [:], to: library.id, mediaURLs: [entry1.id: mediaURL1])

        let manager = SentenceLibraryManager(store: store, defaults: defaults)
        try await waitUntil {
            manager.currentLibraryID == library.id && manager.entries.count == 1 && manager.availableSources.contains("OldSource")
        }

        manager.setSelectedSource("OldSource")
        XCTAssertEqual(manager.selectedSource, "OldSource")

        try await manager.batchUpdateSourceMediaName(
            for: [entry1.id],
            newSourceName: "NewSource"
        )

        try await waitUntil {
            manager.selectedSource == "NewSource" && manager.availableSources.contains("NewSource") && !manager.availableSources.contains("OldSource")
        }
        XCTAssertEqual(manager.selectedSource, "NewSource")
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                XCTFail("句库管理器未在限定时间内加载测试条目")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
