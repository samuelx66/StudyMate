import Foundation
import Accelerate

/// 智能语音断句检测器（基于 Silero VAD 与声学防吞音缓冲）
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
        
        let sileroConfig = SileroVADEngine.Config(
            threshold: max(0.25, min(0.75, 0.55 - config.silenceThresholdRatio)),
            negThreshold: max(0.15, min(0.55, 0.35 - config.silenceThresholdRatio)),
            minSpeechDuration: max(0.2, config.minSentenceDuration * 0.4),
            minSilenceDuration: config.minSilenceDuration,
            maxSentenceDuration: config.maxSentenceDuration,
            onsetPadding: config.paddingDuration,
            offsetHangover: max(0.15, config.paddingDuration * 2.0)
        )
        let raw = SileroVADEngine.shared.detectSegments(from: waveform, config: sileroConfig)
        guard !raw.isEmpty else { return [] }
        
        var seamless = [SentenceSegment]()
        for (i, seg) in raw.enumerated() {
            let start = (i == 0) ? 0.0 : raw[i - 1].endTime
            let end = (i == raw.count - 1) ? waveform.duration : seg.endTime
            seamless.append(SentenceSegment(
                id: seg.id,
                index: i + 1,
                startTime: start,
                endTime: max(start + 0.1, end),
                text: "Sentence #\(i + 1)"
            ))
        }
        return seamless
    }
}
