import AVFoundation
import XCTest
@testable import MacAbobooKit

final class SegmentMediaExporterTests: XCTestCase {
    func testConcatenatedSRTRebasesTimelineAndIncludesBothLanguages() {
        let segments = [
            SentenceSegment(index: 2, startTime: 8.0, endTime: 9.25, text: "Second line", translation: "第二句"),
            SentenceSegment(index: 5, startTime: 15.0, endTime: 17.0, text: "Fifth line", translation: "第五句")
        ]

        let srt = SubtitleExporter.shared.exportToConcatenatedSRT(segments: segments)

        XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:01,250"))
        XCTAssertTrue(srt.contains("00:00:01,250 --> 00:00:03,250"))
        XCTAssertTrue(srt.contains("Second line\n第二句"))
        XCTAssertTrue(srt.contains("Fifth line\n第五句"))
        XCTAssertFalse(srt.contains("00:00:08,000"))
    }

    func testConcatenatedLRCRebasesTimelineAndIncludesBothLanguages() {
        let segments = [
            SentenceSegment(index: 2, startTime: 8.0, endTime: 9.25, text: "Second line", translation: "第二句"),
            SentenceSegment(index: 5, startTime: 15.0, endTime: 17.0, text: "Fifth line", translation: "第五句")
        ]

        let lrc = SubtitleExporter.shared.exportToConcatenatedLRC(segments: segments)

        XCTAssertTrue(lrc.contains("[00:00.00]Second line\n[00:00.00]第二句"))
        XCTAssertTrue(lrc.contains("[00:01.25]Fifth line\n[00:01.25]第五句"))
        XCTAssertFalse(lrc.contains("[00:08.00]"))
    }

