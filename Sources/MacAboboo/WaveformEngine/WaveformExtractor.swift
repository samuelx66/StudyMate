import Foundation

/// 从统一的 16 kHz PCM 生成波形，避免波形和断句分别全量解码音频。
public final class WaveformExtractor: @unchecked Sendable {
    public static let shared = WaveformExtractor()

    private let cache = NSCache<NSString, WaveformCacheWrapper>()

    private final class WaveformCacheWrapper {
        let data: WaveformData

        init(data: WaveformData) {
            self.data = data
        }
    }

    public init() {
        cache.countLimit = 30
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    public func purgeMemoryCache() {
        cache.removeAllObjects()
    }

    /// 异步提取波形数据。音频解码由 `AudioPCMExtractor` 统一完成并共享缓存。
    @discardableResult
    public func extractWaveform(
        from url: URL,
        targetSamplesPerSecond: Double = 100,
        onProgress: (@Sendable (Double, WaveformData) -> Void)? = nil,
        completion: @escaping @Sendable (Result<WaveformData, Error>) -> Void
    ) -> Task<Void, Never> {
        let samplingRate = targetSamplesPerSecond.isFinite
            ? min(1_000, max(1, targetSamplesPerSecond))
            : 100
        let cacheKey = waveformCacheKey(for: url, samplesPerSecond: samplingRate)
        if let cached = cache.object(forKey: cacheKey) {
            completion(.success(cached.data))
            return Task {}
        }

        return Task.detached(priority: .userInitiated) {
            do {
                let pcm = try await AudioPCMExtractor.shared.extract(from: url) { progress in
                    // 中间阶段只有解码进度，没有可安全复用的完整波形数组。
                    onProgress?(progress, .empty)
                }
                try Task.checkCancellation()
                let data = pcm.waveform(samplesPerSecond: samplingRate)
                guard !Task.isCancelled else { return }

                self.cache.setObject(
                    WaveformCacheWrapper(data: data),
                    forKey: cacheKey,
                    cost: self.cacheCost(for: data)
                )
                await MainActor.run {
                    onProgress?(1, data)
                    completion(.success(data))
                }
            } catch is CancellationError {
                return
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

    private func cacheCost(for data: WaveformData) -> Int {
        let elementCount = data.peaks.count + data.minPeaks.count + data.maxPeaks.count
        guard elementCount <= Int.max / MemoryLayout<Float>.size else { return Int.max }
        return elementCount * MemoryLayout<Float>.size
    }
}
