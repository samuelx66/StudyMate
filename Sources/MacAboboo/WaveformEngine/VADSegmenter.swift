import Foundation
import Accelerate

/// 智能语音断句检测器（基于短时能量与静音波谷检测，确保在句子自然停顿处断句）
public final class VADSegmenter {
    public static let shared = VADSegmenter()
    
    /// 断句灵敏度配置
    public struct Config {
        /// 最小静音停顿长度（秒）—— 超过此停顿长度判定为一句话结束
        public var minSilenceDuration: Double
        /// 单句最短时长（秒）
        public var minSentenceDuration: Double
        /// 单句最大建议时长（秒）—— 超过此时长将寻找次级能量波谷拆分
        public var maxSentenceDuration: Double
        /// 静音能量阈值倍率 (0.05 ~ 0.35)
        public var silenceThresholdRatio: Float
        /// 起止点呼吸缓冲 padding（秒）
        public var paddingDuration: Double
        
        public init(
            minSilenceDuration: Double = 0.30,
            minSentenceDuration: Double = 1.0,
            maxSentenceDuration: Double = 12.0,
            silenceThresholdRatio: Float = 0.15,
            paddingDuration: Double = 0.08
        ) {
            self.minSilenceDuration = minSilenceDuration
            self.minSentenceDuration = minSentenceDuration
            self.maxSentenceDuration = maxSentenceDuration
            self.silenceThresholdRatio = silenceThresholdRatio
            self.paddingDuration = paddingDuration
        }
        
        public static let normal = Config()
        public static let sensitive = Config(minSilenceDuration: 0.20, minSentenceDuration: 0.8, maxSentenceDuration: 8.0, silenceThresholdRatio: 0.20)
        public static let relaxed = Config(minSilenceDuration: 0.50, minSentenceDuration: 1.5, maxSentenceDuration: 15.0, silenceThresholdRatio: 0.10)
    }
    
    public init() {}
    
