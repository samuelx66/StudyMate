import XCTest
@testable import MacAbobooKit

@MainActor
final class PlaybackEngineTests: XCTestCase {
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
        XCTAssertEqual(engine.segments.map { $0.text }, ["First", "Second"])
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
            SentenceSegment(index: 1, startTime: 0, endTime: 3)
        ]
        engine.activeSegmentIndex = 0
        engine.play()

        // 唯一句播放完毕后，应自动暂停
        native.emitTime(3.0)
        await Task.yield()

        XCTAssertFalse(engine.isPlaying)
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

        // 句末暂停模式：句1播完后暂停并定位在句2开始
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

        // 单句循环模式：句1播完后循环回到句1起点 1.0
        native.emitTime(4.0)
        await Task.yield()

        XCTAssertEqual(engine.activeSegmentIndex, 0)
        XCTAssertEqual(native.currentTime, 1.0, accuracy: 0.001)
        XCTAssertTrue(engine.isPlaying)
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
        manager.saveProject(
            for: mediaURL,
            title: "Resume",
            duration: 10,
            lastPosition: 4.5,
            segments: [SentenceSegment(index: 1, startTime: 0, endTime: 10)]
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

    private func temporaryTestDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-PlaybackTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
