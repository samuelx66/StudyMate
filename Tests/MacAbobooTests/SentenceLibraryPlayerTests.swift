import XCTest
@testable import MacAbobooKit

@MainActor
final class SentenceLibraryPlayerTests: XCTestCase {
    func testPlayingEntryLoadsIndependentClipFromZero() async throws {
        let mediaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-LibraryPlayer-\(UUID().uuidString).m4a")
        try Data("test-media".utf8).write(to: mediaURL)
        defer { try? FileManager.default.removeItem(at: mediaURL) }

        let backend = TestMediaPlayerBackend(duration: 60)
        let player = SentenceLibraryPlayer(nativeBackend: backend)
        let entry = makeEntry(path: mediaURL.path, start: 12.5, end: 14.75)

        player.play(entry, mediaURL: mediaURL)
        for _ in 0..<4 { await Task.yield() }

        XCTAssertEqual(backend.loadedURL, mediaURL)
        XCTAssertEqual(backend.currentTime, 0, accuracy: 0.001)
        XCTAssertTrue(backend.isPlaying)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.duration, 2.25, accuracy: 0.001)

        backend.emitTime(2.25)
        XCTAssertFalse(backend.isPlaying)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTime, 2.25, accuracy: 0.001)
    }

    func testMissingIndependentClipReportsReadableErrorWithoutLoadingBackend() {
        let backend = TestMediaPlayerBackend()
        let player = SentenceLibraryPlayer(nativeBackend: backend)

        player.play(makeEntry(path: "/path/that/does/not/exist.mp4", start: 1, end: 2))

        XCTAssertEqual(backend.loadCount, 0)
        XCTAssertNotNil(player.errorMessage)
        XCTAssertFalse(player.isPlaying)
    }

    func testPlayingIndependentClipStartsAtZeroInsteadOfOriginalTimestamp() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-LibraryClip-\(UUID().uuidString).m4a")
        let originalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-MissingOriginal-\(UUID().uuidString).mp4")
        try Data("self-contained-media".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let backend = TestMediaPlayerBackend(duration: 3)
        let player = SentenceLibraryPlayer(nativeBackend: backend)
        let entry = SentenceLibraryEntry(
            originalText: "Independent",
            translation: "独立片段",
            sourceMediaName: "original.mp4",
            sourceMediaPath: originalURL.path,
            startTime: 120,
            endTime: 123,
            mediaFilename: "clip.m4a"
        )

        player.play(entry, mediaURL: sourceURL)
        for _ in 0..<4 { await Task.yield() }

        XCTAssertEqual(backend.loadedURL, sourceURL)
        XCTAssertEqual(backend.currentTime, 0, accuracy: 0.001)
        XCTAssertEqual(player.duration, 3, accuracy: 0.001)
        XCTAssertTrue(player.isPlaying)
    }

    func testSingleLoopRestartsTheSelectedLibrarySentence() async throws {
        let mediaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-LibraryLoop-\(UUID().uuidString).m4a")
        try Data("loop-media".utf8).write(to: mediaURL)
        defer { try? FileManager.default.removeItem(at: mediaURL) }

        let backend = TestMediaPlayerBackend(duration: 1)
        let player = SentenceLibraryPlayer(nativeBackend: backend)
        let entry = SentenceLibraryEntry(
            originalText: "loop",
            translation: "循环",
            sourceMediaName: "lesson.mp4",
            sourceMediaPath: mediaURL.path,
            startTime: 0,
            endTime: 1,
            mediaFilename: "loop.m4a"
        )
        player.setPlaybackMode(.singleLoop)
        player.setPlaylist(entries: [entry], mediaURLs: [entry.id: mediaURL])
        player.play(entry, mediaURL: mediaURL)
        await Task.yield()

        backend.emitTime(1)
        await Task.yield()

        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(backend.currentTime, 0, accuracy: 0.001)
        XCTAssertEqual(player.currentTime, 0, accuracy: 0.001)
    }

    func testAllLoopAdvancesThroughVisibleLibraryPlaylist() async throws {
        let firstURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-LibraryFirst-\(UUID().uuidString).m4a")
        let secondURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-LibrarySecond-\(UUID().uuidString).m4a")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let backend = TestMediaPlayerBackend(duration: 1)
        let player = SentenceLibraryPlayer(nativeBackend: backend)
        let first = SentenceLibraryEntry(
            originalText: "one",
            translation: "一",
            sourceMediaName: "lesson.mp4",
            sourceMediaPath: firstURL.path,
            startTime: 0,
            endTime: 1,
            mediaFilename: "one.m4a"
        )
        let second = SentenceLibraryEntry(
            originalText: "two",
            translation: "二",
            sourceMediaName: "lesson.mp4",
            sourceMediaPath: secondURL.path,
            startTime: 0,
            endTime: 1,
            mediaFilename: "two.m4a"
        )
        player.setPlaybackMode(.allLoop)
        player.setPlaylist(entries: [first, second], mediaURLs: [first.id: firstURL, second.id: secondURL])
        player.play(first, mediaURL: firstURL)
        await Task.yield()

        backend.emitTime(1)
        await Task.yield()

        XCTAssertEqual(player.currentEntry?.id, second.id)
        XCTAssertEqual(backend.loadedURL, secondURL)
        XCTAssertTrue(player.isPlaying)
    }

    private func makeEntry(path: String, start: Double, end: Double) -> SentenceLibraryEntry {
        SentenceLibraryEntry(
            originalText: "Original",
            translation: "译文",
            sourceMediaName: URL(fileURLWithPath: path).lastPathComponent,
            sourceMediaPath: path,
            startTime: start,
            endTime: end,
            mediaFilename: "clip-\(UUID().uuidString).m4a"
        )
    }
}
