import Foundation

/// Silero + Whisper 两阶段级联双模断句器（已废弃）
/// 新的统一断句流程请使用 `SpeechSegmentationPipeline` + `SpeechBoundaryOptimizer`。
/// 本类保留仅为历史记录与回归对比用途，不再被主流水线调用。
@available(*, deprecated, renamed: "SpeechSegmentationPipeline", message: "Use SpeechSegmentationPipeline.run(request:stageChanged:preview:) instead.")
public final class SileroWhisperCascadeSegmenter: @unchecked Sendable {
    public static let shared = SileroWhisperCascadeSegmenter()
    
    public init() {}
    
    /// 执行 Silero 粗切 + Whisper 精修的两阶段双模切分与台词填充
    /// - Parameters:
    ///   - sentences: Whisper 或 Speech.framework 识别出的完整语义句子列表
    ///   - waveform: 波形数据
    ///   - vadConfig: Silero 声学断句配置
    /// - Returns: 最终高精断句列表（包含时间轴与英文原文台词）
    public func segment(
        sentences: [SpeechAlignmentEngine.TranscribedSentence],
        waveform: WaveformData,
        vadConfig: SileroVADEngine.Config = .standard
    ) -> [SentenceSegment] {
        let duration = waveform.duration
        guard duration > 0 else { return [] }
        
        // 1. 第一阶段：Silero VAD 毫秒级声学粗切
        let rawSileroSegments = SileroVADEngine.shared.legacyDetectSegments(from: waveform, config: vadConfig)
        
        // 若没有识别到任何 Whisper 文本，执行声学能量次级谷底平滑切分（确保长句被自然拆为 2.5s~5.5s 黄金复读句）
        guard !sentences.isEmpty else {
            return refineAcoustically(rawSileroSegments, waveform: waveform, vadConfig: vadConfig)
        }
        
        // 2. 第二阶段：Whisper 语义句子与 Silero 物理区间智能对齐与边界校准
        var calibrated = [SentenceSegment]()
        calibrated.reserveCapacity(sentences.count)
        
        for (i, sent) in sentences.enumerated() {
            let sText = sent.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sText.isEmpty else { continue }
            
            // 语义起止时间
            var start = sent.startTime
            var end = sent.endTime
            
            // 若包含词级时间戳，以第一个词和最后一个词为精准锚点
            if let firstWord = sent.words.first, let lastWord = sent.words.last {
                start = min(start, firstWord.startTime)
                end = max(end, lastWord.endTime)
            }
            
            // 在 Silero 粗切区间中寻找最佳覆盖/重叠声学块
            var matchingSilero: SentenceSegment?
            var maxOverlap: Double = 0.0
            
            for sileroSeg in rawSileroSegments {
                let overlapStart = max(start, sileroSeg.startTime)
                let overlapEnd = min(end, sileroSeg.endTime)
                let overlap = max(0.0, overlapEnd - overlapStart)
                if overlap > maxOverlap {
                    maxOverlap = overlap
                    matchingSilero = sileroSeg
                }
            }
            
            // 3. 第三阶段：首尾安全边距微调
            if let matched = matchingSilero {
                // 若声学检测到更早的发声起点（可能为轻声起始音），安全向左靠拢
                if matched.startTime < start && (start - matched.startTime) <= 0.35 {
                    start = matched.startTime
                } else {
                    start = max(0.0, start - vadConfig.onsetPadding)
                }
                
                // 若声学检测到尾音延展，安全向右靠拢
                if matched.endTime > end && (matched.endTime - end) <= 0.45 {
                    end = matched.endTime
                } else {
                    end = min(duration, end + vadConfig.offsetHangover)
                }
            } else {
                // 无对应 Silero 块时应用默认防吞音边距
                start = max(0.0, start - vadConfig.onsetPadding)
                end = min(duration, end + vadConfig.offsetHangover)
            }
            
            // 边界约束
            start = max(0.0, min(duration, start))
            end = max(start + 0.15, min(duration, end))
            
            // 相邻句子防重叠冲突平滑处理
            if let last = calibrated.last {
                if start < last.endTime {
                    let midpoint = (last.endTime + start) / 2.0
                    calibrated[calibrated.count - 1].endTime = midpoint
                    start = midpoint
                }
            }
            
            calibrated.append(SentenceSegment(
                id: UUID(),
                index: i + 1,
                startTime: start,
                endTime: end,
                text: sText,
                translation: ""
            ))
        }
        
        // 兜底保护
        if calibrated.isEmpty {
            return rawSileroSegments
        }
        
        // 重新编号
        var finalResult = [SentenceSegment]()
        for (i, seg) in calibrated.enumerated() {
            var s = seg
            s.index = i + 1
            finalResult.append(s)
        }
        
        return finalResult
    }
    
    private func refineAcoustically(
        _ segments: [SentenceSegment],
        waveform: WaveformData,
        vadConfig: SileroVADEngine.Config
    ) -> [SentenceSegment] {
        guard !segments.isEmpty, !waveform.isEmpty else { return segments }
        let peaks = waveform.peaks
        let sampleRate = waveform.sampleRate
        guard sampleRate > 0 else { return segments }
        
        var refined = [SentenceSegment]()
        refined.reserveCapacity(segments.count * 2)
        
        for seg in segments {
            let dur = seg.duration
            if dur <= 5.5 {
                refined.append(seg)
                continue
            }
            
            // 对长发音块寻找中间能量谷底进行平滑切分
            var bestSplitTime: Double?
            var minEnergy: Float = Float.greatestFiniteMagnitude
            
            let searchStart = seg.startTime + max(2.0, dur * 0.35)
            let searchEnd = seg.endTime - max(2.0, dur * 0.35)
            
            if searchEnd > searchStart {
                let startIdx = max(0, Int(searchStart * sampleRate))
                let endIdx = min(peaks.count - 1, Int(searchEnd * sampleRate))
                
                if endIdx > startIdx {
                    for idx in startIdx...endIdx {
                        let val = peaks[idx]
                        if val < minEnergy {
                            minEnergy = val
                            bestSplitTime = Double(idx) / sampleRate
                        }
                    }
                }
            }
            
            if let splitTime = bestSplitTime, minEnergy < 0.30 {
                refined.append(SentenceSegment(
                    index: refined.count + 1,
                    startTime: seg.startTime,
                    endTime: max(seg.startTime + 0.5, splitTime - 0.05),
                    text: "",
                    translation: ""
                ))
                refined.append(SentenceSegment(
                    index: refined.count + 1,
                    startTime: max(seg.startTime + 0.6, splitTime + 0.05),
                    endTime: seg.endTime,
                    text: "",
                    translation: ""
                ))
            } else {
                refined.append(seg)
            }
        }
        
        var result = [SentenceSegment]()
        for (i, s) in refined.enumerated() {
            var item = s
            item.index = i + 1
            result.append(item)
        }
        return result
    }
}