    /// 从波形数据中自动识别语音段与自然停顿点，生成断句列表
    /// - Parameters:
    ///   - waveform: 波形数据
    ///   - config: 灵敏度配置
    /// - Returns: 断句列表
    public func detectSegments(from waveform: WaveformData, config: Config = .normal) -> [SentenceSegment] {
        guard !waveform.isEmpty, waveform.duration > 0 else {
            return []
        }
        
        let peaks = waveform.peaks
        let sampleRate = waveform.sampleRate
        let totalSamples = peaks.count
        let totalDuration = waveform.duration
        
        guard totalSamples > 0 else { return [] }
        
        // 1. 平滑短时能量包络（基于滑动累加器的高性能 O(N) 移动平均滤波）
        let halfWindow = max(1, Int(sampleRate * 0.06))
        var smoothed = [Float](repeating: 0, count: totalSamples)
        var runningSum: Float = 0
        let initialEnd = min(totalSamples - 1, halfWindow)
        for s in 0...initialEnd {
            runningSum += peaks[s]
        }
        
        for i in 0..<totalSamples {
            let addIdx = i + halfWindow
            let removeIdx = i - halfWindow - 1
            if addIdx < totalSamples && addIdx > initialEnd {
                runningSum += peaks[addIdx]
            }
            if removeIdx >= 0 {
                runningSum -= peaks[removeIdx]
            }
            let validStart = max(0, i - halfWindow)
            let validEnd = min(totalSamples - 1, i + halfWindow)
            let count = validEnd - validStart + 1
            smoothed[i] = runningSum / Float(max(1, count))
        }
        
        // 2. 动态计算静音能量阈值
        var minVal: Float = 1.0
        var maxVal: Float = 0.0
        for p in smoothed {
            if p < minVal { minVal = p }
            if p > maxVal { maxVal = p }
        }
        
        let dynamicRange = max(0.01, maxVal - minVal)
        let silenceThreshold = minVal + dynamicRange * config.silenceThresholdRatio
        
        // 3. 寻找静音区间 (Silence Intervals)
        struct SilenceInterval {
            let startSample: Int
            let endSample: Int
            let minEnergySample: Int
        }
        
        var silenceIntervals = [SilenceInterval]()
        var inSilence = false
        var silenceStart = 0
        var lowestVal = Float.greatestFiniteMagnitude
        var lowestIdx = 0
        
        let minSilenceSamples = max(1, Int(config.minSilenceDuration * sampleRate))
        
        for i in 0..<totalSamples {
            let energy = smoothed[i]
            let isQuiet = energy <= silenceThreshold
            
            if isQuiet {
                if !inSilence {
                    inSilence = true
                    silenceStart = i
                    lowestVal = energy
                    lowestIdx = i
                } else if energy < lowestVal {
                    lowestVal = energy
                    lowestIdx = i
                }
            } else {
                if inSilence {
                    inSilence = false
                    let length = i - silenceStart
                    if length >= minSilenceSamples {
                        silenceIntervals.append(SilenceInterval(
                            startSample: silenceStart,
                            endSample: i,
                            minEnergySample: lowestIdx
                        ))
                    }
                }
            }
        }
        
        // 尾部静音处理
        if inSilence && (totalSamples - silenceStart) >= minSilenceSamples {
            silenceIntervals.append(SilenceInterval(
                startSample: silenceStart,
                endSample: totalSamples,
                minEnergySample: lowestIdx
            ))
        }
        
        // 4. 根据静音波谷生成初始切分点
        var cutPoints = [Double]()
        cutPoints.append(0.0)
        
        var lastCutTime = 0.0
        let minSentenceSecs = config.minSentenceDuration
        
        for interval in silenceIntervals {
            let silenceValleyTime = Double(interval.minEnergySample) / sampleRate
            
            // 距离上一个切分点满足单句最短时长要求
            if (silenceValleyTime - lastCutTime) >= minSentenceSecs {
                // 如果当前距离音频结束过近 (< 0.5s)，则合并到末尾
                if (totalDuration - silenceValleyTime) >= 0.5 {
                    cutPoints.append(silenceValleyTime)
                    lastCutTime = silenceValleyTime
                }
            }
        }
        
        if cutPoints.last != totalDuration {
            cutPoints.append(totalDuration)
        }
        
        // 5. 对过长的句子（> maxSentenceDuration）进行二次细分（寻找句子中间最明显的能量凹陷）
        var refinedCutPoints = [Double]()
        for i in 0..<(cutPoints.count - 1) {
            let segStart = cutPoints[i]
            let segEnd = cutPoints[i + 1]
            refinedCutPoints.append(segStart)
            
            let segLen = segEnd - segStart
            if segLen > config.maxSentenceDuration {
                let parts = Int(ceil(segLen / config.maxSentenceDuration))
                let idealPartDuration = segLen / Double(parts)
                
                var currentPartStart = segStart
                for p in 1..<parts {
                    let searchCenter = segStart + Double(p) * idealPartDuration
                    let searchStartSample = Int(max(currentPartStart + minSentenceSecs, searchCenter - 1.5) * sampleRate)
                    let searchEndSample = Int(min(segEnd - minSentenceSecs, searchCenter + 1.5) * sampleRate)
                    
                    if searchEndSample > searchStartSample && searchStartSample < totalSamples {
                        var bestSample = searchStartSample
                        var bestVal: Float = smoothed[searchStartSample]
                        for s in searchStartSample..<min(searchEndSample, totalSamples) {
                            if smoothed[s] < bestVal {
                                bestVal = smoothed[s]
                                bestSample = s
                            }
                        }
                        let subCut = Double(bestSample) / sampleRate
                        refinedCutPoints.append(subCut)
                        currentPartStart = subCut
                    }
                }
            }
        }
        refinedCutPoints.append(totalDuration)
        refinedCutPoints = Array(Set(refinedCutPoints)).sorted()
        
        // 6. 构造最终断句列表
        var segments = [SentenceSegment]()
        for i in 0..<(refinedCutPoints.count - 1) {
            let start = refinedCutPoints[i]
            let end = refinedCutPoints[i + 1]
            
            if end - start >= 0.2 {
                let seg = SentenceSegment(
                    index: segments.count + 1,
                    startTime: start,
                    endTime: end,
                    text: "Sentence \(segments.count + 1)"
                )
                segments.append(seg)
            }
        }
        
        // 容底保护：如果音频极其嘈杂没有任何静音，生成合理分段
        if segments.isEmpty {
            let fallbackStep = min(6.0, max(3.0, totalDuration / 6.0))
            var cur = 0.0
            var count = 1
            while cur < totalDuration {
                let nxt = min(totalDuration, cur + fallbackStep)
                segments.append(SentenceSegment(
                    index: count,
                    startTime: cur,
                    endTime: nxt,
                    text: "Sentence \(count)"
                ))
                cur = nxt
                count += 1
            }
        }
        
        return segments
    }
}
