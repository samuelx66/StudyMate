import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// 波形数据结构（支持快速分段插值与多分辨率提取）
public struct WaveformData: Equatable, Codable, Sendable {
    /// 最小振幅 (用于真实双极性波形 -1.0 ~ 0.0)
    public let minPeaks: [Float]
    /// 最大振幅 (用于真实双极性波形 0.0 ~ 1.0)
    public let maxPeaks: [Float]
    /// 音频总时长（秒）
    public let duration: Double
    /// 每秒采样点数（默认通常提取 100~200 个点/秒）
    public let sampleRate: Double
    /// 预计算的波形指纹特征，供渲染缓存快速辨识波形身份
    public let signature: String
    
    public init(
        peaks: [Float] = [],
        minPeaks: [Float] = [],
        maxPeaks: [Float] = [],
        duration: Double = 0,
        sampleRate: Double = 100
    ) {
        let sanitizedPeaks = peaks.map { value in
            value.isFinite ? min(1, max(0, abs(value))) : 0
        }
        let resolvedMinPeaks: [Float]
        if minPeaks.count == sanitizedPeaks.count {
            resolvedMinPeaks = minPeaks.map { $0.isFinite ? min(0, max(-1, $0)) : 0 }
        } else {
            resolvedMinPeaks = sanitizedPeaks.map { -$0 }
        }
        let resolvedMaxPeaks: [Float]
        if maxPeaks.count == sanitizedPeaks.count {
            resolvedMaxPeaks = maxPeaks.map { $0.isFinite ? max(0, min(1, $0)) : 0 }
        } else {
            resolvedMaxPeaks = sanitizedPeaks
        }
        self.minPeaks = resolvedMinPeaks
        self.maxPeaks = resolvedMaxPeaks
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.sampleRate = sampleRate.isFinite ? max(1, sampleRate) : 100
        self.signature = Self.computeSignature(minPeaks: resolvedMinPeaks, maxPeaks: resolvedMaxPeaks)
    }

    /// Internal fast path for PCM/cache output that has already validated the
    /// array lengths and finite sample range. `peaks` is retained only as an
    /// input compatibility parameter: the value is exactly derivable from
    /// the bipolar envelope and is no longer stored as a third long array.
    init(
        uncheckedPeaks peaks: [Float],
        minPeaks: [Float],
        maxPeaks: [Float],
        duration: Double,
        sampleRate: Double
    ) {
        self.minPeaks = minPeaks
        self.maxPeaks = maxPeaks
        self.duration = duration
        self.sampleRate = sampleRate
        self.signature = Self.computeSignature(minPeaks: minPeaks, maxPeaks: maxPeaks)
    }

    private static func computeSignature(minPeaks: [Float], maxPeaks: [Float]) -> String {
        let count = min(minPeaks.count, maxPeaks.count)
        guard count > 0 else { return "empty" }
        let lastIndex = count - 1
        var samples: [String] = []
        samples.reserveCapacity(9)
        for position in 0...8 {
            let idx = (lastIndex * position) / 8
            let peak = max(abs(minPeaks[idx]), abs(maxPeaks[idx]))
            samples.append(String(peak))
        }
        return samples.joined(separator: "|")
    }

    private enum CodingKeys: String, CodingKey {
        case peaks, minPeaks, maxPeaks, duration, sampleRate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            peaks: try container.decodeIfPresent([Float].self, forKey: .peaks) ?? [],
            minPeaks: try container.decodeIfPresent([Float].self, forKey: .minPeaks) ?? [],
            maxPeaks: try container.decodeIfPresent([Float].self, forKey: .maxPeaks) ?? [],
            duration: try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0,
            sampleRate: try container.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 100
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(minPeaks, forKey: .minPeaks)
        try container.encode(maxPeaks, forKey: .maxPeaks)
        try container.encode(duration, forKey: .duration)
        try container.encode(sampleRate, forKey: .sampleRate)
    }
    
    public static let empty = WaveformData(peaks: [], duration: 0, sampleRate: 100)
    
