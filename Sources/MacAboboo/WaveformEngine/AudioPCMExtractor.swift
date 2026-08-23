import AVFoundation
import CoreMedia
import CryptoKit
import Foundation

/// 所有断句模式共用的 16 kHz、Float32、单声道解码入口。
///
/// 解码结果会按媒体文件版本缓存到 Caches 目录。波形抽取和断句流水线
/// 都经过这个 actor，因此同一媒体不会并发启动两次全量音频解码。
public actor AudioPCMExtractor {
    public static let shared = AudioPCMExtractor()

    private final class PCMCacheBox: NSObject {
        let value: AudioPCMData

        init(value: AudioPCMData) {
            self.value = value
        }
    }

    private struct CacheDescriptor: Sendable {
        let key: String
        let fileURL: URL?
    }

    private static let cacheMagic = Data("MABPCM01".utf8)
    private static let cacheHeaderSize = cacheMagic.count + MemoryLayout<UInt32>.size + MemoryLayout<UInt64>.size
    private static let maxCachedSampleCount: UInt64 = 1_000_000_000

    private let memoryCache = NSCache<NSString, PCMCacheBox>()
    private let cacheDirectory: URL?
    private var inFlight: [String: Task<AudioPCMData, Error>] = [:]

    public init() {
        memoryCache.countLimit = 2
        memoryCache.totalCostLimit = 256 * 1024 * 1024

        if let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let directory = cachesURL
                .appendingPathComponent("MacAboboo", isDirectory: true)
                .appendingPathComponent("PCM", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            cacheDirectory = directory
        } else {
            cacheDirectory = nil
        }
    }

    public func extract(
        from url: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AudioPCMData {
        try Task.checkCancellation()
        let descriptor = Self.cacheDescriptor(for: url, cacheDirectory: cacheDirectory)
        let memoryKey = descriptor.key as NSString

        if let cached = memoryCache.object(forKey: memoryKey)?.value {
            progress?(1)
            return cached
        }

        if let cacheURL = descriptor.fileURL,
           let cached = Self.readDiskCache(from: cacheURL) {
            memoryCache.setObject(Self.PCMCacheBox(value: cached), forKey: memoryKey, cost: Self.cacheCost(for: cached))
            progress?(1)
            return cached
        }

        if let existingTask = inFlight[descriptor.key] {
            let pcm = try await existingTask.value
            try Task.checkCancellation()
            memoryCache.setObject(Self.PCMCacheBox(value: pcm), forKey: memoryKey, cost: Self.cacheCost(for: pcm))
            progress?(1)
            return pcm
        }

        let decodeTask = Task.detached(priority: .utility) {
            try await Self.decodeUncached(from: url, progress: progress)
        }
        inFlight[descriptor.key] = decodeTask

        do {
            let pcm = try await decodeTask.value
            inFlight[descriptor.key] = nil
            try Task.checkCancellation()

            memoryCache.setObject(Self.PCMCacheBox(value: pcm), forKey: memoryKey, cost: Self.cacheCost(for: pcm))
            if let cacheURL = descriptor.fileURL {
                let writeTask = Self.scheduleDiskWrite(pcm, to: cacheURL)
                // Keep the completed result visible while the asynchronous
                // cache write finishes. This prevents a second immediate
                // caller from starting another full decode if NSCache evicts
                // a long recording because of its cost limit.
                Task.detached { [weak self] in
                    _ = await writeTask.value
                    await self?.removeCompletedFlight(for: descriptor.key)
                }
            } else {
                inFlight[descriptor.key] = nil
            }
            progress?(1)
            return pcm
        } catch {
            inFlight[descriptor.key] = nil
            throw error
        }
    }

    // MARK: - Cache

    private static func cacheDescriptor(for url: URL, cacheDirectory: URL?) -> CacheDescriptor {
        let standardizedURL = url.standardizedFileURL
        let values = try? standardizedURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fileSize = values?.fileSize ?? -1
        let modificationTime = values?.contentModificationDate?.timeIntervalSince1970 ?? -1
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
        let fileURL = cacheDirectory?.appendingPathComponent("\(digest).pcmcache")
        return CacheDescriptor(key: digest, fileURL: fileURL)
    }

    private static func cacheCost(for pcm: AudioPCMData) -> Int {
        guard pcm.samples.count <= Int.max / MemoryLayout<Float>.size else { return Int.max }
        return pcm.samples.count * MemoryLayout<Float>.size
    }

    private static func readDiskCache(from url: URL) -> AudioPCMData? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count >= cacheHeaderSize,
              data.prefix(cacheMagic.count) == cacheMagic else {
            return nil
        }

        let sampleRateOffset = cacheMagic.count
        let sampleCountOffset = sampleRateOffset + MemoryLayout<UInt32>.size
        let sampleRate = readUInt32LittleEndian(data, at: sampleRateOffset)
        let rawSampleCount = readUInt64LittleEndian(data, at: sampleCountOffset)
        guard sampleRate == UInt32(AudioPCMData.requiredSampleRate),
              rawSampleCount <= maxCachedSampleCount,
              rawSampleCount <= UInt64(Int.max),
              rawSampleCount <= UInt64((Int.max - cacheHeaderSize) / MemoryLayout<Float>.size) else {
            return nil
        }

        let sampleCount = Int(rawSampleCount)
        let byteCount = sampleCount * MemoryLayout<Float>.size
        guard data.count == cacheHeaderSize + byteCount else { return nil }

        var samples = [Float](repeating: 0, count: sampleCount)
        samples.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                guard let sourceBase = source.baseAddress,
                      let destinationBase = destination.baseAddress else { return }
                destinationBase.copyMemory(
                    from: sourceBase.advanced(by: cacheHeaderSize),
                    byteCount: byteCount
                )
            }
        }

        for index in samples.indices {
            let value = samples[index]
            guard value.isFinite else { return nil }
            samples[index] = min(1, max(-1, value))
        }
        return AudioPCMData(uncheckedSamples: samples)
    }

    private static func scheduleDiskWrite(_ pcm: AudioPCMData, to url: URL) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            let temporaryURL = url.appendingPathExtension("tmp-\(UUID().uuidString)")
            var fileHandle: FileHandle?
            do {
                var header = Data()
                header.append(cacheMagic)
                header.appendLittleEndian(UInt32(AudioPCMData.requiredSampleRate))
                header.appendLittleEndian(UInt64(pcm.samples.count))
                try header.write(to: temporaryURL, options: .atomic)

                let handle = try FileHandle(forWritingTo: temporaryURL)
                fileHandle = handle
                let chunkSize = 4 * 1024 * 1024
                try pcm.samples.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else { return }
                    var offset = 0
                    while offset < rawBuffer.count {
                        let count = min(chunkSize, rawBuffer.count - offset)
                        try handle.write(contentsOf: Data(
                            bytes: baseAddress.advanced(by: offset),
                            count: count
                        ))
                        offset += count
                    }
                }
                try handle.synchronize()
                try handle.close()
                fileHandle = nil

                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: url)
            } catch {
                try? fileHandle?.close()
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }
    }

    private func removeCompletedFlight(for key: String) {
        inFlight[key] = nil
    }

    private static func readUInt32LittleEndian(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt64LittleEndian(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<MemoryLayout<UInt64>.size {
            value |= UInt64(data[offset + index]) << UInt64(index * 8)
        }
        return value
    }

    // MARK: - Decoding

    private static func decodeUncached(
        from url: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> AudioPCMData {
        do {
            return try await extractWithAVFoundation(from: url, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // AVFoundation 不支持的容器/编码交给随应用打包的 ffmpeg。
            return try await extractWithFFmpeg(from: url, progress: progress)
        }
    }

    private static func extractWithAVFoundation(
        from url: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> AudioPCMData {
        // 精准时长会让某些长视频在真正解码前额外扫描容器；PCM 解码只需要
        // 一个估算时长用于容量预留和进度显示，精确 Seek 由播放引擎单独处理。
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let durationTime = try? await asset.load(.duration)
        let duration = durationTime.map(CMTimeGetSeconds) ?? 0
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw PCMExtractionError.noAudioTrack
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: Double(AudioPCMData.requiredSampleRate)
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw PCMExtractionError.decoderUnavailable }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? PCMExtractionError.decoderUnavailable
        }

        let estimatedCount = duration.isFinite && duration > 0
            ? Int(min(Double(Int.max), duration * Double(AudioPCMData.requiredSampleRate)))
            : 0
        var samples: [Float] = []
        if estimatedCount > 0 {
            samples.reserveCapacity(estimatedCount)
        }
        var lastProgress = 0.0

        while reader.status == .reading {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            try appendSamples(from: sampleBuffer, to: &samples)

            if duration.isFinite, duration > 0 {
                let decodedDuration = Double(samples.count) / Double(AudioPCMData.requiredSampleRate)
                let value = min(0.99, decodedDuration / duration)
                if value - lastProgress >= 0.01 {
                    lastProgress = value
                    progress?(value)
                }
            }
        }

        if reader.status == .failed {
            throw reader.error ?? PCMExtractionError.decoderFailed
        }
        try Task.checkCancellation()
        guard !samples.isEmpty else { throw PCMExtractionError.emptyAudio }
        progress?(1)
        return AudioPCMData(uncheckedSamples: samples)
    }

    private static func appendSamples(from sampleBuffer: CMSampleBuffer, to samples: inout [Float]) throws {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw PCMExtractionError.decoderFailed
        }
        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        let floatCount = byteCount / MemoryLayout<Float>.size
        guard floatCount > 0 else { return }

        // AVAssetReader 通常提供连续的 PCM block。直接借用其指针可以消除
        // 每个 sample buffer 一次临时 [Float] 分配；非连续 block 仍走安全兜底。
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let pointerStatus = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        if pointerStatus == kCMBlockBufferNoErr,
           lengthAtOffset >= floatCount * MemoryLayout<Float>.size,
           let dataPointer {
            let floatPointer = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
            samples.append(contentsOf: UnsafeBufferPointer(start: floatPointer, count: floatCount))
            return
        }

        var decoded = [Float](repeating: 0, count: floatCount)
        let status = decoded.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: floatCount * MemoryLayout<Float>.size,
                destination: baseAddress
            )
        }
        guard status == kCMBlockBufferNoErr else { throw PCMExtractionError.decoderFailed }
        samples.append(contentsOf: decoded)
    }

    private static func extractWithFFmpeg(
        from url: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> AudioPCMData {
        guard let executable = ffmpegExecutableURL() else {
            throw PCMExtractionError.ffmpegUnavailable
        }

        let asset = AVURLAsset(url: url)
        let durationTime = try? await asset.load(.duration)
        let duration = durationTime.map(CMTimeGetSeconds) ?? 0
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = [
            "-nostdin", "-v", "error", "-i", url.path,
            "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000",
            "-f", "f32le", "pipe:1"
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? pipe.fileHandleForReading.close()
            if process.isRunning { process.terminate() }
        }

        var samples: [Float] = []
        if duration.isFinite, duration > 0 {
            samples.reserveCapacity(Int(min(Double(Int.max), duration * Double(AudioPCMData.requiredSampleRate))))
        }
        var pending = Data()
        var lastProgress = 0.0

        while true {
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
            guard let data = try pipe.fileHandleForReading.read(upToCount: 512 * 1024), !data.isEmpty else {
                break
            }
            pending.append(data)
            let floatCount = pending.count / MemoryLayout<Float>.size
            if floatCount > 0 {
                let byteCount = floatCount * MemoryLayout<Float>.size
                var decoded = [Float](repeating: 0, count: floatCount)
                _ = decoded.withUnsafeMutableBytes { destination in
                    pending.copyBytes(
                        to: destination,
                        from: pending.startIndex..<(pending.startIndex + byteCount)
                    )
                }
                pending.removeFirst(byteCount)
                samples.append(contentsOf: decoded)
            }

            if duration.isFinite, duration > 0 {
                let value = min(0.99, Double(samples.count) / Double(AudioPCMData.requiredSampleRate) / duration)
                if value - lastProgress >= 0.01 {
                    lastProgress = value
                    progress?(value)
                }
            }
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        guard process.terminationStatus == 0, !samples.isEmpty else {
            throw PCMExtractionError.decoderFailed
        }
        progress?(1)
        return AudioPCMData(uncheckedSamples: samples)
    }

    private static func ffmpegExecutableURL() -> URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

public enum PCMExtractionError: LocalizedError {
    case noAudioTrack
    case decoderUnavailable
    case decoderFailed
    case emptyAudio
    case ffmpegUnavailable

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "媒体中没有可用的音轨。"
        case .decoderUnavailable: return "系统无法创建音频解码器。"
        case .decoderFailed: return "音频解码失败。"
        case .emptyAudio: return "音轨中没有可供断句的音频。"
        case .ffmpegUnavailable: return "该媒体格式需要应用内置的 ffmpeg 解码器。"
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
