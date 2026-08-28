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

    func testLegacyProjectSchemaIsMigratedAndPreservesEditedSubtitles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-LegacyProjectTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mediaURL = directory.appendingPathComponent("legacy.mp3")
        try Data("media".utf8).write(to: mediaURL)
        let manager = ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        let metadataURL = manager.projectFileURL(for: mediaURL)
        let legacyJSON = """
        {"schemaVersion":3,"mediaPath":"\(mediaURL.path)","mediaTitle":"legacy","duration":5,"lastPosition":0,"segments":[{"index":1,"startTime":0.25,"endTime":2.5,"text":"Edited original","translation":"编辑后的译文"}],"hasCompletedSegmentation":true,"updatedAt":"1970-01-01T00:00:00Z"}
        """
        try Data(legacyJSON.utf8).write(to: metadataURL)

        let result = manager.loadProjectResult(for: mediaURL)
        guard case .loaded(let project, let needsMigration) = result else {
            return XCTFail("Expected a migrated legacy project")
        }
        XCTAssertTrue(needsMigration)
        XCTAssertEqual(project.schemaVersion, MediaProjectFile.currentSchemaVersion)
        XCTAssertEqual(project.segments.first?.text, "Edited original")
        XCTAssertEqual(project.segments.first?.translation, "编辑后的译文")
    }

    func testFutureProjectSchemaIsUnavailableAndNotTreatedAsMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-FutureProjectTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mediaURL = directory.appendingPathComponent("future.mp3")
        try Data("media".utf8).write(to: mediaURL)
        let manager = ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        let metadataURL = manager.projectFileURL(for: mediaURL)
        let futureJSON = """
        {"schemaVersion":99,"mediaPath":"\(mediaURL.path)","segments":[]}
        """
        try Data(futureJSON.utf8).write(to: metadataURL)

        guard case .unavailable = manager.loadProjectResult(for: mediaURL) else {
            return XCTFail("A future schema must require recovery instead of automatic segmentation")
        }
    }

    func testSaveCreatesRecoverableBackupAndDeleteRemovesIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-ProjectBackupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mediaURL = directory.appendingPathComponent("backup.mp3")
        try Data("media".utf8).write(to: mediaURL)
        let manager = ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))

        manager.saveProject(
            for: mediaURL,
            title: "Backup",
            duration: 3,
            lastPosition: 0,
            segments: [SentenceSegment(index: 1, startTime: 0, endTime: 3, text: "first", translation: "一")],
            hasCompletedSegmentation: true
        )
        manager.flush()
        manager.saveProject(
            for: mediaURL,
            title: "Backup",
            duration: 3,
            lastPosition: 1,
            segments: [SentenceSegment(index: 1, startTime: 0, endTime: 3, text: "second", translation: "二")],
            hasCompletedSegmentation: true
        )
        manager.flush()

        let backupDirectories = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("projects"),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            url.lastPathComponent.contains(".backup-")
                && ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
        }
        XCTAssertEqual(backupDirectories.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupDirectories[0].appendingPathComponent("project.json").path))

        try manager.deleteProject(for: mediaURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupDirectories[0].path))
    }

    func testExplicitlyAdoptingChangedMediaPreservesProjectAndCreatesBackup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-ProjectAdoptionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mediaURL = directory.appendingPathComponent("changed.mp4")
        try Data("original media".utf8).write(to: mediaURL)
        let manager = ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        let segment = SentenceSegment(
            index: 1,
            startTime: 0.25,
            endTime: 2.5,
            text: "Edited original",
            translation: "编辑后的译文",
            isBookmarked: true
        )

        manager.saveProject(
            for: mediaURL,
            title: "Changed media",
            duration: 3,
            lastPosition: 1,
            segments: [segment],
            hasCompletedSegmentation: true
        )
        manager.flush()
        try Data("replacement media with a different size".utf8).write(to: mediaURL, options: .atomic)

        guard case .loaded(let project, _) = manager.loadProjectResult(for: mediaURL) else {
            return XCTFail("The changed media should still expose the stored project for explicit adoption")
        }
        XCTAssertFalse(project.isCompatible(with: mediaURL))

        let result = await manager.adoptProjectIgnoringMediaMetadataAsync(for: mediaURL)
        guard case .adopted(let adopted, let backupPath) = result else {
            return XCTFail("Expected explicit adoption to succeed")
        }
        XCTAssertTrue(adopted.isCompatible(with: mediaURL))
        XCTAssertEqual(adopted.segments.first?.text, "Edited original")
        XCTAssertEqual(adopted.segments.first?.translation, "编辑后的译文")
        XCTAssertTrue(adopted.segments.first?.isBookmarked == true)
        XCTAssertFalse(backupPath.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: backupPath).appendingPathComponent("project.json").path))
    }

    func testCorruptedCurrentProjectRecoversLatestValidBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-ProjectRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mediaURL = directory.appendingPathComponent("recovery.mp3")
        try Data("media".utf8).write(to: mediaURL)
        let manager = ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))

        let first = SentenceSegment(index: 1, startTime: 0, endTime: 3, text: "编辑前", translation: "原译文")
        manager.saveProject(
            for: mediaURL,
            title: "Recovery",
            duration: 3,
            lastPosition: 0,
            segments: [first],
            hasCompletedSegmentation: true
        )
        manager.flush()

        let second = SentenceSegment(index: 1, startTime: 0, endTime: 3, text: "编辑后", translation: "新译文")
        manager.saveProject(
            for: mediaURL,
            title: "Recovery",
            duration: 3,
            lastPosition: 1,
            segments: [second],
            hasCompletedSegmentation: true
        )
        manager.flush()
        try Data("corrupted".utf8).write(to: manager.projectFileURL(for: mediaURL), options: .atomic)

        guard case .loaded(let recovered, _) = manager.loadProjectResult(for: mediaURL) else {
            return XCTFail("Expected recovery from the latest valid backup")
        }
        XCTAssertEqual(recovered.segments.first?.text, "编辑前")
        XCTAssertEqual(recovered.segments.first?.translation, "原译文")
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

    func testLegacyProjectWithNumericTimestampsAndMissingFieldsLoadsSuccessfully() throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-LegacyJSONTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let manager = ProjectFileManager(baseDirectory: testDirectory)
        let mediaURL = testDirectory.appendingPathComponent("legacy_lesson.mp3")
        try Data("media content".utf8).write(to: mediaURL)

        // 模拟旧版本软件生成的 JSON：包含数字时间戳、非 UUID 字符串 id、缺少新增字段
        let legacyJSON = """
        {
          "schemaVersion": 2,
          "mediaPath": "\(mediaURL.path)",
          "mediaTitle": "Legacy Lesson",
          "duration": 12.5,
          "lastPosition": 3.2,
          "segments": [
            {
              "id": "not-a-valid-uuid",
              "index": 1,
              "startTime": 0.0,
              "endTime": 4.5,
              "text": "Hello legacy world",
              "translation": "你好旧版本世界"
            }
          ],
          "mediaFileSize": \(try mediaURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 13),
          "mediaModificationDate": 746538492.123,
          "updatedAt": 746538492.123
        }
        """

        let projectFileURL = manager.projectFileURL(for: mediaURL)
        try Data(legacyJSON.utf8).write(to: projectFileURL)

        let loaded = manager.loadProject(for: mediaURL)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.mediaTitle, "Legacy Lesson")
        XCTAssertEqual(loaded?.segments.count, 1)
        XCTAssertEqual(loaded?.segments[0].text, "Hello legacy world")
        XCTAssertEqual(loaded?.segments[0].translation, "你好旧版本世界")
        XCTAssertEqual(loaded?.segments[0].startTime, 0.0)
        XCTAssertEqual(loaded?.segments[0].endTime, 4.5)
        XCTAssertTrue(loaded?.hasCompletedSegmentation ?? false)
    }

    func testIsCompatibleHandlesTimestampDriftWhenFileSizeMatches() throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-CompatibilityTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let mediaURL = testDirectory.appendingPathComponent("drift.mp3")
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        try Data("audio data 12345".utf8).write(to: mediaURL)

        let attr = try FileManager.default.attributesOfItem(atPath: mediaURL.path)
        let actualSize = (attr[.size] as? NSNumber)?.int64Value
        let fileDate = attr[.modificationDate] as? Date ?? Date()

        // 模拟时间戳由于 ISO 8601 转换导致秒级截断或轻微漂移（例如相差 5 秒）
        let driftedDate = fileDate.addingTimeInterval(5.0)

        let project = MediaProjectFile(
            mediaPath: mediaURL.path,
            mediaTitle: "Drift",
            duration: 10,
            lastPosition: 0,
            segments: [],
            mediaFileSize: actualSize,
            mediaModificationDate: driftedDate
        )

        XCTAssertTrue(project.isCompatible(with: mediaURL))
    }

    func testOpeningAndResavingUnmodifiedHydratedProjectDoesNotCreateBackup() throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-NoBackupOnUnmodified-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        let manager = ProjectFileManager(baseDirectory: testDirectory)
        let mediaURL = testDirectory.appendingPathComponent("lesson.mp3")
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        try Data("audio media bytes".utf8).write(to: mediaURL)

        let initialSegments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 2.5, text: "Hello", translation: "你好")
        ]
        let waveform = WaveformData(peaks: [0.2, 0.6, 0.4], duration: 2.5, sampleRate: 100)

        // 首次保存工程并写入波形
        manager.saveProject(
            for: mediaURL,
            title: "Lesson",
            duration: 2.5,
            lastPosition: 1.0,
            segments: initialSegments,
            waveformData: waveform,
            persistWaveform: true,
            hasCompletedSegmentation: true
        )
        manager.flush()

        // 检查初次保存后是否有备份（首次创建主文件时不应产生备份）
        let baseName = manager.projectFileURL(for: mediaURL).deletingPathExtension().lastPathComponent
        let initialBackups = try FileManager.default.contentsOfDirectory(at: testDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(baseName + ".backup-") }
        XCTAssertEqual(initialBackups.count, 0)

        // 模拟用户打开文件（从磁盘读取并水化波形）
        let loaded = try XCTUnwrap(manager.loadProject(for: mediaURL))
        XCTAssertNotNil(loaded.waveformData)

        // 用户打开后什么都没有改，直接调用 saveProject（例如切歌或退出时触发常规自动保存）
        manager.saveProject(
            for: mediaURL,
            title: loaded.mediaTitle,
            duration: loaded.duration,
            lastPosition: loaded.lastPosition,
            segments: loaded.segments,
            waveformData: nil,
            persistWaveform: false,
            hasCompletedSegmentation: loaded.hasCompletedSegmentation,
            acousticBoundaryTimes: loaded.acousticBoundaryTimes
        )
        manager.flush()

        // 验证：什么都没改时，绝不产生多余的备份目录！
        let backupsAfterResave = try FileManager.default.contentsOfDirectory(at: testDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(baseName + ".backup-") }
        XCTAssertEqual(backupsAfterResave.count, 0, "未修改任何内容时不应触发备份")

        // 模拟用户听了一段音频后退出（仅 lastPosition 从 1.0 变为 2.2，断句内容无任何修改）
        manager.saveProject(
            for: mediaURL,
            title: loaded.mediaTitle,
            duration: loaded.duration,
            lastPosition: 2.2,
            segments: loaded.segments,
            waveformData: nil,
            persistWaveform: false,
            hasCompletedSegmentation: loaded.hasCompletedSegmentation,
            acousticBoundaryTimes: loaded.acousticBoundaryTimes
        )
        manager.flush()

        // 验证：仅播放进度发生变化时，更新主工程但绝不生成多余备份目录
        let backupsAfterPositionChange = try FileManager.default.contentsOfDirectory(at: testDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(baseName + ".backup-") }
        XCTAssertEqual(backupsAfterPositionChange.count, 0, "仅播放进度更新不应触发备份快照")
        let updatedProject = try XCTUnwrap(manager.loadProject(for: mediaURL))
        XCTAssertEqual(updatedProject.lastPosition, 2.2)

        // 模拟用户修改了内容（例如编辑了译文）
        var modifiedSegments = loaded.segments
        modifiedSegments[0].translation = "你好，世界！"
        manager.saveProject(
            for: mediaURL,
            title: loaded.mediaTitle,
            duration: loaded.duration,
            lastPosition: 2.2,
            segments: modifiedSegments,
            waveformData: nil,
            persistWaveform: false,
            hasCompletedSegmentation: loaded.hasCompletedSegmentation,
            acousticBoundaryTimes: loaded.acousticBoundaryTimes
        )
        manager.flush()

        // 验证：实际修改后，触发了 1 次备份
        let backupsAfterEdit = try FileManager.default.contentsOfDirectory(at: testDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(baseName + ".backup-") }
        XCTAssertEqual(backupsAfterEdit.count, 1, "内容修改后应生成 1 个备份快照")
    }
}
