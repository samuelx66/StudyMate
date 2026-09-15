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
