import Foundation
import AVFoundation
import Accelerate

/// 原生音频波形抽取器（基于 AVAssetReader + Accelerate vDSP 硬件加速，毫秒级快速抽取）
public final class WaveformExtractor: @unchecked Sendable {
    public static let shared = WaveformExtractor()
    
    // 内存缓存
    private let cache = NSCache<NSString, WaveformCacheWrapper>()
    
    private final class WaveformCacheWrapper {
        let data: WaveformData
        init(data: WaveformData) { self.data = data }
    }
    
    public init() {
        cache.countLimit = 30
    }
    
    /// 异步提取波形数据
    @discardableResult
    public func extractWaveform(
        from url: URL,
        targetSamplesPerSecond: Double = 100,
        onProgress: (@Sendable (Double, WaveformData) -> Void)? = nil,
        completion: @escaping @Sendable (Result<WaveformData, Error>) -> Void
    ) -> Task<Void, Never> {
        let samplingRate = targetSamplesPerSecond.isFinite ? min(1_000, max(1, targetSamplesPerSecond)) : 100
        let cacheKey = waveformCacheKey(for: url, samplesPerSecond: samplingRate)
        if let cached = cache.object(forKey: cacheKey) {
            completion(.success(cached.data))
            return Task {}
        }
        
        return Task.detached(priority: .userInitiated) {
            do {
                let data: WaveformData
                do {
                    data = try await self.extractWithAVAssetReader(
                        url: url,
                        targetSamplesPerSecond: samplingRate,
                        onProgress: onProgress
                    )
                } catch is CancellationError {
                    return
                } catch {
                    // AVFoundation 不支持的容器/编码（例如部分 MKV、APE）交给随应用打包的 ffmpeg。
                    data = try await self.extractWithFFmpeg(
                        url: url,
                        targetSamplesPerSecond: samplingRate,
                        onProgress: onProgress
                    )
                }
                guard !Task.isCancelled else { return }
                self.cache.setObject(WaveformCacheWrapper(data: data), forKey: cacheKey)
                await MainActor.run {
                    onProgress?(1.0, data)
                    completion(.success(data))
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }

    private func waveformCacheKey(for url: URL, samplesPerSecond: Double) -> NSString {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? -1
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? -1
        return "\(url.standardizedFileURL.path)|\(size)|\(modified)|\(samplesPerSecond)" as NSString
    }
    
    // MARK: - AVAssetReader 原生硬件加速解码
    
    private func extractWithAVAssetReader(
        url: URL,
        targetSamplesPerSecond: Double,
        onProgress: (@Sendable (Double, WaveformData) -> Void)?
    ) async throws -> WaveformData {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        try Task.checkCancellation()
        let durationCM = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(durationCM)
        
        guard duration > 0, !duration.isNaN else {
            throw NSError(domain: "WaveformExtractor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid asset duration"])
        }
        
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw NSError(domain: "WaveformExtractor", code: -2, userInfo: [NSLocalizedDescriptionKey: "No audio track found in media"])
        }
        
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 22050.0
        ]
        
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOutput) else {
            throw NSError(domain: "WaveformExtractor", code: -3, userInfo: [NSLocalizedDescriptionKey: "Audio track cannot be decoded"])
        }
        reader.add(trackOutput)
        
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "WaveformExtractor", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to start reading audio"])
        }
        
        let audioSampleRate: Double = 22050.0
        let samplesPerBin = max(1, Int(audioSampleRate / targetSamplesPerSecond))
        
        var allMinPeaks = [Float]()
        var allMaxPeaks = [Float]()
        var allPeaks = [Float]()
        
        let estimatedBins = Int(duration * targetSamplesPerSecond) + 100
        allMinPeaks.reserveCapacity(estimatedBins)
        allMaxPeaks.reserveCapacity(estimatedBins)
        allPeaks.reserveCapacity(estimatedBins)
        
        var leftover = [Float]()
        leftover.reserveCapacity(samplesPerBin * 2)
        var lastProgressReportTime = Date()
        var lastReportedProgress = 0.0
        
        while reader.status == .reading {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let sampleBuffer = trackOutput.copyNextSampleBuffer(),
                  let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                break
            }
            
            let length = CMBlockBufferGetDataLength(blockBuffer)
            let sampleCount = length / MemoryLayout<Float>.size
            guard sampleCount > 0 else { continue }
            
            var data = [Float](repeating: 0, count: sampleCount)
            data.withUnsafeMutableBytes { rawBuffer in
                _ = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: rawBuffer.baseAddress!)
            }
            
            data.withUnsafeBufferPointer { bufPtr in
                guard let basePtr = bufPtr.baseAddress else { return }
                var offset = 0
                let totalAvailable = bufPtr.count
                
                // 1. 如果之前有未凑满一个 bin 的剩余采样点，先补齐
                if !leftover.isEmpty {
                    let needed = samplesPerBin - leftover.count
                    if totalAvailable >= needed {
                        leftover.append(contentsOf: bufPtr[0..<needed])
                        offset = needed
                        
                        var maxVal: Float = 0
                        var minVal: Float = 0
                        leftover.withUnsafeBufferPointer { ptr in
                            guard let base = ptr.baseAddress else { return }
                            vDSP_maxv(base, 1, &maxVal, vDSP_Length(ptr.count))
                            vDSP_minv(base, 1, &minVal, vDSP_Length(ptr.count))
                        }
                        allMinPeaks.append(minVal)
                        allMaxPeaks.append(maxVal)
                        allPeaks.append(min(1.0, max(0.0, max(abs(minVal), abs(maxVal)))))
                        leftover.removeAll(keepingCapacity: true)
                    } else {
                        leftover.append(contentsOf: bufPtr)
                        return
                    }
                }
                
                // 2. 纯指针步进，通过 Accelerate vDSP 硬件指令零拷贝秒级计算
                while (totalAvailable - offset) >= samplesPerBin {
                    var maxVal: Float = 0
                    var minVal: Float = 0
                    let currentChunkPtr = basePtr.advanced(by: offset)
                    vDSP_maxv(currentChunkPtr, 1, &maxVal, vDSP_Length(samplesPerBin))
                    vDSP_minv(currentChunkPtr, 1, &minVal, vDSP_Length(samplesPerBin))
                    
                    allMinPeaks.append(minVal)
                    allMaxPeaks.append(maxVal)
                    allPeaks.append(min(1.0, max(0.0, max(abs(minVal), abs(maxVal)))))
                    
                    offset += samplesPerBin
                }
                
                // 3. 将尾部剩余采样点缓存至 leftover
                if offset < totalAvailable {
                    leftover.append(contentsOf: bufPtr[offset..<totalAvailable])
                }
            }
            
            let currentSecs = Double(allPeaks.count) / targetSamplesPerSecond
            let progress = min(0.99, currentSecs / max(1.0, duration))
            if let onProgress = onProgress,
               Date().timeIntervalSince(lastProgressReportTime) > 0.35,
               progress - lastReportedProgress >= 0.01 {
                lastProgressReportTime = Date()
                lastReportedProgress = progress
                let interimData = WaveformData(
                    peaks: allPeaks,
                    minPeaks: allMinPeaks,
                    maxPeaks: allMaxPeaks,
                    duration: max(duration, currentSecs),
                    sampleRate: targetSamplesPerSecond
                )
                await MainActor.run {
                    onProgress(progress, interimData)
                }
            }
        }

        if reader.status == .failed {
            throw reader.error ?? NSError(
                domain: "WaveformExtractor",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Audio decoding failed"]
            )
        }
        try Task.checkCancellation()
        
        if !leftover.isEmpty {
            var maxVal: Float = 0
            var minVal: Float = 0
            leftover.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                vDSP_maxv(base, 1, &maxVal, vDSP_Length(ptr.count))
                vDSP_minv(base, 1, &minVal, vDSP_Length(ptr.count))
            }
            allMinPeaks.append(minVal)
            allMaxPeaks.append(maxVal)
            allPeaks.append(min(1.0, max(0.0, max(abs(minVal), abs(maxVal)))))
        }
        
        normalizePeaks(&allPeaks, minPeaks: &allMinPeaks, maxPeaks: &allMaxPeaks)
        
        let actualDuration = max(duration, Double(allPeaks.count) / targetSamplesPerSecond)
        
        return WaveformData(
            peaks: allPeaks,
            minPeaks: allMinPeaks,
            maxPeaks: allMaxPeaks,
            duration: actualDuration,
            sampleRate: targetSamplesPerSecond
        )
    }

    // MARK: - ffmpeg 兜底（扩展格式）

    private func extractWithFFmpeg(
        url: URL,
        targetSamplesPerSecond: Double,
        onProgress: (@Sendable (Double, WaveformData) -> Void)?
    ) async throws -> WaveformData {
        guard let executable = ffmpegExecutableURL() else {
            throw NSError(
                domain: "WaveformExtractor",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "The media format is unsupported and the bundled ffmpeg helper is unavailable."]
            )
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executable
        process.arguments = [
            "-nostdin", "-v", "error", "-i", url.path,
            "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "22050",
            "-f", "f32le", "pipe:1"
        ]
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()

        let samplesPerBin = max(1, Int(22_050 / targetSamplesPerSecond))
        var pendingBytes = Data()
        var pendingSamples: [Float] = []
        var peaks: [Float] = []
        var minPeaks: [Float] = []
        var maxPeaks: [Float] = []
        var lastReport = Date()

        defer {
            try? outputPipe.fileHandleForReading.close()
            if process.isRunning { process.terminate() }
        }

        while true {
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
            guard let bytes = try outputPipe.fileHandleForReading.read(upToCount: 256 * 1024), !bytes.isEmpty else {
                break
            }
            pendingBytes.append(bytes)
            let floatCount = pendingBytes.count / MemoryLayout<Float>.size
            guard floatCount > 0 else { continue }
            let usableByteCount = floatCount * MemoryLayout<Float>.size
            var decoded = [Float](repeating: 0, count: floatCount)
            _ = decoded.withUnsafeMutableBytes { destination in
                pendingBytes.copyBytes(to: destination, from: pendingBytes.startIndex..<(pendingBytes.startIndex + usableByteCount))
            }
            pendingBytes.removeFirst(usableByteCount)
            pendingSamples.append(contentsOf: decoded)

            var consumed = 0
            while pendingSamples.count - consumed >= samplesPerBin {
                let range = consumed..<(consumed + samplesPerBin)
                var minimum: Float = 0
                var maximum: Float = 0
                pendingSamples.withUnsafeBufferPointer { pointer in
                    guard let base = pointer.baseAddress else { return }
                    vDSP_minv(base.advanced(by: range.lowerBound), 1, &minimum, vDSP_Length(samplesPerBin))
                    vDSP_maxv(base.advanced(by: range.lowerBound), 1, &maximum, vDSP_Length(samplesPerBin))
                }
                minPeaks.append(minimum)
                maxPeaks.append(maximum)
                peaks.append(min(1, max(abs(minimum), abs(maximum))))
                consumed += samplesPerBin
            }
            if consumed > 0 { pendingSamples.removeFirst(consumed) }

            if let onProgress, Date().timeIntervalSince(lastReport) > 0.25 {
                lastReport = Date()
                let elapsed = Double(peaks.count) / targetSamplesPerSecond
                let interim = WaveformData(
                    peaks: peaks,
                    minPeaks: minPeaks,
                    maxPeaks: maxPeaks,
                    duration: elapsed,
                    sampleRate: targetSamplesPerSecond
                )
                await MainActor.run { onProgress(0, interim) }
            }
        }

        process.waitUntilExit()
        try Task.checkCancellation()
        if !pendingSamples.isEmpty {
            let minimum = pendingSamples.min() ?? 0
            let maximum = pendingSamples.max() ?? 0
            minPeaks.append(minimum)
            maxPeaks.append(maximum)
            peaks.append(min(1, max(abs(minimum), abs(maximum))))
        }
        guard process.terminationStatus == 0, !peaks.isEmpty else {
            throw NSError(
                domain: "WaveformExtractor",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "ffmpeg could not decode an audio stream from this media."]
            )
        }

        normalizePeaks(&peaks, minPeaks: &minPeaks, maxPeaks: &maxPeaks)
        return WaveformData(
            peaks: peaks,
            minPeaks: minPeaks,
            maxPeaks: maxPeaks,
            duration: Double(peaks.count) / targetSamplesPerSecond,
            sampleRate: targetSamplesPerSecond
        )
    }

    private func ffmpegExecutableURL() -> URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    
    private func normalizePeaks(_ peaks: inout [Float], minPeaks: inout [Float], maxPeaks: inout [Float]) {
        var globalMax: Float = 0
        peaks.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress, ptr.count > 0 else { return }
            vDSP_maxv(base, 1, &globalMax, vDSP_Length(ptr.count))
        }
        
        if globalMax > 0.05 && globalMax < 0.85 {
            let scale = 0.85 / globalMax
            for i in 0..<peaks.count {
                peaks[i] = min(1.0, peaks[i] * scale)
                minPeaks[i] = max(-1.0, minPeaks[i] * scale)
                maxPeaks[i] = min(1.0, maxPeaks[i] * scale)
            }
        }
    }
}
