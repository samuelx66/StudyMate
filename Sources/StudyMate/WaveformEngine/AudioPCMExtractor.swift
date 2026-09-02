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

    private struct DecodeFlight {
        let id: UUID
        let task: Task<AudioPCMData, Error>
        var waiters: Set<UUID>
        var isCompleted: Bool
    }

    /// 磁盘写入在后台进行，但删除播放列表记录时必须等对应写入结束，
    /// 否则刚删除的缓存可能又被后台任务原子移动回来。
    private struct DiskWriteFlight {
        let id: UUID
        let task: Task<Void, Never>
    }

    /// Writes decoder output directly into the cache container. Only the
    /// current AVFoundation/FFmpeg block is resident; `finish()` patches the
    /// sample count and atomically publishes the completed cache file.
    private final class PCMCacheStreamWriter {
        let destinationURL: URL
        let temporaryURL: URL
        private var handle: FileHandle?
        private(set) var sampleCount = 0
        private var isCommitted = false

        init(destinationURL: URL) throws {
            self.destinationURL = destinationURL
            self.temporaryURL = destinationURL.appendingPathExtension("tmp-\(UUID().uuidString)")
            do {
                var header = Data()
                header.append(AudioPCMExtractor.cacheMagic)
                header.appendLittleEndian(UInt32(AudioPCMData.requiredSampleRate))
                header.appendLittleEndian(UInt64(0))
                try header.write(to: temporaryURL, options: .atomic)
                handle = try FileHandle(forWritingTo: temporaryURL)
                try handle?.seekToEnd()
            } catch {
                try? handle?.close()
                try? FileManager.default.removeItem(at: temporaryURL)
                throw PCMExtractionError.cacheWriteFailed
            }
        }

        func append(_ samples: UnsafeBufferPointer<Float>) throws {
            guard !samples.isEmpty, let baseAddress = samples.baseAddress else { return }
            do {
                let byteCount = samples.count * MemoryLayout<Float>.size
                let data = Data(
                    bytesNoCopy: UnsafeMutableRawPointer(mutating: baseAddress),
                    count: byteCount,
                    deallocator: .none
                )
                try handle?.write(contentsOf: data)
                sampleCount += samples.count
            } catch {
                throw PCMExtractionError.cacheWriteFailed
            }
        }

        func appendRawBytes(_ data: Data) throws {
            guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Float>.size) else {
                throw PCMExtractionError.cacheWriteFailed
            }
            do {
                try handle?.write(contentsOf: data)
                sampleCount += data.count / MemoryLayout<Float>.size
            } catch {
                throw PCMExtractionError.cacheWriteFailed
            }
        }

        func finish() throws {
            guard sampleCount > 0, let handle else { throw PCMExtractionError.emptyAudio }
            do {
                let sampleCountOffset = UInt64(
                    AudioPCMExtractor.cacheMagic.count + MemoryLayout<UInt32>.size
                )
                try handle.seek(toOffset: sampleCountOffset)
                var countData = Data()
                countData.appendLittleEndian(UInt64(sampleCount))
                try handle.write(contentsOf: countData)
                try handle.synchronize()
                try handle.close()
                self.handle = nil

                // Publish the completed cache in one filesystem operation.  Removing
                // the previous file first leaves a visible gap (and lets a reader
                // observe a half-written replacement); replaceItemAt keeps either
                // the old valid cache or the new valid cache available.
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    _ = try FileManager.default.replaceItemAt(
                        destinationURL,
                        withItemAt: temporaryURL,
                        backupItemName: nil,
                        options: [.usingNewMetadataOnly]
                    )
                } else {
                    try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
                }
                isCommitted = true
            } catch let error as PCMExtractionError {
                throw error
            } catch {
                throw PCMExtractionError.cacheWriteFailed
            }
        }

        func cancel() {
            try? handle?.close()
            handle = nil
            if !isCommitted {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        deinit { cancel() }
    }

    private static let cacheMagic = Data("MABPCM02".utf8)
    private static let cacheHeaderSize = cacheMagic.count + MemoryLayout<UInt32>.size + MemoryLayout<UInt64>.size
    private static let maxCachedSampleCount: UInt64 = 1_000_000_000

    private let memoryCache = NSCache<NSString, PCMCacheBox>()
    private let cacheDirectory: URL?
    private var inFlight: [String: DecodeFlight] = [:]
    private var diskWrites: [String: DiskWriteFlight] = [:]

    public init() {
        self.init(
            cacheDirectoryOverride: nil,
            pruneDefaultCache: true
        )
    }

    /// 测试和离线工具可以注入独立缓存目录；正式应用仍使用默认的
    /// `~/Library/Application Support/StudyMate/PCMCache` 路径。
    init(cacheDirectory: URL) {
        self.init(
            cacheDirectoryOverride: cacheDirectory,
            pruneDefaultCache: false
        )
    }

    private init(
        cacheDirectoryOverride: URL?,
        pruneDefaultCache: Bool
    ) {
        memoryCache.countLimit = 2
        memoryCache.totalCostLimit = 256 * 1024 * 1024

        if let directory = cacheDirectoryOverride {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            cacheDirectory = directory
            if pruneDefaultCache {
                Task.detached(priority: .background) {
                    Self.pruneDiskCache(in: directory)
                }
            }
        } else if let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let directory = appSupportURL
                .appendingPathComponent("StudyMate", isDirectory: true)
                .appendingPathComponent("PCMCache", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            cacheDirectory = directory
            if pruneDefaultCache {
                Task.detached(priority: .background) {
                    Self.pruneDiskCache(in: directory)
                }
            }
        } else {
            cacheDirectory = nil
        }
    }

    public func extract(
        from url: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AudioPCMData {
        try Task.checkCancellation()
        let descriptor = Self.cacheDescriptor(
            for: url,
            cacheDirectory: cacheDirectory
        )
        let memoryKey = descriptor.key as NSString

        if let cached = memoryCache.object(forKey: memoryKey)?.value {
            progress?(1)
            return cached
        }

        if let cacheURL = descriptor.fileURL,
           let cached = Self.readDiskCache(from: cacheURL) {
            cacheInMemoryIfReasonable(cached, key: memoryKey)
            progress?(1)
            return cached
        }
        let waiterID = UUID()
        let flightID: UUID
        let decodeTask: Task<AudioPCMData, Error>
        if var existingFlight = inFlight[descriptor.key] {
            existingFlight.waiters.insert(waiterID)
            inFlight[descriptor.key] = existingFlight
            flightID = existingFlight.id
            decodeTask = existingFlight.task
        } else {
            let cacheURL = descriptor.fileURL
            let task = Task.detached(priority: .utility) {
                if let cacheURL {
                    do {
                        return try await Self.decodeUncachedToCache(
                            from: url,
                            cacheURL: cacheURL,
                            progress: progress
                        )
                    } catch PCMExtractionError.cacheWriteFailed {
                        // A read-only/full Application Support volume must not
                        // make media unusable. Preserve the old in-memory path
                        // as a storage failure fallback.
                        return try await Self.decodeUncached(from: url, progress: progress)
                    }
                }
                return try await Self.decodeUncached(from: url, progress: progress)
            }
            let id = UUID()
            inFlight[descriptor.key] = DecodeFlight(
                id: id,
                task: task,
                waiters: [waiterID],
                isCompleted: false
            )
            flightID = id
            decodeTask = task
        }

        do {
            let pcm = try await withTaskCancellationHandler {
                try await decodeTask.value
            } onCancel: {
                Task {
                    await self.cancelWaiter(
                        waiterID,
                        for: descriptor.key,
                        flightID: flightID
                    )
                }
            }
            removeWaiter(waiterID, for: descriptor.key, flightID: flightID)
            try Task.checkCancellation()

            cacheInMemoryIfReasonable(pcm, key: memoryKey)
            let shouldFinalize = markFlightCompleted(for: descriptor.key, flightID: flightID)
            if shouldFinalize, let cacheURL = descriptor.fileURL, !pcm.isFileBacked {
                let writeTask = Self.scheduleDiskWrite(pcm, to: cacheURL)
                let writeID = registerDiskWrite(writeTask, for: descriptor.key)
                // Keep the completed result visible while the asynchronous
                // cache write finishes. This prevents a second immediate
                // caller from starting another full decode if NSCache evicts
                // a long recording because of its cost limit.
                Task.detached { [weak self] in
                    _ = await writeTask.value
                    await self?.removeCompletedFlight(for: descriptor.key, flightID: flightID)
                    await self?.clearDiskWrite(for: descriptor.key, id: writeID)
                }
            } else if shouldFinalize {
                removeCompletedFlight(for: descriptor.key, flightID: flightID)
            }
            progress?(1)
            return pcm
        } catch {
            removeWaiter(waiterID, for: descriptor.key, flightID: flightID)
            removeFailedFlight(for: descriptor.key, flightID: flightID)
            throw error
        }
    }

    // MARK: - Cache

    private static func cacheDescriptor(
        for url: URL,
        cacheDirectory: URL?
    ) -> CacheDescriptor {
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
        pcm.residentByteCount
    }

    private func cacheInMemoryIfReasonable(_ pcm: AudioPCMData, key: NSString) {
        let cost = Self.cacheCost(for: pcm)
        // 长录音由当前任务持有并保存在磁盘缓存，不再额外常驻一份大数组。
        guard cost <= 128 * 1024 * 1024 else { return }
        memoryCache.setObject(Self.PCMCacheBox(value: pcm), forKey: key, cost: cost)
    }

    public func purgeMemoryCache() {
        memoryCache.removeAllObjects()
    }

    /// 删除媒体对应的内存缓存、磁盘缓存及未完成的临时写入。
    ///
    /// 播放列表删除只移除历史记录，不会删除原始音视频；但 PCM 是由原始
    /// 媒体派生的可再生缓存，因此应随历史记录一并清理，避免长期占用磁盘。
    public func removeCache(for url: URL) async {
        let descriptor = Self.cacheDescriptor(
            for: url,
            cacheDirectory: cacheDirectory
        )
        memoryCache.removeObject(forKey: descriptor.key as NSString)

        if let flight = inFlight.removeValue(forKey: descriptor.key) {
            flight.task.cancel()
            _ = try? await flight.task.value
        }

        // 处理删除期间已经排队的写入。循环是为了覆盖 actor 在 await
        // 期间又登记了同一媒体新写入的情况，确保删除返回后不会复现缓存。
        while let write = diskWrites.removeValue(forKey: descriptor.key) {
            _ = await write.task.value
        }

        Self.removeCacheFiles(
            for: descriptor.key,
            in: cacheDirectory.map { [$0] } ?? []
        )
    }

    private static func readDiskCache(from url: URL) -> AudioPCMData? {
        guard let data = try? Data(contentsOf: url, options: [.alwaysMapped]),
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

        // Retain the mapped Data as the immutable PCM backing. Consumers can
        // now address individual windows without allocating another full
        // `[Float]` for a long recording.
        return AudioPCMData(
            mappedCacheData: data,
            sampleByteOffset: cacheHeaderSize,
            sampleCount: sampleCount
        )
    }

    private static func scheduleDiskWrite(_ pcm: AudioPCMData, to url: URL) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            let temporaryURL = url.appendingPathExtension("tmp-\(UUID().uuidString)")
            var fileHandle: FileHandle?
            do {
                var header = Data()
                header.append(cacheMagic)
                header.appendLittleEndian(UInt32(AudioPCMData.requiredSampleRate))
                header.appendLittleEndian(UInt64(pcm.sampleCount))
                try header.write(to: temporaryURL, options: .atomic)

                let handle = try FileHandle(forWritingTo: temporaryURL)
                fileHandle = handle
                let chunkSize = 4 * 1024 * 1024
                try pcm.withUnsafeSamples(in: 0..<pcm.sampleCount) { samples in
                    guard let baseAddress = samples.baseAddress else { return }
                    let rawBuffer = UnsafeRawBufferPointer(start: baseAddress, count: samples.count * MemoryLayout<Float>.size)
                    var offset = 0
                    while offset < rawBuffer.count {
                        let count = min(chunkSize, rawBuffer.count - offset)
                        let chunk = Data(
                            // `offset` is measured in bytes, while
                            // UnsafePointer<Float>.advanced(by:) expects a
                            // number of Float elements.  Advancing the typed
                            // pointer by a byte count skipped 4x the intended
                            // position after the first chunk and could corrupt
                            // large PCM caches.  Advance the raw byte buffer.
                            bytesNoCopy: UnsafeMutableRawPointer(mutating: rawBuffer.baseAddress!.advanced(by: offset)),
                            count: count,
                            deallocator: .none
                        )
                        try handle.write(contentsOf: chunk)
                        offset += count
                    }
                }
                try handle.synchronize()
                try handle.close()
                fileHandle = nil

                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try FileManager.default.replaceItemAt(
                        url,
                        withItemAt: temporaryURL,
                        backupItemName: nil,
                        options: [.usingNewMetadataOnly]
                    )
                } else {
                    try FileManager.default.moveItem(at: temporaryURL, to: url)
                }
            } catch {
                try? fileHandle?.close()
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }
    }

    private func registerDiskWrite(_ task: Task<Void, Never>, for key: String) -> UUID {
        let id = UUID()
        diskWrites[key] = DiskWriteFlight(id: id, task: task)
        return id
    }

    private func clearDiskWrite(for key: String, id: UUID) {
        guard diskWrites[key]?.id == id else { return }
        diskWrites[key] = nil
    }

    private static func removeCacheFiles(for key: String, in directories: [URL]) {
        let cacheName = "\(key).pcmcache"
        let temporaryPrefix = "\(cacheName).tmp-"
        for directory in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files {
                let name = file.lastPathComponent
                guard name == cacheName || name.hasPrefix(temporaryPrefix) else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func cancelWaiter(_ waiterID: UUID, for key: String, flightID: UUID) {
        guard var flight = inFlight[key], flight.id == flightID else { return }
        flight.waiters.remove(waiterID)
        if flight.waiters.isEmpty, !flight.isCompleted {
            inFlight[key] = nil
            flight.task.cancel()
        } else {
            inFlight[key] = flight
        }
    }

    private func removeWaiter(_ waiterID: UUID, for key: String, flightID: UUID) {
        guard var flight = inFlight[key], flight.id == flightID else { return }
        flight.waiters.remove(waiterID)
        inFlight[key] = flight
    }

    private func markFlightCompleted(for key: String, flightID: UUID) -> Bool {
        guard var flight = inFlight[key], flight.id == flightID else { return false }
        guard !flight.isCompleted else { return false }
        flight.isCompleted = true
        inFlight[key] = flight
        return true
    }

    private func removeCompletedFlight(for key: String, flightID: UUID) {
        guard let flight = inFlight[key], flight.id == flightID, flight.isCompleted else { return }
        inFlight[key] = nil
    }

    private func removeFailedFlight(for key: String, flightID: UUID) {
        guard let flight = inFlight[key], flight.id == flightID else { return }
        if flight.waiters.isEmpty || flight.task.isCancelled {
            inFlight[key] = nil
        }
    }

    private static func pruneDiskCache(in directory: URL) {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentAccessDateKey,
            .contentModificationDateKey
        ]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else { return }
        let now = Date()
        let maximumAge: TimeInterval = 30 * 24 * 60 * 60
        let maximumBytes: Int64 = 4 * 1024 * 1024 * 1024
        var retained: [(url: URL, size: Int64, date: Date)] = []
        var totalBytes: Int64 = 0

        for url in files where url.pathExtension == "pcmcache" {
            guard let values = try? url.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true else { continue }
            let date = values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(date) > maximumAge {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let size = Int64(values.fileSize ?? 0)
            retained.append((url, size, date))
            totalBytes += size
        }

        guard totalBytes > maximumBytes else { return }
        for item in retained.sorted(by: { $0.date < $1.date }) where totalBytes > maximumBytes {
            if (try? FileManager.default.removeItem(at: item.url)) != nil {
                totalBytes -= item.size
            }
        }
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

    private static func decodeUncachedToCache(
        from url: URL,
        cacheURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> AudioPCMData {
        if Self.ffmpegExecutableURL() != nil {
            // 与无缓存路径保持一致：正式包优先使用可控的 ffmpeg，避免
            // AVAssetReader 在 macOS 26 的并发 AAC 解码路径中触发进程级异常。
            try await extractWithFFmpeg(
                from: url,
                writingTo: cacheURL,
                progress: progress
            )
        } else {
            try await extractWithAVFoundation(
                from: url,
                writingTo: cacheURL,
                progress: progress
            )
        }
        guard let mapped = readDiskCache(from: cacheURL) else {
            throw PCMExtractionError.cacheWriteFailed
        }
        return mapped
    }

    private static func extractWithAVFoundation(
        from url: URL,
        writingTo cacheURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let durationTime = try? await asset.load(.duration)
        let duration = durationTime.map(CMTimeGetSeconds) ?? 0
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw PCMExtractionError.noAudioTrack }

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

        let writer = try PCMCacheStreamWriter(destinationURL: cacheURL)
        defer { writer.cancel() }
        var decodeScratch: [Float] = []
        var lastProgress = 0.0
        while reader.status == .reading {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            try writeSamples(from: sampleBuffer, to: writer, scratch: &decodeScratch)
            if duration.isFinite, duration > 0 {
                let decodedDuration = Double(writer.sampleCount) / Double(AudioPCMData.requiredSampleRate)
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
        guard writer.sampleCount > 0 else { throw PCMExtractionError.emptyAudio }
        try writer.finish()
        progress?(1)
    }

    private static func writeSamples(
        from sampleBuffer: CMSampleBuffer,
        to writer: PCMCacheStreamWriter,
        scratch: inout [Float]
    ) throws {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw PCMExtractionError.decoderFailed
        }
        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        let floatCount = byteCount / MemoryLayout<Float>.size
        guard floatCount > 0 else { return }

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
            let floats = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Float.self)
            try writer.append(UnsafeBufferPointer(start: floats, count: floatCount))
            return
        }

        if scratch.capacity < floatCount { scratch.reserveCapacity(floatCount) }
        scratch.removeAll(keepingCapacity: true)
        scratch.append(contentsOf: repeatElement(0, count: floatCount))
        let status = scratch.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: floatCount * MemoryLayout<Float>.size,
                destination: baseAddress
            )
        }
        guard status == kCMBlockBufferNoErr else { throw PCMExtractionError.decoderFailed }
        try scratch.withUnsafeBufferPointer { try writer.append($0) }
    }

    private static func extractWithFFmpeg(
        from url: URL,
        writingTo cacheURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        guard let executable = Self.ffmpegExecutableURL() else {
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

        let writer = try PCMCacheStreamWriter(destinationURL: cacheURL)
        defer { writer.cancel() }
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
            var combined = pending
            combined.append(data)
            let alignedByteCount = combined.count - combined.count % MemoryLayout<Float>.size
            if alignedByteCount > 0 {
                try writer.appendRawBytes(combined.prefix(alignedByteCount))
            }
            pending = Data(combined.suffix(combined.count - alignedByteCount))

            if duration.isFinite, duration > 0 {
                let value = min(0.99, Double(writer.sampleCount) / Double(AudioPCMData.requiredSampleRate) / duration)
                if value - lastProgress >= 0.01 {
                    lastProgress = value
                    progress?(value)
                }
            }
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        guard process.terminationStatus == 0, writer.sampleCount > 0, pending.isEmpty else {
            throw PCMExtractionError.decoderFailed
        }
        try writer.finish()
        progress?(1)
    }

    private static func decodeUncached(
        from url: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> AudioPCMData {
        // macOS 26 的 AVAssetReader 在多个媒体同时打开、或 AAC 尾包异常时
        // 可能触发 AVFAudio 的进程级异常（Swift 无法 catch）。应用已有
        // ffmpeg 解码器时优先走同一条可控路径，保证波形、断句和播放器不会
        // 因系统解码器的内部状态导致整个应用退出。仅在正式包没有 ffmpeg
        // 时保留 AVFoundation 作为系统原生兜底。
        if Self.ffmpegExecutableURL() != nil {
            return try await extractWithFFmpeg(from: url, progress: progress)
        }
        return try await extractWithAVFoundation(from: url, progress: progress)
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
        // 非连续 CMBlockBuffer 的兜底复制会复用这块临时内存，避免每个
        // sample buffer 都重新分配和释放一个 [Float]。
        var decodeScratch: [Float] = []
        var lastProgress = 0.0

        while reader.status == .reading {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            try appendSamples(from: sampleBuffer, to: &samples, scratch: &decodeScratch)

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

    private static func appendSamples(
        from sampleBuffer: CMSampleBuffer,
        to samples: inout [Float],
        scratch: inout [Float]
    ) throws {
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

        if scratch.capacity < floatCount {
            scratch.reserveCapacity(floatCount)
        }
        scratch.removeAll(keepingCapacity: true)
        scratch.append(contentsOf: repeatElement(0, count: floatCount))
        let status = scratch.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: floatCount * MemoryLayout<Float>.size,
                destination: baseAddress
            )
        }
        guard status == kCMBlockBufferNoErr else { throw PCMExtractionError.decoderFailed }
        samples.append(contentsOf: scratch)
    }

    private static func extractWithFFmpeg(
        from url: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> AudioPCMData {
        guard let executable = Self.ffmpegExecutableURL() else {
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
            let combined: Data
            if pending.isEmpty {
                combined = data
            } else {
                var joined = pending
                joined.append(data)
                combined = joined
            }
            let floatCount = combined.count / MemoryLayout<Float>.size
            if floatCount > 0 {
                let byteCount = floatCount * MemoryLayout<Float>.size
                let oldCount = samples.count
                samples.append(contentsOf: repeatElement(0, count: floatCount))
                samples.withUnsafeMutableBytes { destination in
                    combined.withUnsafeBytes { source in
                        guard let destinationBase = destination.baseAddress,
                              let sourceBase = source.baseAddress else { return }
                        destinationBase.advanced(by: oldCount * MemoryLayout<Float>.size)
                            .copyMemory(from: sourceBase, byteCount: byteCount)
                    }
                }
            }
            pending = Data(combined.suffix(combined.count - floatCount * MemoryLayout<Float>.size))

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

    /// 供媒体导出与扩展解码共用，确保正式包始终优先使用内置 ffmpeg。
    static func ffmpegExecutableURL() -> URL? {
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
    case cacheWriteFailed

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "媒体中没有可用的音轨。"
        case .decoderUnavailable: return "系统无法创建音频解码器。"
        case .decoderFailed: return "音频解码失败。"
        case .emptyAudio: return "音轨中没有可供断句的音频。"
        case .ffmpegUnavailable: return "该媒体格式需要应用内置的 ffmpeg 解码器。"
        case .cacheWriteFailed: return "无法写入 PCM 缓存，已改用内存解码。"
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
