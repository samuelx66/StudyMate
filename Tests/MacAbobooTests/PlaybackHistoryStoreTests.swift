import XCTest
@testable import MacAbobooKit

@MainActor
final class PlaybackHistoryStoreTests: XCTestCase {
    func testHistoryPersistsInsertionOrderWithoutDuplicates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-HistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("first.mp3")
        let second = directory.appendingPathComponent("second.mp4")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)

        let store = PlaybackHistoryStore(storageDirectory: directory)
        store.recordPlayed(first)
        store.add([second, first])

        XCTAssertEqual(store.entries.map(\.mediaPath), [first.path, second.path])
        store.flush()

        let reloaded = PlaybackHistoryStore(storageDirectory: directory)
        XCTAssertEqual(reloaded.entries.map(\.mediaPath), [first.path, second.path])

        reloaded.remove(first)
        reloaded.flush()
        let afterRemoval = PlaybackHistoryStore(storageDirectory: directory)
        XCTAssertEqual(afterRemoval.entries.map(\.mediaPath), [second.path])
    }
}
