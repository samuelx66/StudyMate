import Combine
import CryptoKit
import AVFoundation
import XCTest
@testable import StudyMateKit

@MainActor
final class PlaybackEngineTests: XCTestCase {
    func testStartupRestoresMostRecentlyOpenedReadableMedia() throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first.mp3")
        let secondURL = directory.appendingPathComponent("second.mp4")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)

        let history = PlaybackHistoryStore(storageDirectory: directory.appendingPathComponent("history"))
        history.recordPlayed(firstURL)
        history.recordPlayed(secondURL)
        history.flush()
        let native = TestMediaPlayerBackend(duration: 10)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 10),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects")),
            playbackHistoryStore: history
        )
        engine.setDecoderMode(.system)

        engine.restoreLastOpenedMediaIfNeeded()

        XCTAssertEqual(engine.currentMedia?.url, secondURL.standardizedFileURL)
        XCTAssertEqual(native.loadedURL, secondURL.standardizedFileURL)
        history.flush()
    }

    func testStartupRestoreLeavesEmptyOrMissingHistoryBlank() throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = PlaybackHistoryStore(storageDirectory: directory.appendingPathComponent("history"))
        let engine = PlaybackEngine(
            nativeBackend: TestMediaPlayerBackend(),
            mpvBackend: TestMediaPlayerBackend(),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects")),
            playbackHistoryStore: history
        )

        engine.restoreLastOpenedMediaIfNeeded()
        XCTAssertNil(engine.currentMedia)

        let missingURL = directory.appendingPathComponent("missing.mp3")
        try Data("temporary".utf8).write(to: missingURL)
        let historyDirectory = directory.appendingPathComponent("missing-history")
        let persistedHistory = PlaybackHistoryStore(storageDirectory: historyDirectory)
        persistedHistory.recordPlayed(missingURL)
        persistedHistory.flush()
        try FileManager.default.removeItem(at: missingURL)
        let reloadedHistory = PlaybackHistoryStore(storageDirectory: historyDirectory)
        let missingEngine = PlaybackEngine(
            nativeBackend: TestMediaPlayerBackend(),
            mpvBackend: TestMediaPlayerBackend(),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("missing-projects")),
            playbackHistoryStore: reloadedHistory
        )
        missingEngine.restoreLastOpenedMediaIfNeeded()
        XCTAssertNil(missingEngine.currentMedia)
    }

    func testFailedBackendLoadDoesNotEnterPlaybackHistory() throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("broken.mp4")
        try Data("broken".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(automaticallyCompletesLoads: false)
        let history = PlaybackHistoryStore(storageDirectory: directory.appendingPathComponent("history"))
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects")),
            playbackHistoryStore: history
        )
        engine.setDecoderMode(.system)

        engine.loadMedia(from: mediaURL)
        XCTAssertTrue(history.entries.isEmpty)
        native.completeLoad(at: 0, success: false)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testClosingCurrentMediaReturnsToEmptyWorkspaceAndPreservesHistory() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("lesson.mp4")
        try Data("media".utf8).write(to: mediaURL)
        let history = PlaybackHistoryStore(storageDirectory: directory.appendingPathComponent("history"))
        let native = TestMediaPlayerBackend(duration: 12)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 12),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects")),
            playbackHistoryStore: history
        )

        engine.loadMedia(from: mediaURL)
        XCTAssertEqual(engine.currentMedia?.url, mediaURL.standardizedFileURL)

        await engine.closeCurrentMedia()

        XCTAssertNil(engine.currentMedia)
        XCTAssertFalse(engine.isMediaLoading)
        XCTAssertTrue(engine.segments.isEmpty)
        XCTAssertNil(native.loadedURL)
        XCTAssertEqual(history.lastOpenedMediaURL, mediaURL.standardizedFileURL)
    }

    func testOpeningAndRemovingMediaUpdatesPlaylistAndSuppressesProjectRecreation() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("history.mp3")
        try Data("media".utf8).write(to: mediaURL)
        let projects = ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        let history = PlaybackHistoryStore(storageDirectory: directory.appendingPathComponent("history"))
        let engine = PlaybackEngine(
            nativeBackend: TestMediaPlayerBackend(duration: 10),
            mpvBackend: TestMediaPlayerBackend(duration: 10),
            projectFileManager: projects,
            playbackHistoryStore: history
        )

        engine.loadMedia(from: mediaURL)
        XCTAssertEqual(history.entries.map(\.mediaPath), [mediaURL.path])
        engine.persistCurrentProject(includeWaveform: true)
        projects.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: projects.projectFileURL(for: mediaURL).path))

        await engine.removeFromPlaybackHistory(mediaURL)
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projects.projectFileURL(for: mediaURL).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaURL.path))

        engine.persistCurrentProject(includeWaveform: true)
        projects.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: projects.projectFileURL(for: mediaURL).path))
    }

    func testClearingPlaybackHistoryDeletesAllProjectRecordsButNotSourceMedia() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first.mp3")
        let secondURL = directory.appendingPathComponent("second.mp3")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        let projects = ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        let history = PlaybackHistoryStore(storageDirectory: directory.appendingPathComponent("history"))
        let engine = PlaybackEngine(
            nativeBackend: TestMediaPlayerBackend(duration: 10),
            mpvBackend: TestMediaPlayerBackend(duration: 10),
            projectFileManager: projects,
            playbackHistoryStore: history
        )

        engine.loadMedia(from: firstURL)
        engine.persistCurrentProject()
        history.recordPlayed(secondURL)
        projects.saveProject(for: secondURL, title: "Second", duration: 10, lastPosition: 0, segments: [])
        projects.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: projects.projectFileURL(for: firstURL).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projects.projectFileURL(for: secondURL).path))

        await engine.clearPlaybackHistory()

        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projects.projectFileURL(for: firstURL).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projects.projectFileURL(for: secondURL).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testRemovingPCMCacheDeletesCurrentFiles() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("cache-source.mp4")
        try Data("media".utf8).write(to: mediaURL)
        let cacheDirectory = directory.appendingPathComponent("PCMCache", isDirectory: true)
        let extractor = AudioPCMExtractor(cacheDirectory: cacheDirectory)
        let cacheURL = try pcmCacheURL(for: mediaURL, cacheDirectory: cacheDirectory)
        try Data("pcm-cache".utf8).write(to: cacheURL, options: .atomic)
        let temporaryURL = cacheDirectory.appendingPathComponent(
            "\(cacheURL.deletingPathExtension().lastPathComponent).pcmcache.tmp-test"
        )
        try Data("temporary".utf8).write(to: temporaryURL, options: .atomic)

        await extractor.removeCache(for: mediaURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaURL.path))
    }

    func testSegmentOperations() {
        let engine = makeTestPlaybackEngine()
        engine.duration = 60.0

        // 添加断句
        engine.addSegment(startTime: 0.0, endTime: 5.0)
        engine.addSegment(startTime: 7.0, endTime: 12.0)
        engine.addSegment(startTime: 14.0, endTime: 20.0)

        XCTAssertEqual(engine.segments.count, 3)
        XCTAssertEqual(engine.segments[0].index, 1)
        XCTAssertEqual(engine.segments[1].index, 2)
        XCTAssertEqual(engine.segments[2].index, 3)

        // 更新断句锚点
        let seg1Id = engine.segments[0].id
        engine.updateSegmentAnchor(id: seg1Id, start: 0.5)
        XCTAssertEqual(engine.segments[0].startTime, 0.5)
        XCTAssertEqual(engine.segments[0].endTime, 5.0)
        // 起点拖动不能改写上一句的终点或下一句的起点。
        XCTAssertEqual(engine.segments[1].startTime, 7.0)

        engine.updateSegmentAnchor(id: seg1Id, end: 6.0)
        XCTAssertEqual(engine.segments[0].endTime, 6.0)
        XCTAssertEqual(engine.segments[1].startTime, 7.0)

        // 调整第二句起止标线时，保留相邻标线位置并避免与相邻句重叠。
        let seg2Id = engine.segments[1].id
        engine.updateSegmentAnchor(id: seg2Id, start: 6.5, end: 12.5)
        XCTAssertEqual(engine.segments[1].startTime, 6.5)
        XCTAssertEqual(engine.segments[1].endTime, 12.5)
        XCTAssertEqual(engine.segments[0].endTime, 6.0)
        XCTAssertEqual(engine.segments[2].startTime, 14.0)

        // 拆分断句
        engine.splitSegment(at: 3.0)
        XCTAssertEqual(engine.segments.count, 4)

        // 合并断句
        engine.mergeSegmentWithNext(at: 0)
        XCTAssertEqual(engine.segments.count, 3)

        // 删除断句
        engine.deleteSegment(at: 1)
        XCTAssertEqual(engine.segments.count, 2)
    }

    func testSegmentMutationsRefreshSecondaryViewportWhenActiveIDIsRetained() {
        let engine = makeTestPlaybackEngine()
        engine.duration = 60
        let first = SentenceSegment(index: 1, startTime: 0, endTime: 4)
        let second = SentenceSegment(index: 2, startTime: 4, endTime: 8)
        engine.segments = [first, second]
        engine.activeSegmentIndex = 0

        let initialEnd = engine.secondaryViewport.end
        engine.splitSegment(at: 2)
        XCTAssertEqual(engine.activeSegmentIndex, 0)
        XCTAssertLessThan(engine.secondaryViewport.end, initialEnd)

        engine.mergeSegmentWithNext(at: 0)
        XCTAssertEqual(engine.activeSegmentIndex, 0)
        XCTAssertEqual(engine.secondaryViewport.end, initialEnd, accuracy: 0.0001)

        engine.deleteSegment(at: 1)
        XCTAssertEqual(engine.activeSegmentIndex, 0)
        XCTAssertEqual(engine.secondaryViewport.end, initialEnd, accuracy: 0.0001)
    }

    func testBoundaryAnchorsMoveIndependently() {
        let engine = makeTestPlaybackEngine()
        engine.duration = 60.0
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0.0, endTime: 5.0),
            SentenceSegment(index: 2, startTime: 7.0, endTime: 12.0)
        ]

        let firstID = engine.segments[0].id
        let secondID = engine.segments[1].id

        engine.updateSegmentAnchor(id: firstID, end: 6.25)
        XCTAssertEqual(engine.segments[0].endTime, 6.25, accuracy: 0.0001)
        XCTAssertEqual(engine.segments[1].startTime, 7.0, accuracy: 0.0001)

        engine.updateSegmentAnchor(id: secondID, start: 8.5)
        XCTAssertEqual(engine.segments[0].endTime, 6.25, accuracy: 0.0001)
        XCTAssertEqual(engine.segments[1].startTime, 8.5, accuracy: 0.0001)
    }

    func testSegmentEditorSavesOriginalAndTranslationTogether() {
        let engine = makeTestPlaybackEngine()
        let segment = SentenceSegment(
            index: 1,
            startTime: 0,
            endTime: 3,
            text: "Old original",
            translation: "旧译文"
        )
        engine.segments = [segment]

        engine.updateSegmentText(
            id: segment.id,
            text: "New original",
            translation: "新译文"
        )

        XCTAssertEqual(engine.segments[0].text, "New original")
        XCTAssertEqual(engine.segments[0].translation, "新译文")
    }

    func testActiveSegmentDetection() {
        let engine = makeTestPlaybackEngine()
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0.0, endTime: 4.0),
            SentenceSegment(index: 2, startTime: 4.0, endTime: 8.0)
        ]

        engine.updateActiveSegment(for: 2.5)
        XCTAssertEqual(engine.activeSegmentIndex, 0)

        engine.updateActiveSegment(for: 5.0)
        XCTAssertEqual(engine.activeSegmentIndex, 1)

        // 保持既有语义：位于断句间隙时预选下一句，公共边界属于下一句。
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0.0, endTime: 3.0),
            SentenceSegment(index: 2, startTime: 5.0, endTime: 8.0),
            SentenceSegment(index: 3, startTime: 8.0, endTime: 12.0)
        ]
        engine.updateActiveSegment(for: 4.0)
        XCTAssertEqual(engine.activeSegmentIndex, 1)
        engine.updateActiveSegment(for: 8.0)
        XCTAssertEqual(engine.activeSegmentIndex, 2)
    }

    func testExplicitSentenceSelectionPublishesEditorSyncRevision() {
        let engine = makeTestPlaybackEngine()
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0.0, endTime: 2.0),
            SentenceSegment(index: 2, startTime: 2.0, endTime: 4.0),
            SentenceSegment(index: 3, startTime: 4.0, endTime: 6.0)
        ]

        let initialRevision = engine.explicitSegmentSelectionRevision
        engine.nextSegment()
        XCTAssertEqual(engine.activeSegmentIndex, 1)
        XCTAssertEqual(engine.explicitSegmentSelectionRevision, initialRevision + 1)

        engine.previousSegment()
        XCTAssertEqual(engine.activeSegmentIndex, 0)
        XCTAssertEqual(engine.explicitSegmentSelectionRevision, initialRevision + 2)
    }

    func testSilentGapDoesNotRepublishUnchangedActiveSegment() {
        let engine = makeTestPlaybackEngine()
        engine.segments = [
            SentenceSegment(index: 1, startTime: 2.0, endTime: 4.0),
            SentenceSegment(index: 2, startTime: 6.0, endTime: 8.0)
        ]

        engine.updateActiveSegment(for: 1.0)
        XCTAssertEqual(engine.activeSegmentIndex, 0)

        var publications: [Int?] = []
        let cancellable = engine.$activeSegmentIndex
            .dropFirst()
            .sink { publications.append($0) }

        engine.updateActiveSegment(for: 1.1)
        engine.updateActiveSegment(for: 1.5)
        engine.updateActiveSegment(for: 1.9)
        XCTAssertTrue(publications.isEmpty)

        engine.updateActiveSegment(for: 5.0)
        XCTAssertEqual(engine.activeSegmentIndex, 1)
        XCTAssertEqual(publications.count, 1)

        publications.removeAll()
        engine.updateActiveSegment(for: 5.1)
        engine.updateActiveSegment(for: 5.5)
        engine.updateActiveSegment(for: 5.9)
        XCTAssertTrue(publications.isEmpty)
        withExtendedLifetime(cancellable) {}
    }

    func testExplicitAdjacentSentenceSelectionSurvivesFrameEarlySeekResult() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("frame-early-seek.mp4")
        try Data("media".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 12)
        native.seekResultOffset = -0.001
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 12),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        for _ in 0..<20 where engine.isMediaLoading {
            await Task.yield()
        }
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 5),
            SentenceSegment(index: 2, startTime: 5, endTime: 8)
        ]

        engine.jumpToSegment(at: 1)
        for _ in 0..<4 { await Task.yield() }

        XCTAssertEqual(engine.currentTime, 4.999, accuracy: 0.0001)
        XCTAssertEqual(engine.activeSegmentIndex, 1)

        // A paused AVPlayer may publish the same rounded position again.
        native.emitTime(4.999)
        XCTAssertEqual(engine.activeSegmentIndex, 1)

        // Once playback enters the sentence, the temporary selection guard is released.
        native.emitTime(5.001)
        XCTAssertEqual(engine.activeSegmentIndex, 1)

        // An ordinary timeline seek still follows the decoder's real time and
        // must not inherit the explicit-row-selection guard.
        native.seekResultOffset = 0
        engine.seek(to: 4.999)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(engine.activeSegmentIndex, 0)
    }

    func testBoundaryDragSource() {
        let engine = makeTestPlaybackEngine()

        engine.beginBoundaryDrag(from: .primary)
        XCTAssertTrue(engine.isBoundaryDragging)
        XCTAssertEqual(engine.boundaryDragSource, .primary)

        engine.beginBoundaryDrag(from: .secondary)
        XCTAssertEqual(engine.boundaryDragSource, .secondary)

        engine.endBoundaryDrag()
        XCTAssertFalse(engine.isBoundaryDragging)
        XCTAssertNil(engine.boundaryDragSource)
    }

    func testBoundaryEditingKeepsPlaybackAndDoesNotSeek() throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("boundary-edit.mp4")
        try Data("media".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 20)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        let first = SentenceSegment(index: 1, startTime: 0, endTime: 4)
        let second = SentenceSegment(index: 2, startTime: 4, endTime: 8)
        engine.segments = [first, second]
        engine.activeSegmentIndex = 0
        engine.play()
        XCTAssertTrue(engine.isPlaying)
        let seekCountBeforeDrag = native.seekCount

        engine.beginBoundaryDrag(from: .primary)
        engine.selectSegmentForBoundaryEditing(id: second.id)

        XCTAssertTrue(engine.isPlaying)
        XCTAssertTrue(native.isPlaying)
        XCTAssertEqual(native.seekCount, seekCountBeforeDrag)
        XCTAssertEqual(engine.activeSegmentIndex, 1)

        engine.endBoundaryDrag()
    }

    func testReleasingBoundaryDragSelectsAndPlaysDraggedSentence() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("boundary-release.mp4")
        try Data("media".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 20)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        let first = SentenceSegment(index: 1, startTime: 0, endTime: 4)
        let second = SentenceSegment(index: 2, startTime: 4, endTime: 8)
        engine.segments = [first, second]
        engine.activeSegmentIndex = 0
        engine.pause()

        engine.beginBoundaryDrag(from: .primary)
        engine.playSegmentAfterBoundaryEditing(id: second.id)
        for _ in 0..<4 { await Task.yield() }

        XCTAssertEqual(engine.activeSegmentIndex, 1)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertTrue(native.isPlaying)
        XCTAssertEqual(native.currentTime, 4, accuracy: 0.0001)
        engine.endBoundaryDrag()
    }

    func testBoundaryDragCarriesAdjacentBoundaryWhenCrossed() {
        let engine = makeTestPlaybackEngine()
        engine.duration = 20
        let first = SentenceSegment(index: 1, startTime: 0, endTime: 3)
        let second = SentenceSegment(index: 2, startTime: 3, endTime: 6)
        engine.segments = [first, second]

        engine.updateSegmentBoundaryFromDrag(
            id: first.id,
            proposed: 4,
            isStart: false
        )
        XCTAssertEqual(engine.segments[0].endTime, 4, accuracy: 0.0001)
        XCTAssertEqual(engine.segments[1].startTime, 4, accuracy: 0.0001)

        engine.updateSegmentBoundaryFromDrag(
            id: second.id,
            proposed: 2,
            isStart: true
        )
        XCTAssertEqual(engine.segments[0].endTime, 2, accuracy: 0.0001)
        XCTAssertEqual(engine.segments[1].startTime, 2, accuracy: 0.0001)
    }

    func testBoundaryDragDoesNotAdvanceSingleRepeatWhilePointerIsDown() throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("boundary-repeat.mp4")
        try Data("media".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 20)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        let first = SentenceSegment(index: 1, startTime: 0, endTime: 4)
        let second = SentenceSegment(index: 2, startTime: 4, endTime: 8)
        engine.segments = [first, second]
        engine.activeSegmentIndex = 0
        engine.loopMode = .singleSegment
        engine.play()

        engine.beginBoundaryDrag(from: .primary)
        let seekCountBeforeRepeat = native.seekCount
        native.emitTime(4.01)

        XCTAssertEqual(engine.activeSegmentIndex, 0)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertTrue(native.isPlaying)
        XCTAssertGreaterThan(native.seekCount, seekCountBeforeRepeat)
        engine.endBoundaryDrag()
    }

    func testVideoTimelinePreviewUsesFastSeekAndResumesOnRelease() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("preview.mp4")
        try Data("media".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 20)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        XCTAssertFalse(engine.isMediaLoading)

        engine.play()
        XCTAssertTrue(engine.isPlaying)
        engine.beginPreviewSeek()
        XCTAssertFalse(engine.isPlaying)

        engine.previewSeek(to: 4)
        await Task.yield()
        XCTAssertGreaterThanOrEqual(native.previewSeekCount, 1)
        XCTAssertEqual(native.seekCount, 0)

        engine.endPreviewSeek()
        engine.seek(to: 8)
        await Task.yield()
        XCTAssertEqual(native.seekCount, 1)
        XCTAssertTrue(native.isPlaying)
    }

    func testDecoderEngineModeSwitching() {
        let engine = makeTestPlaybackEngine()

        // 初始默认为混合模式
        engine.setDecoderMode(.hybrid)
        XCTAssertEqual(engine.decoderMode, .hybrid)

        // 切换为系统解码模式
        engine.setDecoderMode(.system)
        XCTAssertEqual(engine.decoderMode, .system)

        // 切换为 libmpv 解码模式
        engine.setDecoderMode(.mpv)
        XCTAssertEqual(engine.decoderMode, .mpv)

        // 恢复混合模式
        engine.setDecoderMode(.hybrid)
        XCTAssertEqual(engine.decoderMode, .hybrid)
    }

    func testPlaybackRateAdjustments() {
        let engine = makeTestPlaybackEngine()

        // 默认 1.0x
        XCTAssertEqual(engine.playbackRate, 1.0)

        // 设置 0.5x, 0.75x, 1.25x, 1.5x, 2.0x
        engine.playbackRate = 0.5
        XCTAssertEqual(engine.playbackRate, 0.5)

        engine.playbackRate = 1.5
        XCTAssertEqual(engine.playbackRate, 1.5)

        engine.playbackRate = 2.0
        XCTAssertEqual(engine.playbackRate, 2.0)

        // 切换解码模式后倍速仍保持一致
        engine.setDecoderMode(.mpv)
        XCTAssertEqual(engine.playbackRate, 2.0)

        engine.setDecoderMode(.system)
        XCTAssertEqual(engine.playbackRate, 2.0)
    }

    func testIDBasedSegmentOperations() {
        let engine = makeTestPlaybackEngine()
        engine.duration = 60.0

        let seg1 = SentenceSegment(index: 1, startTime: 0.0, endTime: 5.0, text: "First")
        let seg2 = SentenceSegment(index: 2, startTime: 5.0, endTime: 10.0, text: "Second")
        let seg3 = SentenceSegment(index: 3, startTime: 10.0, endTime: 15.0, text: "Third")
        engine.segments = [seg1, seg2, seg3]

        // ID 跳转
        engine.jumpToSegment(id: seg2.id)
        XCTAssertEqual(engine.activeSegmentIndex, 1)

        // ID 拆分
        engine.splitSegment(id: seg2.id, at: 7.5)
        XCTAssertEqual(engine.segments.count, 4)
        XCTAssertEqual(engine.segments[1].startTime, 5.0)
        XCTAssertEqual(engine.segments[1].endTime, 7.5)
        XCTAssertEqual(engine.segments[2].startTime, 7.5)
        XCTAssertEqual(engine.segments[2].endTime, 10.0)

        // ID 合并
        let splitId = engine.segments[1].id
        engine.mergeSegmentWithNext(id: splitId)
        XCTAssertEqual(engine.segments.count, 3)
        XCTAssertEqual(engine.segments[1].startTime, 5.0)
        XCTAssertEqual(engine.segments[1].endTime, 10.0)

        // ID 删除
        engine.deleteSegment(id: seg3.id)
        XCTAssertEqual(engine.segments.count, 2)
        XCTAssertEqual(engine.segments.map { $0.text }, ["First", "Second Second"])
    }

    func testContinuousPlaybackSkipsGapBetweenSegments() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("lesson.mp3")
        try Data("test".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 20)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        engine.loopMode = .normal
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 3),
            SentenceSegment(index: 2, startTime: 5, endTime: 8)
        ]
        engine.activeSegmentIndex = 0
        engine.play()

        // 句1播放完毕（到达 3.0s 边界），连续播放模式应直接跳至句2的起始点 5.0s，跳过 3.0s~5.0s 之间的内容
        native.emitTime(3.0)
        await Task.yield()

        XCTAssertEqual(engine.activeSegmentIndex, 1)
        XCTAssertEqual(native.currentTime, 5.0, accuracy: 0.001)
        XCTAssertTrue(engine.isPlaying)
    }

    func testContinuousPlaybackKeepsNativeStreamAtAdjacentBoundary() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("adjacent-boundary.mp4")
        try Data("test".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 20)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        engine.loopMode = .normal
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 3),
            SentenceSegment(index: 2, startTime: 3, endTime: 6)
        ]
        engine.activeSegmentIndex = 0
        engine.play()
        let seekCountBeforeBoundary = native.seekCount

        // 相邻断句不应对同一时间点再次 Seek；这正是 AVPlayer 在系统解码
        // 下容易停在下一句起点的边界。
        native.emitTime(3.0)
        await Task.yield()

        XCTAssertEqual(engine.activeSegmentIndex, 1)
        XCTAssertEqual(native.currentTime, 3.0, accuracy: 0.001)
        XCTAssertEqual(native.seekCount, seekCountBeforeBoundary)
        XCTAssertTrue(native.isPlaying)
        XCTAssertTrue(engine.isPlaying)
    }

    func testContinuousPlaybackPausesAtEndOfLastSegment() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("lesson.mp3")
        try Data("test".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 20)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        engine.loopMode = .normal
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 3),
            SentenceSegment(index: 2, startTime: 5, endTime: 8)
        ]
        engine.activeSegmentIndex = 1
        engine.play()

        // 最后一条句子播放完毕后，应自动暂停并保留两个波形的当前状态。
        native.emitTime(8.0)
        await Task.yield()

        XCTAssertFalse(engine.isPlaying)

        let frozenPrimaryViewport = engine.primaryViewport
        let frozenSecondaryViewport = engine.secondaryViewport
        let frozenActiveIndex = engine.activeSegmentIndex
        let frozenTime = engine.currentTime

        // 后端在暂停/结束后可能补发一条滞后的时间回调；它不应让活动句、
        // 次波形视口或主波形游标跳回其它位置。
        native.emitTime(1.0)
        await Task.yield()

        XCTAssertEqual(engine.activeSegmentIndex, frozenActiveIndex)
        XCTAssertEqual(engine.primaryViewport.start, frozenPrimaryViewport.start, accuracy: 0.0001)
        XCTAssertEqual(engine.primaryViewport.end, frozenPrimaryViewport.end, accuracy: 0.0001)
        XCTAssertEqual(engine.secondaryViewport.start, frozenSecondaryViewport.start, accuracy: 0.0001)
        XCTAssertEqual(engine.secondaryViewport.end, frozenSecondaryViewport.end, accuracy: 0.0001)
        XCTAssertEqual(engine.currentTime, frozenTime, accuracy: 0.0001)
    }

    func testSelectingSegmentAfterLastSegmentResumesPlayback() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("lesson.mp3")
        try Data("test".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 20)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        engine.loopMode = .normal
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 3),
            SentenceSegment(index: 2, startTime: 5, endTime: 8)
        ]
        engine.activeSegmentIndex = 1
        engine.play()

        // 最后一句自然结束后，列表点击应恢复播放，而不是只完成 Seek。
        native.emitTime(8.0)
        await Task.yield()
        XCTAssertFalse(engine.isPlaying)

        engine.jumpToSegment(at: 0)
        await Task.yield()

        XCTAssertEqual(native.currentTime, 0.0, accuracy: 0.001)
        XCTAssertTrue(native.isPlaying)
        XCTAssertTrue(engine.isPlaying)
    }

    func testLoopAllModeDoesNotSkipContinuousSentenceBoundary() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("lesson.mp3")
        try Data("test".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 20)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        engine.loopMode = .all
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 3),
            SentenceSegment(index: 2, startTime: 3, endTime: 6)
        ]
        engine.activeSegmentIndex = 0
        engine.play()
        let seekCountBeforeBoundary = native.seekCount

        native.emitTime(3.01)
        await Task.yield()

        XCTAssertEqual(engine.activeSegmentIndex, 1)
        XCTAssertEqual(native.seekCount, seekCountBeforeBoundary)
    }

    func testLoopAllModeResetsPrimaryViewportWhenMediaFinishes() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("loop-viewport.mp4")
        try Data("test".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 20)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        engine.loopMode = .all
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 3),
            SentenceSegment(index: 2, startTime: 16, endTime: 19)
        ]
        engine.activeSegmentIndex = 1
        engine.play()

        // 模拟播放到媒体尾部后，主波形已经跟随到文件末端。
        engine.panPrimaryViewport(by: 20)
        XCTAssertEqual(engine.primaryViewport.start, 5.0, accuracy: 0.001)
        XCTAssertEqual(engine.primaryViewport.end, 20.0, accuracy: 0.001)

        // 后端结束回调应把时间轴和主波形一起带回开头，并继续播放。
        native.onFinished?()
        for _ in 0..<4 { await Task.yield() }

        XCTAssertEqual(engine.activeSegmentIndex, 0)
        XCTAssertEqual(native.currentTime, 0.0, accuracy: 0.001)
        XCTAssertEqual(engine.primaryViewport.start, 0.0, accuracy: 0.001)
        XCTAssertEqual(engine.primaryViewport.end, 15.0, accuracy: 0.001)
        XCTAssertTrue(native.isPlaying)
        XCTAssertTrue(engine.isPlaying)
    }

    func testLoopAllModeResetsPrimaryViewportWhenLastSentenceWraps() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("loop-boundary-viewport.mp4")
        try Data("test".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 20)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        engine.loopMode = .all
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 3),
            SentenceSegment(index: 2, startTime: 16, endTime: 19)
        ]
        engine.activeSegmentIndex = 1
        engine.play()
        engine.panPrimaryViewport(by: 20)

        // 最后一条字幕先于媒体结束，循环应在句子边界直接回到第一句。
        native.emitTime(19.0)
        for _ in 0..<4 { await Task.yield() }

        XCTAssertEqual(engine.activeSegmentIndex, 0)
        XCTAssertEqual(native.currentTime, 0.0, accuracy: 0.001)
        XCTAssertEqual(engine.primaryViewport.start, 0.0, accuracy: 0.001)
        XCTAssertEqual(engine.primaryViewport.end, 15.0, accuracy: 0.001)
        XCTAssertTrue(native.isPlaying)
        XCTAssertTrue(engine.isPlaying)
    }

    func testPlaybackFollowKeepsViewportSpanAtMediaEnd() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("follow-span.mp4")
        try Data("test".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 30)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 30),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        engine.loopMode = .normal
        // 保留一个可继续播放的下一句，使测试覆盖自动跟随而不是最后一句冻结。
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 30),
            SentenceSegment(index: 2, startTime: 30, endTime: 35)
        ]
        engine.activeSegmentIndex = 0
        engine.play()

        // 接近媒体末尾时，视口应平移到末端但仍保持原来的 15 秒跨度。
        native.emitTime(29.0)
        await Task.yield()

        XCTAssertEqual(engine.primaryViewport.start, 15.0, accuracy: 0.001)
        XCTAssertEqual(engine.primaryViewport.end, 30.0, accuracy: 0.001)
    }

    func testLastSentenceKeepsPrimaryViewportStableForContinuousPlayback() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("last-sentence-normal.mp4")
        try Data("test".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 20)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        engine.loopMode = .normal
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 3),
            SentenceSegment(index: 2, startTime: 16, endTime: 20)
        ]
        engine.activeSegmentIndex = 1
        engine.play()
        engine.panPrimaryViewport(by: 20)
        let initialViewport = engine.primaryViewport

        native.emitTime(18.0)
        native.emitTime(20.0)
        await Task.yield()

        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.primaryViewport.start, initialViewport.start, accuracy: 0.001)
        XCTAssertEqual(engine.primaryViewport.end, initialViewport.end, accuracy: 0.001)
    }

    func testLastSentenceKeepsPrimaryViewportStableForSingleSegmentLoop() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("last-sentence-single.mp4")
        try Data("test".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 20)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        engine.loopMode = .singleSegment
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 3),
            SentenceSegment(index: 2, startTime: 16, endTime: 20)
        ]
        engine.activeSegmentIndex = 1
        engine.play()
        engine.panPrimaryViewport(by: 20)
        let initialViewport = engine.primaryViewport

        native.emitTime(18.0)
        native.emitTime(20.0)
        for _ in 0..<3 { await Task.yield() }

        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(native.currentTime, 16.0, accuracy: 0.001)
        XCTAssertEqual(engine.primaryViewport.start, initialViewport.start, accuracy: 0.001)
        XCTAssertEqual(engine.primaryViewport.end, initialViewport.end, accuracy: 0.001)
    }

    func testSingleSegmentModeRepeatsLastSentenceWhenBackendFinishesWithoutFinalTimeTick() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("last-sentence-finished-callback.mp4")
        try Data("test".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 20)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        engine.loopMode = .singleSegment
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 3),
            SentenceSegment(index: 2, startTime: 16, endTime: 20)
        ]
        engine.activeSegmentIndex = 1
        engine.play()

        // AVPlayer/libmpv may report finished without a preceding time update
        // at the exact final subtitle boundary.
        // Deliberately report a stale time to ensure the finished callback,
        // rather than a fragile end-time comparison, drives the repeat.
        native.emitFinished(at: 0)
        await Task.yield()

        XCTAssertEqual(engine.activeSegmentIndex, 1)
        XCTAssertEqual(native.currentTime, 16.0, accuracy: 0.001)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertTrue(native.isPlaying)
    }

    func testSingleSegmentFinishDuringPendingSeekStillRestartsCurrentSentence() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("last-sentence-pending-seek.mp4")
        try Data("test".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 20, automaticallyCompletesSeeks: false)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        engine.loopMode = .singleSegment
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 3),
            SentenceSegment(index: 2, startTime: 16, endTime: 20)
        ]
        engine.activeSegmentIndex = 1
        engine.jumpToSegment(at: 1)
        engine.play()

        // A real backend can report the item-end notification while the
        // final precise seek is still being settled. The notification must
        // not fall through to the natural-end stop path.
        native.emitFinished(at: 20)
        native.completeNextSeek() // superseded selection seek
        native.completeNextSeek() // repeat seek requested by onFinished
        await Task.yield()

        XCTAssertEqual(engine.activeSegmentIndex, 1)
        XCTAssertEqual(native.currentTime, 16.0, accuracy: 0.001)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertTrue(native.isPlaying)
    }

    func testPauseAfterSegmentMode() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("lesson.mp3")
        try Data("test".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 20)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        engine.loopMode = .pauseAfterSegment
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 3),
            SentenceSegment(index: 2, startTime: 5, endTime: 8)
        ]
        engine.activeSegmentIndex = 0
        engine.play()

        // 句后停顿模式：句1播完后暂停并定位在句2开始
        native.emitTime(3.0)
        await Task.yield()

        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.activeSegmentIndex, 1)
        XCTAssertEqual(native.currentTime, 5.0, accuracy: 0.001)
    }

    func testSingleSegmentLoopMode() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("lesson.mp3")
        try Data("test".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 20)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        engine.loopMode = .singleSegment
        engine.segments = [
            SentenceSegment(index: 1, startTime: 1.0, endTime: 4.0),
            SentenceSegment(index: 2, startTime: 5.0, endTime: 8.0)
        ]
        engine.activeSegmentIndex = 0
        engine.play()

        // 单句重复模式：句1播完后循环回到句1起点 1.0
        native.emitTime(4.0)
        await Task.yield()

        XCTAssertEqual(engine.activeSegmentIndex, 0)
        XCTAssertEqual(native.currentTime, 1.0, accuracy: 0.001)
        XCTAssertTrue(engine.isPlaying)
    }

    func testContinuousRepeatDoesNotFallBackAtAdjacentSentenceStart() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("continuous-repeat-adjacent.mp4")
        try Data("test".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 20)
        native.seekResultOffset = -0.001
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        engine.loopMode = .normal
        engine.repeatCountLimit = 3
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0.0, endTime: 1.0),
            SentenceSegment(index: 2, startTime: 1.0, endTime: 2.0)
        ]
        engine.activeSegmentIndex = 0
        engine.play()

        // The first two endings repeat sentence 1. The backend reports a
        // frame-rounded position just before each repeat target.
        native.emitTime(1.0)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(engine.activeSegmentIndex, 0)
        XCTAssertEqual(engine.currentRepeatCount, 2)

        native.emitTime(1.0)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(engine.activeSegmentIndex, 0)
        XCTAssertEqual(engine.currentRepeatCount, 3)

        // The third ending advances naturally to the adjacent second
        // sentence. No stale sentence-1 repeat may survive this transition.
        native.seekResultOffset = 0
        native.emitTime(1.0)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(engine.activeSegmentIndex, 1)
        XCTAssertEqual(engine.currentRepeatCount, 1)

        // Repeating sentence 2 at its boundary must stay on sentence 2 even
        // when the decoder reports a timestamp slightly before 1.0s.
        native.seekResultOffset = -0.001
        native.emitTime(2.0)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(engine.activeSegmentIndex, 1)
        XCTAssertEqual(engine.currentRepeatCount, 2)
    }

    func testContinuousThreeRepeatsWithShadowingPauseAdvancesToNextSentence() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("continuous-shadowing-repeat.mp4")
        try Data("test".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 10)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 10),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        engine.loopMode = .normal
        engine.repeatCountLimit = 3
        engine.shadowingPauseRatio = 0.25
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 1),
            SentenceSegment(index: 2, startTime: 1, endTime: 2)
        ]
        engine.activeSegmentIndex = 0
        engine.play()

        // First playback completes, pauses for shadowing, then seeks to #1.
        native.emitTime(1)
        XCTAssertTrue(engine.isShadowingPaused)
        try await Task.sleep(nanoseconds: 750_000_000)
        XCTAssertEqual(engine.currentRepeatCount, 2)
        XCTAssertEqual(engine.activeSegmentIndex, 0)

        // Simulate AVPlayer's queued pre-seek sentence-end frame. It must not
        // immediately start another pause/repeat cycle.
        native.emitTime(1)
        XCTAssertFalse(engine.isShadowingPaused)
        XCTAssertEqual(engine.currentRepeatCount, 2)
        native.emitTime(0.2)
        try await Task.sleep(nanoseconds: 900_000_000)
        native.emitTime(0.95)

        // Second real playback and its stale post-seek frame.
        native.emitTime(1)
        XCTAssertTrue(engine.isShadowingPaused)
        try await Task.sleep(nanoseconds: 750_000_000)
        XCTAssertEqual(engine.currentRepeatCount, 3)
        native.emitTime(1)
        XCTAssertFalse(engine.isShadowingPaused)
        XCTAssertEqual(engine.currentRepeatCount, 3)
        native.emitTime(0.2)
        try await Task.sleep(nanoseconds: 900_000_000)
        native.emitTime(0.95)

        // The third real completion pauses once, then advances to sentence #2.
        native.emitTime(1)
        XCTAssertTrue(engine.isShadowingPaused)
        XCTAssertEqual(engine.currentRepeatCount, 3)
        try await Task.sleep(nanoseconds: 750_000_000)
        XCTAssertEqual(engine.activeSegmentIndex, 1)
        XCTAssertEqual(engine.currentRepeatCount, 1)
        XCTAssertEqual(native.currentTime, 1, accuracy: 0.001)
    }

    func testShadowingPauseIgnoresQueuedEndFrameAndKeepsCurrentSentenceSelected() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("shadowing-pause-stale-end.mp4")
        try Data("test".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 20)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        engine.loopMode = .normal
        engine.repeatCountLimit = 2
        engine.shadowingPauseRatio = 0.25
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 1),
            SentenceSegment(index: 2, startTime: 1, endTime: 2)
        ]
        engine.activeSegmentIndex = 0
        engine.play()

        native.emitTime(1.0)
        XCTAssertTrue(engine.isShadowingPaused)

        // A decoder can deliver a queued end frame after pause(). It must not
        // briefly select sentence #2 while sentence #1 is waiting to repeat.
        native.emitTime(1.05)

        XCTAssertEqual(engine.activeSegmentIndex, 0)
        XCTAssertTrue(engine.isShadowingPaused)
        engine.pause()
    }

    func testDelayedPreSeekEndFrameDoesNotResetShadowingRepeatCycle() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("delayed-shadowing-frame.mp4")
        try Data("test".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 10)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 10),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        engine.loopMode = .normal
        engine.repeatCountLimit = 3
        engine.shadowingPauseRatio = 0.25
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 2),
            SentenceSegment(index: 2, startTime: 2.2, endTime: 3)
        ]
        engine.activeSegmentIndex = 0
        engine.play()

        native.emitTime(2)
        try await Task.sleep(nanoseconds: 750_000_000)
        XCTAssertEqual(engine.currentRepeatCount, 2)
        XCTAssertFalse(engine.isShadowingPaused)

        // Real AVPlayer can deliver this pre-seek end frame more than 400 ms
        // after the repeat seek. It is still impossible for a two-second
        // sentence to have genuinely completed by then.
        try await Task.sleep(nanoseconds: 550_000_000)
        native.emitTime(2)
        XCTAssertEqual(engine.activeSegmentIndex, 0)
        XCTAssertEqual(engine.currentRepeatCount, 2)
        XCTAssertFalse(engine.isShadowingPaused)
    }

    func testTransientActiveIndexChangeCannotResetRepeatProgress() throws {
        let engine = PlaybackEngine(
            nativeBackend: TestMediaPlayerBackend(duration: 10),
            mpvBackend: TestMediaPlayerBackend(duration: 10)
        )
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 1),
            SentenceSegment(index: 2, startTime: 1.1, endTime: 2)
        ]
        engine.activeSegmentIndex = 0
        engine.currentRepeatCount = 2

        // AVPlayer may briefly report a queued timestamp from the adjacent
        // sentence and then return to the repeated target sentence.
        engine.activeSegmentIndex = 1
        engine.activeSegmentIndex = 0
        XCTAssertEqual(engine.currentRepeatCount, 2)
    }

    func testRepeatSeekEndFrameCannotVisuallySelectAdjacentSentenceWhilePaused() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("repeat-visual-stability.mp4")
        try Data("test".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 10)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 10),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        engine.loopMode = .normal
        engine.repeatCountLimit = 3
        engine.shadowingPauseRatio = 0.25
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 1),
            SentenceSegment(index: 2, startTime: 1, endTime: 2)
        ]
        engine.activeSegmentIndex = 0
        engine.play()

        native.emitTime(1)
        try await Task.sleep(nanoseconds: 750_000_000)
        XCTAssertEqual(engine.currentRepeatCount, 2)

        // The renderer can still receive a delayed end timestamp while the
        // player is paused. It must not visually select sentence #2.
        engine.isShadowingPaused = true
        engine.updateActiveSegment(for: 1)
        XCTAssertEqual(engine.activeSegmentIndex, 0)
        XCTAssertEqual(engine.currentRepeatCount, 2)
    }

    func testNextSegmentNearBoundaryDoesNotRevertToPreviousSentenceInSingleLoop() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("single-loop-next-race.mp4")
        try Data("test".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 20)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        engine.loopMode = .singleSegment
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0.0, endTime: 0.8),
            SentenceSegment(index: 2, startTime: 0.8, endTime: 2.0)
        ]
        engine.activeSegmentIndex = 0
        engine.play()

        // Let the first sentence enter its repeat seek, then press Next
        // before that boundary work has fully settled.  The backend reports
        // one stale previous-sentence timestamp for the new seek, matching
        // AVPlayer's observable callback ordering at this boundary.
        native.emitTime(0.796)
        native.seekResultOffset = -0.8
        engine.nextSegment()
        for _ in 0..<4 { await Task.yield() }

        XCTAssertEqual(engine.activeSegmentIndex, 1)
        XCTAssertTrue(engine.isPlaying)

        // Once the decoder reaches the selected sentence, single-sentence
        // repeat must continue to refer to sentence 2, never sentence 1.
        native.seekResultOffset = 0
        native.emitTime(0.8)
        native.emitTime(2.0)
        await Task.yield()

        XCTAssertEqual(engine.activeSegmentIndex, 1)
        XCTAssertEqual(native.currentTime, 0.8, accuracy: 0.001)
    }

    func testStaleLoadCompletionCannotReplaceNewMediaSession() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first.mp3")
        let secondURL = directory.appendingPathComponent("second.mp3")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        let native = TestMediaPlayerBackend(automaticallyCompletesLoads: false)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)

        engine.loadMedia(from: firstURL)
        engine.loadMedia(from: secondURL)
        native.completeLoad(at: 0)
        await Task.yield()
        XCTAssertEqual(engine.currentMedia?.url, secondURL)
        XCTAssertTrue(engine.isMediaLoading)

        native.completeLoad(at: 1)
        await Task.yield()
        XCTAssertFalse(engine.isMediaLoading)
        XCTAssertEqual(native.loadedURL, secondURL)
    }

    func testRuntimeFallbackPreservesPlaybackIntent() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("fallback.mp4")
        try Data("media".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 12)
        let mpv = TestMediaPlayerBackend(duration: 12)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: mpv,
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.hybrid)
        engine.loadMedia(from: mediaURL)
        engine.play()

        native.emitError(NSError(domain: "test", code: 1))
        for _ in 0..<4 { await Task.yield() }

        XCTAssertTrue(engine.activeBackend === mpv)
        XCTAssertTrue(mpv.isPlaying)
        XCTAssertTrue(engine.isPlaying)
    }

    func testSavedPositionRestoresAfterBackendIsReady() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("resume.mp3")
        try Data("media".utf8).write(to: mediaURL)
        let manager = ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        let savedSegment = SentenceSegment(index: 1, startTime: 0, endTime: 10)
        manager.saveProject(
            for: mediaURL,
            title: "Resume",
            duration: 10,
            lastPosition: 4.5,
            segments: [savedSegment],
            acousticBoundaryTimes: [4.5]
        )
        manager.flush()
        let native = TestMediaPlayerBackend(duration: 10)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 10),
            projectFileManager: manager
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)

        for _ in 0..<20 where abs(engine.currentTime - 4.5) > 0.001 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(engine.currentTime, 4.5, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(native.seekCount, 1)
    }

    func testPlayRequestWaitsForPendingSeekAndResumesAfterCompletion() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("seek-play-race.mp4")
        try Data("media".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(
            duration: 20,
            automaticallyCompletesSeeks: false
        )
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        for _ in 0..<20 where engine.isMediaLoading {
            await Task.yield()
        }
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 3),
            SentenceSegment(index: 2, startTime: 6.96, endTime: 10.835)
        ]

        // Selecting a sentence starts an asynchronous seek. Pressing Play
        // before it completes must queue playback instead of racing AVPlayer.
        engine.jumpToSegment(at: 1)
        XCTAssertTrue(engine.isSeeking)
        engine.play()
        XCTAssertFalse(native.isPlaying)
        XCTAssertFalse(engine.isPlaying)

        native.completeNextSeek()
        for _ in 0..<4 { await Task.yield() }

        XCTAssertTrue(native.isPlaying)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(native.currentTime, 6.96, accuracy: 0.001)
    }

    func testSeekTimeoutReleasesPlaybackLockWhenBackendDropsCompletion() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("seek-timeout.mp4")
        try Data("media".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(
            duration: 20,
            automaticallyCompletesSeeks: false
        )
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 20),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        for _ in 0..<20 where engine.isMediaLoading {
            await Task.yield()
        }

        engine.seek(to: 6.0)
        XCTAssertTrue(engine.isSeeking)

        // A backend that loses its completion callback must not leave the
        // engine suppressing all later time updates indefinitely.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertFalse(engine.isSeeking)
        XCTAssertEqual(engine.currentTime, 6.0, accuracy: 0.001)
    }

    func testAutoGenerateSubtitlesSetting() {
        let engine = makeTestPlaybackEngine()
        engine.autoGenerateSubtitles = true
        XCTAssertTrue(engine.autoGenerateSubtitles)

        engine.autoGenerateSubtitles = false
        XCTAssertFalse(engine.autoGenerateSubtitles)
    }

    func testSameNameSidecarOverridesSavedProjectSegmentsAndReusesWaveform() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("sidecar-priority.mp3")
        try Data("media".utf8).write(to: mediaURL)
        let subtitleURL = directory.appendingPathComponent("sidecar-priority.srt")
        try """
        1
        00:00:01,000 --> 00:00:03,000
        Sidecar original
        同名字幕译文
        """.write(to: subtitleURL, atomically: true, encoding: .utf8)

        let manager = ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        let waveform = WaveformData(peaks: [0.2, 0.5, 0.3], duration: 10, sampleRate: 100)
        manager.saveProject(
            for: mediaURL,
            title: "Saved Project",
            duration: 10,
            lastPosition: 2,
            segments: [SentenceSegment(index: 1, startTime: 0, endTime: 10, text: "Old project sentence")],
            waveformData: waveform,
            persistWaveform: true
        )
        manager.flush()

        let engine = PlaybackEngine(
            nativeBackend: TestMediaPlayerBackend(duration: 10),
            mpvBackend: TestMediaPlayerBackend(duration: 10),
            projectFileManager: manager
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)

        for _ in 0..<50 where engine.segments.first?.text != "Sidecar original" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(engine.segments.count, 1)
        let segment = try XCTUnwrap(engine.segments.first)
        XCTAssertEqual(segment.startTime, 1, accuracy: 0.001)
        XCTAssertEqual(segment.endTime, 3, accuracy: 0.001)
        XCTAssertEqual(segment.text, "Sidecar original")
        XCTAssertEqual(segment.translation, "同名字幕译文")
        XCTAssertEqual(engine.currentTime, 2, accuracy: 0.001)
        XCTAssertEqual(engine.waveformData.peaks, waveform.peaks)
    }

    func testMultipleFormatSidecarsPrioritizesSRTOverLRC() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("multi-sidecar.mp3")
        try Data("media".utf8).write(to: mediaURL)
        let srtURL = directory.appendingPathComponent("multi-sidecar.srt")
        let lrcURL = directory.appendingPathComponent("multi-sidecar.lrc")
        try """
        1
        00:00:01,000 --> 00:00:03,000
        From SRT
        SRT译文
        """.write(to: srtURL, atomically: true, encoding: .utf8)
        try """
        [00:00.50]From LRC
        [00:00.50]LRC译文
        """.write(to: lrcURL, atomically: true, encoding: .utf8)

        let manager = ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        let engine = PlaybackEngine(
            nativeBackend: TestMediaPlayerBackend(duration: 10),
            mpvBackend: TestMediaPlayerBackend(duration: 10),
            projectFileManager: manager
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)

        for _ in 0..<50 where engine.segments.first?.text != "From SRT" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(engine.segments.count, 1)
        let segment = try XCTUnwrap(engine.segments.first)
        XCTAssertEqual(segment.startTime, 1, accuracy: 0.001)
        XCTAssertEqual(segment.endTime, 3, accuracy: 0.001)
        XCTAssertEqual(segment.text, "From SRT")
        XCTAssertEqual(segment.translation, "SRT译文")
    }

    func testMergedLibraryM4AReopensWithMatchingSubtitleTimelineAndWaveform() async throws {
        guard AudioPCMExtractor.ffmpegExecutableURL() != nil else {
            throw XCTSkip("ffmpeg is required for the media export integration test")
        }
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.wav")
        try makeTestAudio(at: sourceURL, duration: 3.0)
        let exporter = SegmentMediaExporter(
            temporaryRootURL: directory.appendingPathComponent("export-temp")
        )
        let firstClipURL = directory.appendingPathComponent("first.m4a")
        let secondClipURL = directory.appendingPathComponent("second.m4a")
        try exporter.exportAudioClip(
            mediaURL: sourceURL,
            segment: SentenceSegment(index: 1, startTime: 0, endTime: 0.6),
            outputURL: firstClipURL
        )
        try exporter.exportAudioClip(
            mediaURL: sourceURL,
            segment: SentenceSegment(index: 2, startTime: 1, endTime: 1.8),
            outputURL: secondClipURL
        )

        let first = SentenceLibraryEntry(
            originalText: "First",
            translation: "第一句",
            sourceMediaName: "source.mp4",
            sourceMediaPath: sourceURL.path,
            startTime: 0,
            endTime: 0.6,
            mediaFilename: firstClipURL.lastPathComponent
        )
        let second = SentenceLibraryEntry(
            originalText: "Second",
            translation: "第二句",
            sourceMediaName: "source.mp4",
            sourceMediaPath: sourceURL.path,
            startTime: 1,
            endTime: 1.8,
            mediaFilename: secondClipURL.lastPathComponent
        )
        let result = try exporter.exportLibraryEntriesMerged(
            entries: [first, second],
            mediaURLs: [first.id: firstClipURL, second.id: secondClipURL],
            outputAudioURL: directory.appendingPathComponent("merged.m4a"),
            album: "source.mp4",
            artist: "source.mp4"
        )

        // 以实际解码采样读到 EOF，确认合并文件不是只有容器头或被提前截断。
        let mergedDuration = try await fullyDecodeAudio(at: result.location)
        XCTAssertEqual(mergedDuration, 1.4, accuracy: 0.12)
        let subtitleURL = result.location.deletingPathExtension().appendingPathExtension("srt")
        let parsedItems = try SubtitleParser.shared.parse(from: subtitleURL)
        XCTAssertEqual(parsedItems.count, 2)
        XCTAssertEqual(parsedItems[0].startTime, 0, accuracy: 0.001)
        XCTAssertEqual(parsedItems[0].endTime, 0.6, accuracy: 0.05)
        XCTAssertEqual(parsedItems[1].startTime, parsedItems[0].endTime, accuracy: 0.05)
        XCTAssertEqual(parsedItems[1].endTime, 1.4, accuracy: 0.08)

        // 通过正式 PlaybackEngine 路径重新打开同名字幕，验证字幕时间轴接管
        // 断句且波形提取使用同一个 M4A 的时间基准。
        let engine = PlaybackEngine(
            nativeBackend: TestMediaPlayerBackend(duration: 1.4),
            mpvBackend: TestMediaPlayerBackend(duration: 1.4),
            projectFileManager: ProjectFileManager(
                baseDirectory: directory.appendingPathComponent("projects")
            )
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: result.location)
        for _ in 0..<200 {
            if engine.segments.count == 2, !engine.waveformData.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(engine.segments.count, 2)
        XCTAssertEqual(engine.segments[0].startTime, 0, accuracy: 0.001)
        XCTAssertEqual(engine.segments[0].endTime, 0.6, accuracy: 0.08)
        XCTAssertEqual(engine.segments[1].startTime, engine.segments[0].endTime, accuracy: 0.08)
        XCTAssertEqual(engine.segments[1].endTime, 1.4, accuracy: 0.12)
        XCTAssertEqual(engine.waveformData.duration, mergedDuration, accuracy: 0.12)
        await engine.closeCurrentMedia()
    }

    private func makeTestAudio(at url: URL, duration: Double) throws {
        let sampleRate = 16_000.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let angularStep = 2.0 * Double.pi * 440.0 / sampleRate
        for frame in 0..<Int(frameCount) {
            samples[frame] = Float(0.2 * sin(angularStep * Double(frame)))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func fullyDecodeAudio(at url: URL) async throws -> Double {
        // Use the production decoder path for this integration assertion. It
        // fully consumes the audio while avoiding AVFAudio's process-level
        // `fmt?` failure when the test suite has just created another AAC file.
        let pcm = try await AudioPCMExtractor.shared.extract(from: url)
        return Double(pcm.sampleCount) / Double(pcm.sampleRate)
    }

    func testManualSubtitleImportReplacesEveryExistingSegmentAndTargetsTranslation() {
        let engine = makeTestPlaybackEngine()
        engine.duration = 20
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 5, text: "Old one"),
            SentenceSegment(index: 2, startTime: 5, endTime: 10, text: "Old two")
        ]
        let imported = [
            ParsedSubtitleItem(index: 1, startTime: 2, endTime: 4, text: "New subtitle"),
            ParsedSubtitleItem(index: 2, startTime: 8, endTime: 11, text: "Another subtitle")
        ]

        engine.importSubtitleItems(imported, target: .translation)

        XCTAssertEqual(engine.segments.count, 2)
        XCTAssertEqual(engine.segments.map(\.startTime), [2, 8])
        XCTAssertEqual(engine.segments.map(\.endTime), [4, 11])
        XCTAssertEqual(engine.segments.map(\.text), ["", ""])
        XCTAssertEqual(engine.segments.map(\.translation), ["New subtitle", "Another subtitle"])
    }

    func testRegeneratedOriginalTextOverwritesOnlyTargetsAndPreservesSentenceMetadata() {
        let first = SentenceSegment(
            index: 1,
            startTime: 0,
            endTime: 2,
            text: "Keep original",
            translation: "保留译文",
            note: "note",
            isNavigationBookmarked: true,
            isBookmarked: true,
            speakerID: 3
        )
        let second = SentenceSegment(
            index: 2,
            startTime: 2,
            endTime: 4,
            text: "Old original",
            translation: "原有译文",
            note: "second note",
            speakerID: 5
        )
        let tokens = [
            SpeechToken(text: " New", startTime: 2.1, endTime: 2.5),
            SpeechToken(text: " sentence", startTime: 2.6, endTime: 3.3),
            SpeechToken(text: ".", startTime: 3.3, endTime: 3.4)
        ]

        let recognized = PlaybackEngine.recognizedOriginalTexts(for: [second], tokens: tokens)
        let updated = PlaybackEngine.replacingOriginalTexts(
            in: [first, second],
            targetIDs: [second.id],
            recognizedTexts: recognized
        )

        XCTAssertEqual(updated[0], first)
        XCTAssertEqual(updated[1].text, "New sentence.")
        XCTAssertEqual(updated[1].translation, second.translation)
        XCTAssertEqual(updated[1].note, second.note)
        XCTAssertEqual(updated[1].startTime, second.startTime)
        XCTAssertEqual(updated[1].endTime, second.endTime)
        XCTAssertEqual(updated[1].speakerIDs, second.speakerIDs)
    }

    func testRegeneratedOriginalTextClearsExistingTargetWhenWhisperFindsNoText() {
        let segment = SentenceSegment(
            index: 1,
            startTime: 1,
            endTime: 2,
            text: "Stale text",
            translation: "译文"
        )

        let recognized = PlaybackEngine.recognizedOriginalTexts(for: [segment], tokens: [])
        let updated = PlaybackEngine.replacingOriginalTexts(
            in: [segment],
            targetIDs: [segment.id],
            recognizedTexts: recognized
        )

        XCTAssertEqual(updated[0].text, "")
        XCTAssertEqual(updated[0].translation, "译文")
        XCTAssertEqual(updated[0].startTime, 1)
        XCTAssertEqual(updated[0].endTime, 2)
    }

    private func temporaryTestDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudyMate-PlaybackTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func pcmCacheURL(
        for mediaURL: URL,
        cacheDirectory: URL
    ) throws -> URL {
        let standardizedURL = mediaURL.standardizedFileURL
        let values = try standardizedURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fileSize = values.fileSize ?? -1
        let modificationTime = values.contentModificationDate?.timeIntervalSince1970 ?? -1
        let signature = [
            "pcm-cache-v1",
            standardizedURL.path,
            String(fileSize),
            String(format: "%.6f", modificationTime),
            String(AudioPCMData.requiredSampleRate),
            "1",
            "f32le"
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(signature.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let filename = "\(digest).pcmcache"
        return cacheDirectory.appendingPathComponent(filename)
    }

    func testShadowingPauseCanBePausedAndResumedWithPlayPauseButton() async throws {
        let directory = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let mediaURL = directory.appendingPathComponent("sample.mp4")
        try Data("test".utf8).write(to: mediaURL)
        let native = TestMediaPlayerBackend(duration: 10)
        let engine = PlaybackEngine(
            nativeBackend: native,
            mpvBackend: TestMediaPlayerBackend(duration: 10),
            projectFileManager: ProjectFileManager(baseDirectory: directory.appendingPathComponent("projects"))
        )
        engine.setDecoderMode(.system)
        engine.loadMedia(from: mediaURL)
        engine.loopMode = .normal
        engine.repeatCountLimit = 2
        engine.setShadowingPauseSeconds(1.0)
        engine.segments = [
            SentenceSegment(index: 1, startTime: 0, endTime: 1),
            SentenceSegment(index: 2, startTime: 1, endTime: 2)
        ]
        engine.activeSegmentIndex = 0
        engine.play()

        // Sentence 1 reaches end, triggers shadowing pause.
        native.emitTime(1)
        XCTAssertTrue(engine.isShadowingPaused)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertGreaterThan(engine.shadowingCountdownRemaining, 0)

        // User clicks Pause button during shadowing pause.
        engine.pause()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertTrue(engine.isShadowingPaused)
        let pausedRemaining = engine.shadowingCountdownRemaining

        // Wait 250ms; countdown must remain frozen while paused.
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(engine.shadowingCountdownRemaining, pausedRemaining)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertTrue(engine.isShadowingPaused)

        // User clicks Play button to resume shadowing pause.
        engine.play()
        XCTAssertTrue(engine.isPlaying)
        XCTAssertTrue(engine.isShadowingPaused)

        // Wait for remaining countdown to finish.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertFalse(engine.isShadowingPaused)
        XCTAssertEqual(engine.currentRepeatCount, 2)
        XCTAssertEqual(engine.activeSegmentIndex, 0)
    }
}
