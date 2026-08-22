import Foundation

/// Silero VAD + Whisper 双引擎智能锚点熔合器
/// 将语义级识别句子（Whisper / Speech.framework）与物理级声学概率曲线（Silero VAD）在毫秒级微调熔合
public final class DualEngineFusionSegmenter: @unchecked Sendable {
    public static let shared = DualEngineFusionSegmenter()
    
    public init() {}
    
    /// 熔合语义转写句子与 Silero VAD 声学波形概率
    /// - Parameters:
    ///   - sentences: 语音识别转写出的语义句子列表
    ///   - waveform: 波形数据
    ///   - vadConfig: Silero VAD 门限与前后 Padding 缓冲配置
    /// - Returns: 经双引擎声学校准、绝不吞字头/尾音的高精断句列表
    public func fuse(
        sentences: [SpeechAlignmentEngine.TranscribedSentence],
        waveform: WaveformData,
        vadConfig: SileroVADEngine.Config = .standard
    ) -> [SentenceSegment] {
        guard !sentences.isEmpty else {
            // 若转写为空，自动回退到纯 Silero VAD 声学断句
            return SileroVADEngine.shared.detectSegments(from: waveform, config: vadConfig)
        }
        
        let frames = SileroVADEngine.shared.extractSpeechProbabilityTimeline(from: waveform, config: vadConfig)
        let totalDuration = waveform.duration
        
        var refined = [SentenceSegment]()
        refined.reserveCapacity(sentences.count)
        
        var lastValidEnd: Double = 0.0
        
        for (i, item) in sentences.enumerated() {
            let rawStart = item.startTime
            let rawEnd = item.endTime
            
            // 1. 句首声学防吞音回溯 (向左搜索真实声学起始点)
            var calibratedStart = max(lastValidEnd, rawStart - vadConfig.onsetPadding)
            if !frames.isEmpty {
                // 在 [rawStart - 0.4s, rawStart] 区间内向前搜寻 VAD 概率跃迁点
                let searchMin = max(lastValidEnd, rawStart - 0.45)
                let onsetCandidates = frames.filter { $0.time >= searchMin && $0.time <= rawStart }
                if let firstSpeech = onsetCandidates.first(where: { $0.probability >= vadConfig.threshold }) {
                    calibratedStart = max(lastValidEnd, firstSpeech.time - vadConfig.onsetPadding)
                }
            }
            
            // 2. 句尾声学防截断延展 (向右搜索真实声学衰减点)
            var calibratedEnd = min(totalDuration, rawEnd + vadConfig.offsetHangover)
            if !frames.isEmpty {
                // 在 [rawEnd, rawEnd + 0.6s] 区间内向后搜寻 VAD 概率彻底归零点
                let searchMax = min(totalDuration, rawEnd + 0.65)
                let offsetCandidates = frames.filter { $0.time >= rawEnd && $0.time <= searchMax }
                if let lastSpeech = offsetCandidates.last(where: { $0.probability >= vadConfig.negThreshold }) {
                    calibratedEnd = min(totalDuration, lastSpeech.time + vadConfig.offsetHangover)
                }
            }
            
            // 确保单句最小时长
            if (calibratedEnd - calibratedStart) < vadConfig.minSpeechDuration {
                calibratedEnd = min(totalDuration, calibratedStart + vadConfig.minSpeechDuration)
            }
            
            // 确保相邻句子边界不交叠
            if calibratedStart < lastValidEnd {
                calibratedStart = lastValidEnd
            }
            if calibratedEnd <= calibratedStart {
                calibratedEnd = min(totalDuration, calibratedStart + 0.5)
            }
            
            lastValidEnd = calibratedEnd
            
            refined.append(SentenceSegment(
                index: i + 1,
                startTime: calibratedStart,
                endTime: calibratedEnd,
                text: item.text.trimmingCharacters(in: .whitespacesAndNewlines),
                translation: ""
            ))
        }
        
        return refined
    }
}
