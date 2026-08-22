import XCTest
@testable import MacAbobooKit

final class ProjectFileManagerTests: XCTestCase {
    func testSaveAndLoadIndividualProjectFile() {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-ProjectTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let manager = ProjectFileManager(baseDirectory: testDirectory)
        let dummyMediaURL = testDirectory.appendingPathComponent("lesson_01.mp3")
        FileManager.default.createFile(atPath: dummyMediaURL.path, contents: Data("media".utf8))
        
        let segments = [
            SentenceSegment(index: 1, startTime: 0.5, endTime: 4.2, text: "Good morning class.", translation: "大家早上好。"),
            SentenceSegment(index: 2, startTime: 4.5, endTime: 9.0, text: "Please open your books.", isBookmarked: true)
        ]
        
        let waveform = WaveformData(
            peaks: [0.5, 0.8, 0.2, 0.3],
            duration: 10.0,
            sampleRate: 100
        )
        
        manager.saveProject(
            for: dummyMediaURL,
            title: "Lesson 01",
            duration: 10.0,
            lastPosition: 4.5,
            segments: segments,
            waveformData: waveform,
            persistWaveform: true
        )
        manager.flush()

        let loaded = manager.loadProject(for: dummyMediaURL)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.mediaTitle, "Lesson 01")
        XCTAssertEqual(loaded?.segments.count, 2)
        XCTAssertEqual(loaded?.segments[0].text, "Good morning class.")
        XCTAssertEqual(loaded?.segments[0].translation, "大家早上好。")
        XCTAssertTrue(loaded?.segments[1].isBookmarked ?? false)
        XCTAssertEqual(loaded?.waveformData?.peaks.count, 4)

        let metadata = try? String(contentsOf: manager.projectFileURL(for: dummyMediaURL), encoding: .utf8)
        XCTAssertFalse(metadata?.contains("\"peaks\"") ?? true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.waveformFileURL(for: dummyMediaURL).path))
        XCTAssertTrue(loaded?.isCompatible(with: dummyMediaURL) ?? false)

        try? Data("changed media contents".utf8).write(to: dummyMediaURL, options: .atomic)
        XCTAssertFalse(loaded?.isCompatible(with: dummyMediaURL) ?? true)
    }
}
