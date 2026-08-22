import Foundation

/// 波形数据结构（支持快速分段插值与多分辨率提取）
public struct WaveformData: Equatable, Codable, Sendable {
    /// 归一化振幅数据 (0.0 ~ 1.0)
    public let peaks: [Float]
    /// 最小振幅 (用于真实双极性波形 -1.0 ~ 0.0)
    public let minPeaks: [Float]
    /// 最大振幅 (用于真实双极性波形 0.0 ~ 1.0)
    public let maxPeaks: [Float]
    /// 音频总时长（秒）
    public let duration: Double
    /// 每秒采样点数（默认通常提取 100~200 个点/秒）
    public let sampleRate: Double
    
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
        self.peaks = sanitizedPeaks
        if minPeaks.count == sanitizedPeaks.count {
            self.minPeaks = minPeaks.map { $0.isFinite ? min(0, max(-1, $0)) : 0 }
        } else {
            self.minPeaks = sanitizedPeaks.map { -$0 }
        }
        if maxPeaks.count == sanitizedPeaks.count {
            self.maxPeaks = maxPeaks.map { $0.isFinite ? max(0, min(1, $0)) : 0 }
        } else {
            self.maxPeaks = sanitizedPeaks
        }
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.sampleRate = sampleRate.isFinite ? max(1, sampleRate) : 100
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
        try container.encode(peaks, forKey: .peaks)
        try container.encode(minPeaks, forKey: .minPeaks)
        try container.encode(maxPeaks, forKey: .maxPeaks)
        try container.encode(duration, forKey: .duration)
        try container.encode(sampleRate, forKey: .sampleRate)
    }
    
    public static let empty = WaveformData(peaks: [], duration: 0, sampleRate: 100)
    
    public var isEmpty: Bool {
        peaks.isEmpty || duration <= 0
    }
    
    /// 获取指定时间范围内的重采样峰值数组，适合直接渲染到指定像素宽度
    /// - Parameters:
    ///   - startTime: 起始时间（秒）
    ///   - endTime: 结束时间（秒）
    ///   - targetCount: 目标输出的柱状图/点数（如屏幕宽度像素数 / 柱宽）
    /// - Returns: 归一化 (min, max) 数组
    public func resample(startTime: Double, endTime: Double, targetCount: Int) -> [(min: Float, max: Float)] {
        guard targetCount > 0, !peaks.isEmpty, duration > 0 else {
            return []
        }
        
        let clampedStart = max(0, min(startTime, duration))
        let clampedEnd = max(clampedStart, min(endTime, duration))
        let rangeDuration = clampedEnd - clampedStart
        
        guard rangeDuration > 0 else {
            return Array(repeating: (min: 0, max: 0), count: targetCount)
        }
        
        let startIdx = Int(clampedStart * sampleRate)
        let endIdx = min(peaks.count, Int(ceil(clampedEnd * sampleRate)))
        
        guard endIdx > startIdx else {
            return Array(repeating: (min: 0, max: 0), count: targetCount)
        }
        
        let totalSrcSamples = endIdx - startIdx
        var result = [(min: Float, max: Float)]()
        result.reserveCapacity(targetCount)
        
        let samplesPerBin = Double(totalSrcSamples) / Double(targetCount)
        
        for i in 0..<targetCount {
            let binStart = startIdx + Int(Double(i) * samplesPerBin)
            let binEnd = min(endIdx, startIdx + Int(Double(i + 1) * samplesPerBin) + 1)
            
            if binStart >= peaks.count {
                result.append((min: 0, max: 0))
                continue
            }
            
            var binMin: Float = 0
            var binMax: Float = 0
            
            if binStart < binEnd {
                for s in binStart..<min(binEnd, peaks.count) {
                    let pMax = maxPeaks[s]
                    let pMin = minPeaks[s]
                    if pMax > binMax { binMax = pMax }
                    if pMin < binMin { binMin = pMin }
                }
            } else {
                binMax = maxPeaks[binStart]
                binMin = minPeaks[binStart]
            }
            
            result.append((min: binMin, max: binMax))
        }
        
        return result
    }
}
