import XCTest
@testable import MacAbobooKit

final class SegmentationStoreTests: XCTestCase {
    func testSaveAndLoadProject() {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-SQLiteTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let store = SegmentationStore(databaseURL: testDirectory.appendingPathComponent("projects.sqlite3"))
        let dummyURL = testDirectory.appendingPathComponent("dummy_test_media.mp4")
        
        let segments = [
            SentenceSegment(index: 1, startTime: 0.0, endTime: 3.5, text: "Sentence 1", isBookmarked: true),
            SentenceSegment(index: 2, startTime: 3.5, endTime: 7.0, text: "Sentence 2", translation: "第二句")
        ]
        
        store.saveProject(
            for: dummyURL,
            title: "Test Media",
            duration: 10.0,
            lastPosition: 2.0,
            segments: segments
        )
        
        store.flush()
        let loaded = store.loadProject(for: dummyURL)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.title, "Test Media")
        XCTAssertEqual(loaded?.segments.count, 2)
        XCTAssertEqual(loaded?.segments[0].text, "Sentence 1")
        XCTAssertTrue(loaded?.segments[0].isBookmarked ?? false)
        XCTAssertEqual(loaded?.segments[1].translation, "第二句")
    }
}