    public var isEmpty: Bool {
        minPeaks.isEmpty || duration <= 0
    }

    /// 与旧 API 兼容的派生值。生产渲染和断句代码使用 `peakCount` / `peak(at:)`
    /// 避免在长媒体处理中临时生成整个数组。
    public var peaks: [Float] {
        zip(minPeaks, maxPeaks).map { max(abs($0), abs($1)) }
    }

    public var peakCount: Int { minPeaks.count }

    public func peak(at index: Int) -> Float {
        guard minPeaks.indices.contains(index), maxPeaks.indices.contains(index) else { return 0 }
        return max(abs(minPeaks[index]), abs(maxPeaks[index]))
    }
    
    /// 获取指定时间范围内的重采样峰值数组，适合直接渲染到指定像素宽度
    /// - Parameters:
    ///   - startTime: 起始时间（秒）
    ///   - endTime: 结束时间（秒）
    ///   - targetCount: 目标输出的柱状图/点数（如屏幕宽度像素数 / 柱宽）
    /// - Returns: 归一化 (min, max) 数组
    public func resample(startTime: Double, endTime: Double, targetCount: Int) -> [(min: Float, max: Float)] {
        guard targetCount > 0, !minPeaks.isEmpty, duration > 0 else {
            return []
        }
        
        let clampedStart = max(0, min(startTime, duration))
        let clampedEnd = max(clampedStart, min(endTime, duration))
        let rangeDuration = clampedEnd - clampedStart

        guard rangeDuration > 0 else {
            return Array(repeating: (min: 0, max: 0), count: targetCount)
        }

        let startIdx = Int(clampedStart * sampleRate)
        let endIdx = min(peakCount, Int(ceil(clampedEnd * sampleRate)))

        guard endIdx > startIdx else {
            return Array(repeating: (min: 0, max: 0), count: targetCount)
        }

        let totalSrcSamples = endIdx - startIdx
        var result = [(min: Float, max: Float)]()
        result.reserveCapacity(targetCount)

        let samplesPerBin = Double(totalSrcSamples) / Double(targetCount)

        minPeaks.withUnsafeBufferPointer { minBuffer in
            maxPeaks.withUnsafeBufferPointer { maxBuffer in
                for i in 0..<targetCount {
                    let binStart = startIdx + Int(Double(i) * samplesPerBin)
                    let binEnd = min(endIdx, startIdx + Int(Double(i + 1) * samplesPerBin) + 1)

                    if binStart >= peakCount {
                        result.append((min: 0, max: 0))
                        continue
                    }

                    let count = min(binEnd, peakCount) - binStart
                    if count > 0 {
                        var binMin: Float = 0
                        var binMax: Float = 0

                        #if canImport(Accelerate)
                        if count >= 4,
                           let minPtr = minBuffer.baseAddress,
                           let maxPtr = maxBuffer.baseAddress {
                            vDSP_minv(minPtr.advanced(by: binStart), 1, &binMin, vDSP_Length(count))
                            vDSP_maxv(maxPtr.advanced(by: binStart), 1, &binMax, vDSP_Length(count))
                        } else {
                            binMin = minBuffer[binStart]
                            binMax = maxBuffer[binStart]
                            for s in (binStart + 1)..<(binStart + count) {
                                let pMax = maxBuffer[s]
                                let pMin = minBuffer[s]
                                if pMax > binMax { binMax = pMax }
                                if pMin < binMin { binMin = pMin }
                            }
                        }
                        #else
                        binMin = minBuffer[binStart]
                        binMax = maxBuffer[binStart]
                        for s in (binStart + 1)..<(binStart + count) {
                            let pMax = maxBuffer[s]
                            let pMin = minBuffer[s]
                            if pMax > binMax { binMax = pMax }
                            if pMin < binMin { binMin = pMin }
                        }
                        #endif

                        result.append((min: binMin, max: binMax))
                    } else {
                        result.append((min: minBuffer[binStart], max: maxBuffer[binStart]))
                    }
                }
            }
        }

        return result
    }
}
