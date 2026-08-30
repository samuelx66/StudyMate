import AVFoundation
import XCTest
@testable import StudyMateKit

final class AudioPCMExtractorTests: XCTestCase {
    func testFirstDecodeStreamsIntoFileBackedCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudyMate-PCMStreaming-\(UUID().uuidString)", isDirectory: true)
        let cacheDirectory = directory.appendingPathComponent("PCMCache", isDirectory: true)
        let mediaURL = directory.appendingPathComponent("source.wav")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeTestAudio(at: mediaURL, duration: 1.25)

        let extractor = AudioPCMExtractor(cacheDirectory: cacheDirectory)
        let first = try await extractor.extract(from: mediaURL)

        XCTAssertTrue(first.isFileBacked)
        XCTAssertEqual(first.residentByteCount, 0)
        XCTAssertEqual(first.sampleRate, 16_000)
        XCTAssertEqual(first.sampleCount, 20_000, accuracy: 8)
        XCTAssertEqual(first.samples(in: 0..<min(128, first.sampleCount)).count, 128)

        let files = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        let cacheFiles = files.filter { $0.pathExtension == "pcmcache" }
        XCTAssertEqual(cacheFiles.count, 1)
        XCTAssertFalse(files.contains { $0.lastPathComponent.contains(".tmp-") })
        let cacheSize = try XCTUnwrap(
            cacheFiles.first?.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        XCTAssertEqual(cacheSize, 20 + first.sampleCount * MemoryLayout<Float>.size)

        await extractor.purgeMemoryCache()
        let reopened = try await extractor.extract(from: mediaURL)
        XCTAssertTrue(reopened.isFileBacked)
        XCTAssertEqual(reopened.residentByteCount, 0)
        XCTAssertEqual(reopened.sampleCount, first.sampleCount)
        XCTAssertEqual(
            reopened.samples(in: 1_000..<1_128),
            first.samples(in: 1_000..<1_128)
        )
    }

    private func makeTestAudio(at url: URL, duration: Double) throws {
        let sampleRate = 16_000.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ))
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
