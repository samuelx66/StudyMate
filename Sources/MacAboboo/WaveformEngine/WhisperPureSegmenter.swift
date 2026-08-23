import Foundation

/// 纯 Whisper 语义与词级高精断句器
/// 算法特点：
/// 1. 100% 仅依赖 Whisper 语义识别与词级时间戳（Word-level Timestamps）
/// 2. 彻底脱离声学物理静音依赖，强力抵抗背景音乐、嘈杂音效与多人无缝对话抢话
/// 3. 基于语法标点（. ? ! ,）与单词边界精准切分
public final class WhisperPureSegmenter: @unchecked Sendable {
    public static let shared = WhisperPureSegmenter()
    
    public init() {}
    
    /// 执行纯 Whisper 语义与词级断句切分
    /// - Parameters:
    ///   - sentences: Whisper 识别出的完整语义句子列表（包含每个单词的毫秒级时间戳）
    ///   - duration: 音频总时长
    ///   - autoGenerateSubtitles: 是否将识别出的英文原文填入字幕
    /// - Returns: 纯 Whisper 语义切分的高精断句列表
    public func segment(
        sentences: [SpeechAlignmentEngine.TranscribedSentence],
        duration: Double,
        autoGenerateSubtitles: Bool = true
    ) -> [SentenceSegment] {
        guard !sentences.isEmpty, duration > 0 else { return [] }
        
        var segments = [SentenceSegment]()
        segments.reserveCapacity(sentences.count)
        
        for (i, sent) in sentences.enumerated() {
            let trimmedText = sent.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { continue }
            
            var start = sent.startTime
            var end = sent.endTime
            
            // 优先使用首词与尾词的毫秒级时间戳
            if let firstWord = sent.words.first {
                start = min(start, firstWord.startTime)
            }
            if let lastWord = sent.words.last {
                end = max(end, lastWord.endTime)
            }
            
            // 句尾微调防掐尾音缓冲 (+120ms)
            end = min(duration, end + 0.12)
            
            // 边界约束
            start = max(0.0, min(duration, start))
            end = max(start + 0.20, min(duration, end))
            
            // 相邻句子重叠平滑处理
            if let last = segments.last {
                if start < last.endTime {
                    let midpoint = (last.endTime + start) / 2.0
                    segments[segments.count - 1].endTime = midpoint
                    start = midpoint
                }
            }
            
            let textToSet = autoGenerateSubtitles ? trimmedText : ""
            
            segments.append(SentenceSegment(
                id: UUID(),
                index: i + 1,
                startTime: start,
                endTime: end,
                text: textToSet,
                translation: ""
            ))
        }
        
        // 重新连续编号
        var finalResult = [SentenceSegment]()
        for (i, seg) in segments.enumerated() {
            var s = seg
            s.index = i + 1
            finalResult.append(s)
        }
        return finalResult
    }
    
    /// 执行纯 Whisper 语义与词级断句切分（带波形降级保护）
    public func segment(
        sentences: [SpeechAlignmentEngine.TranscribedSentence],
        waveform: WaveformData,
        duration: Double,
        autoGenerateSubtitles: Bool = true
    ) -> [SentenceSegment] {
        if !sentences.isEmpty {
            return segment(sentences: sentences, duration: duration, autoGenerateSubtitles: autoGenerateSubtitles)
        }
        
        let fallback = SileroVADEngine.shared.legacyDetectSegments(from: waveform, config: .noiseResistant)
        var finalResult = [SentenceSegment]()
        for (i, seg) in fallback.enumerated() {
            var s = seg
            s.index = i + 1
            s.text = ""
            s.translation = ""
            finalResult.append(s)
        }
        return finalResult
    }
}