    func testSeparateAndMergedExportCreateMatchingM4AAndBilingualLRC() async throws {
        guard AudioPCMExtractor.ffmpegExecutableURL() != nil else {
            throw XCTSkip("ffmpeg is required for the media export integration test")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-SegmentExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let mediaURL = root.appendingPathComponent("source.wav")
        try makeTestAudio(at: mediaURL, duration: 3.0)
        let earlier = SentenceSegment(
            index: 1,
            startTime: 0.20,
            endTime: 0.70,
            text: "Original one",
            translation: "译文一"
        )
        let later = SentenceSegment(
            index: 3,
            startTime: 2.00,
            endTime: 2.50,
            text: "Original three",
            translation: "译文三"
        )
        // 故意倒序输入，导出器必须按媒体时间排序。
        let selection = [later, earlier]
        let exporter = SegmentMediaExporter(
            temporaryRootURL: root.appendingPathComponent("runtime-temp", isDirectory: true)
        )

        let separate = try exporter.exportIndividually(
            mediaURL: mediaURL,
            segments: selection,
            destinationDirectory: root,
            baseName: "Test / Lesson"
        )
        let separateFiles = try FileManager.default.contentsOfDirectory(
            at: separate.location,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(separateFiles.filter { $0.pathExtension == "m4a" }.count, 2)
        XCTAssertEqual(separateFiles.filter { $0.pathExtension == "lrc" }.count, 2)
        XCTAssertTrue(separateFiles.allSatisfy { $0.pathExtension != "srt" })
        let firstSubtitleURL = try XCTUnwrap(
            separateFiles.first { $0.lastPathComponent.hasSuffix("-0001.lrc") }
        )
        let firstSubtitle = try String(contentsOf: firstSubtitleURL, encoding: .utf8)
        XCTAssertTrue(firstSubtitle.contains("[00:00.00]Original one\n[00:00.00]译文一"))

        // 即使调用方误传旧的 MP3 后缀，导出器也必须强制生成 M4A。
        let requestedMergedAudioURL = root.appendingPathComponent("merged.mp3")
        let mergedResult = try exporter.exportMerged(
            mediaURL: mediaURL,
            segments: selection,
            outputAudioURL: requestedMergedAudioURL
        )
        let mergedAudioURL = mergedResult.location
        XCTAssertEqual(mergedAudioURL.pathExtension, "m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestedMergedAudioURL.path))
        let mergedSubtitle = try String(
            contentsOf: mergedAudioURL.deletingPathExtension().appendingPathExtension("lrc"),
            encoding: .utf8
        )
        XCTAssertTrue(mergedSubtitle.contains("[00:00.00]Original one\n[00:00.00]译文一"))
        XCTAssertTrue(mergedSubtitle.contains("[00:00.50]Original three\n[00:00.50]译文三"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: mergedAudioURL.deletingPathExtension().appendingPathExtension("srt").path
        ))

        let duration = try await AVURLAsset(url: mergedAudioURL).load(.duration).seconds
        XCTAssertEqual(duration, 1.0, accuracy: 0.12)
    }

    func testIndependentAudioClipStartsAtZeroAndReportsProgress() async throws {
        guard AudioPCMExtractor.ffmpegExecutableURL() != nil else {
            throw XCTSkip("ffmpeg is required for the media export integration test")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-IndependentClipTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let mediaURL = root.appendingPathComponent("source.wav")
        try makeTestAudio(at: mediaURL, duration: 3.0)
        let outputURL = root.appendingPathComponent("clip.m4a")
        let recorder = ProgressRecorder()
        let segment = SentenceSegment(index: 4, startTime: 1.0, endTime: 2.0)

        try SegmentMediaExporter(temporaryRootURL: root.appendingPathComponent("runtime-temp"))
            .exportAudioClip(
                mediaURL: mediaURL,
                segment: segment,
                outputURL: outputURL,
                progress: { value in recorder.append(value) }
            )

        let duration = try await AVURLAsset(url: outputURL).load(.duration).seconds
        XCTAssertEqual(duration, 1.0, accuracy: 0.12)
        XCTAssertEqual(try XCTUnwrap(recorder.values.first).fraction, 0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(recorder.values.last).fraction, 1, accuracy: 0.0001)
        XCTAssertTrue(recorder.values.allSatisfy { $0.fraction >= 0 && $0.fraction <= 1 })
    }

    func testLibraryEntryExportReusesIndependentClipsAndWritesLRC() async throws {
        guard AudioPCMExtractor.ffmpegExecutableURL() != nil else {
            throw XCTSkip("ffmpeg is required for the media export integration test")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAboboo-LibraryExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source.wav")
        try makeTestAudio(at: sourceURL, duration: 3.0)
        let clipOneURL = root.appendingPathComponent("one.m4a")
        let clipTwoURL = root.appendingPathComponent("two.m4a")
        let clipExporter = SegmentMediaExporter(temporaryRootURL: root.appendingPathComponent("runtime-temp"))
        try clipExporter.exportAudioClip(
            mediaURL: sourceURL,
            segment: SentenceSegment(index: 1, startTime: 0, endTime: 0.6),
            outputURL: clipOneURL
        )
        try clipExporter.exportAudioClip(
            mediaURL: sourceURL,
            segment: SentenceSegment(index: 2, startTime: 1.0, endTime: 1.8),
            outputURL: clipTwoURL
        )
        let first = SentenceLibraryEntry(
            originalText: "One",
            translation: "一",
            sourceMediaName: "lesson.mp4",
            sourceMediaPath: "/lesson.mp4",
            startTime: 0,
            endTime: 0.6,
            mediaFilename: "one.m4a"
        )
        let second = SentenceLibraryEntry(
            originalText: "Two",
            translation: "二",
            sourceMediaName: "lesson.mp4",
            sourceMediaPath: "/lesson.mp4",
            startTime: 1,
            endTime: 1.8,
            mediaFilename: "two.m4a"
        )
        let exporter = SegmentMediaExporter(temporaryRootURL: root.appendingPathComponent("runtime-temp-2"))
        let separate = try exporter.exportLibraryEntriesIndividually(
            entries: [first, second],
            mediaURLs: [first.id: clipOneURL, second.id: clipTwoURL],
            destinationDirectory: root,
            baseName: "lesson",
            album: "lesson.mp4",
            artist: "lesson.mp4"
        )
        let separateFiles = try FileManager.default.contentsOfDirectory(at: separate.location, includingPropertiesForKeys: nil)
        XCTAssertEqual(separateFiles.filter { $0.pathExtension == "m4a" }.count, 2)
        XCTAssertTrue(separateFiles.contains { $0.pathExtension == "lrc" })
        let separateLRCs = try separateFiles
            .filter { $0.pathExtension == "lrc" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertTrue(separateLRCs.contains { $0.contains("One") && $0.contains("一") })
        XCTAssertTrue(separateLRCs.contains { $0.contains("Two") && $0.contains("二") })

        let merged = try exporter.exportLibraryEntriesMerged(
            entries: [first, second],
            mediaURLs: [first.id: clipOneURL, second.id: clipTwoURL],
            outputAudioURL: root.appendingPathComponent("merged.mp3"),
            album: "lesson.mp4",
            artist: "lesson.mp4"
        )
        XCTAssertEqual(merged.location.pathExtension, "m4a")
        let mergedLRC = try String(
            contentsOf: merged.location.deletingPathExtension().appendingPathExtension("lrc"),
            encoding: .utf8
        )
        XCTAssertTrue(mergedLRC.contains("[00:00.00]One"))
        XCTAssertTrue(mergedLRC.contains("[00:00.60]Two"))
        let duration = try await AVURLAsset(url: merged.location).load(.duration).seconds
        XCTAssertEqual(duration, 1.4, accuracy: 0.2)
    }

    private func makeTestAudio(at url: URL, duration: Double) throws {
        let sampleRate = 16_000.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let angularStep = 2.0 * Double.pi * 440.0 / sampleRate
        for frame in 0..<Int(frameCount) {
            samples[frame] = Float(0.2 * sin(angularStep * Double(frame)))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [SegmentMediaExportProgress] = []

    func append(_ value: SegmentMediaExportProgress) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}
