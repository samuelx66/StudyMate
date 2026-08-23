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

    func testSeparateAndMergedExportCreateMatchingMP3AndBilingualSRT() async throws {
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
        XCTAssertEqual(separateFiles.filter { $0.pathExtension == "mp3" }.count, 2)
        XCTAssertEqual(separateFiles.filter { $0.pathExtension == "srt" }.count, 2)
        let firstSubtitleURL = try XCTUnwrap(
            separateFiles.first { $0.lastPathComponent.hasSuffix("-0001.srt") }
        )
        let firstSubtitle = try String(contentsOf: firstSubtitleURL, encoding: .utf8)
        XCTAssertTrue(firstSubtitle.contains("00:00:00,000 --> 00:00:00,500"))
        XCTAssertTrue(firstSubtitle.contains("Original one\n译文一"))

        let mergedAudioURL = root.appendingPathComponent("merged.mp3")
        _ = try exporter.exportMerged(
            mediaURL: mediaURL,
            segments: selection,
            outputAudioURL: mergedAudioURL
        )
        let mergedSubtitle = try String(
            contentsOf: mergedAudioURL.deletingPathExtension().appendingPathExtension("srt"),
            encoding: .utf8
        )
        XCTAssertTrue(mergedSubtitle.contains("00:00:00,000 --> 00:00:00,500"))
        XCTAssertTrue(mergedSubtitle.contains("00:00:00,500 --> 00:00:01,000"))
        XCTAssertTrue(mergedSubtitle.contains("Original one\n译文一"))
        XCTAssertTrue(mergedSubtitle.contains("Original three\n译文三"))

        let duration = try await AVURLAsset(url: mergedAudioURL).load(.duration).seconds
        XCTAssertEqual(duration, 1.0, accuracy: 0.12)
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
