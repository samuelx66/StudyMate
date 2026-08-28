import XCTest
@testable import MacAbobooKit

final class ProjectFileManagerTests: XCTestCase {
    func testCompletedEmptySegmentationStatePersists() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-EmptyProjectTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("silence.wav")
        try Data("media".utf8).write(to: mediaURL)
        let manager = ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))

        manager.saveProject(
            for: mediaURL,
            title: "silence",
            duration: 8,
            lastPosition: 0,
            segments: [],
            hasCompletedSegmentation: true
        )
        manager.flush()

        let restored = try XCTUnwrap(manager.loadProject(for: mediaURL))
        XCTAssertTrue(restored.segments.isEmpty)
        XCTAssertTrue(restored.hasCompletedSegmentation)
        XCTAssertEqual(restored.schemaVersion, MediaProjectFile.currentSchemaVersion)
    }

    func testDeleteProjectRemovesMetadataAndWaveformRecords() throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-ProjectDeletionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let manager = ProjectFileManager(baseDirectory: testDirectory)
        let mediaURL = testDirectory.appendingPathComponent("lesson.mp3")
        try Data("media".utf8).write(to: mediaURL)

        manager.saveProject(
            for: mediaURL,
            title: "Lesson",
            duration: 3,
            lastPosition: 1,
            segments: [SentenceSegment(index: 1, startTime: 0, endTime: 3)],
            waveformData: WaveformData(peaks: [0.1, 0.5], duration: 3, sampleRate: 100),
            persistWaveform: true
        )
        manager.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.projectFileURL(for: mediaURL).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.waveformFileURL(for: mediaURL).path))

        try manager.deleteProject(for: mediaURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.projectFileURL(for: mediaURL).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.waveformFileURL(for: mediaURL).path))
    }

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
        let acousticBoundaries = [9.0, 4.5, 4.5, -1.0, .infinity]
        
        manager.saveProject(
            for: dummyMediaURL,
            title: "Lesson 01",
            duration: 10.0,
            lastPosition: 4.5,
            segments: segments,
            waveformData: waveform,
            persistWaveform: true,
            acousticBoundaryTimes: acousticBoundaries
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
        XCTAssertEqual(loaded?.acousticBoundaryTimes, [4.5, 9.0])

        try? Data("changed media contents".utf8).write(to: dummyMediaURL, options: .atomic)
        XCTAssertFalse(loaded?.isCompatible(with: dummyMediaURL) ?? true)
    }

    func testUnsupportedProjectSchemaIsIgnored() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-UnsupportedProjectTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mediaURL = directory.appendingPathComponent("unsupported.mp3")
        try Data("media".utf8).write(to: mediaURL)
        let manager = ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        let metadataURL = manager.projectFileURL(for: mediaURL)
        let unsupportedJSON = """
        {"schemaVersion":3,"mediaPath":"\(mediaURL.path)","mediaTitle":"unsupported","duration":5,"lastPosition":0,"segments":[],"hasCompletedSegmentation":true,"updatedAt":"1970-01-01T00:00:00Z"}
        """
        try Data(unsupportedJSON.utf8).write(to: metadataURL)

        XCTAssertNil(manager.loadProject(for: mediaURL))
    }

    func testRapidSavesPersistLatestMetadataSnapshot() throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-CoalescedSaveTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let manager = ProjectFileManager(baseDirectory: testDirectory)
        let mediaURL = testDirectory.appendingPathComponent("lesson.mp3")
        try Data("media".utf8).write(to: mediaURL)

        for position in 0..<100 {
            manager.saveProject(
                for: mediaURL,
                title: "Lesson",
                duration: 120,
                lastPosition: Double(position),
                segments: [SentenceSegment(index: 1, startTime: 0, endTime: Double(position + 1))]
            )
        }
        manager.flush()

        let loaded = manager.loadProject(for: mediaURL)
        XCTAssertEqual(loaded?.lastPosition, 99)
        XCTAssertEqual(loaded?.segments.first?.endTime, 100)
    }

    func testIdenticalSnapshotDoesNotRewriteProjectMetadata() throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-SnapshotSkipTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let manager = ProjectFileManager(baseDirectory: testDirectory)
        let mediaURL = testDirectory.appendingPathComponent("lesson.mp3")
        try Data("media".utf8).write(to: mediaURL)
        let segment = SentenceSegment(index: 1, startTime: 0, endTime: 3, text: "Hello")

        manager.saveProject(
            for: mediaURL,
            title: "Lesson",
            duration: 3,
            lastPosition: 1.25,
            segments: [segment],
            hasCompletedSegmentation: true
        )
        manager.flush()
        let firstData = try Data(contentsOf: manager.projectFileURL(for: mediaURL))

        manager.saveProject(
            for: mediaURL,
            title: "Lesson",
            duration: 3,
            lastPosition: 1.25,
            segments: [segment],
            hasCompletedSegmentation: true
        )
        manager.flush()
        let secondData = try Data(contentsOf: manager.projectFileURL(for: mediaURL))

        XCTAssertEqual(secondData, firstData)
    }

    func testLightweightSaveDoesNotDropPendingWaveformPersistence() throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-WaveformCarryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let manager = ProjectFileManager(baseDirectory: testDirectory)
        let mediaURL = testDirectory.appendingPathComponent("lesson.mp3")
        try Data("media".utf8).write(to: mediaURL)
        let waveform = WaveformData(peaks: [0.1, 0.4, 0.8], duration: 3, sampleRate: 100)

        manager.saveProject(
            for: mediaURL,
            title: "Initial",
            duration: 3,
            lastPosition: 0,
            segments: [],
            waveformData: waveform,
            persistWaveform: true
        )
        manager.saveProject(
            for: mediaURL,
            title: "Latest",
            duration: 3,
            lastPosition: 2,
            segments: [SentenceSegment(index: 1, startTime: 0, endTime: 3)]
        )
        manager.flush()

        let loaded = manager.loadProject(for: mediaURL)
        XCTAssertEqual(loaded?.mediaTitle, "Latest")
        XCTAssertEqual(loaded?.lastPosition, 2)
        XCTAssertEqual(loaded?.waveformData?.peaks, waveform.peaks)
    }
}
