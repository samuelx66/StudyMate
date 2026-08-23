import Accelerate
import Foundation

/// 面向普通用户的三种断句预设。内部六个 profile 仍保留，用于精细调参与兼容旧调用方。
public enum SpeechSegmentationPreset: String, CaseIterable, Codable, Sendable {
    /// Whisper + Silero + SpeakerKit，适合嘈杂背景和多人对话。
    case highPrecision
    /// Silero + SpeakerKit，不启动 Whisper，优先速度和资源占用。
    case fast
    /// Whisper 语义优先，适合停顿不明显或背景音乐较强的内容。
    case semantic

    /// 将用户可见预设映射到同一流水线中的内部 profile。
    /// 句子长度只影响需要长度调节的高精度/快速预设，语义预设始终保持语义优先。
    public func mode(for sentenceLength: SpeechSentenceLength) -> SpeechSegmentationMode {
        switch self {
        case .highPrecision:
            switch sentenceLength {
            case .short: return .whisperSemantic
            case .standard: return .sileroWhisperCascade
            case .long: return .semanticAcousticFusion
            }
        case .fast:
            switch sentenceLength {
            case .short: return .vadSensitive
            case .standard: return .vadStandard
            case .long: return .vadRelaxed
            }
        case .semantic:
            return .whisperSemantic
        }
    }
}

/// 高级设置中的句子长度偏好。它只选择同一流水线的 profile，不改变算法架构。
public enum SpeechSentenceLength: String, CaseIterable, Codable, Sendable {
    case short
    case standard
    case long
}

/// 六个内部 profile 对应的统一断句策略。profile 只改变权重与阈值，不再各自维护一套算法。
public enum SpeechSegmentationMode: String, CaseIterable, Codable, Sendable {
    case sileroWhisperCascade
    case whisperSemantic
    case semanticAcousticFusion
    case vadStandard
    case vadSensitive
    case vadRelaxed

    public var requiresTranscription: Bool {
        switch self {
        case .sileroWhisperCascade, .whisperSemantic, .semanticAcousticFusion:
            return true
        case .vadStandard, .vadSensitive, .vadRelaxed:
            return false
        }
    }

    public var profile: SpeechSegmentationProfile {
        switch self {
        case .sileroWhisperCascade:
            return SpeechSegmentationProfile(
                vad: .init(threshold: 0.42, minSpeechDuration: 0.22, minSilenceDuration: 0.28, maxSpeechDuration: 14, speechPadding: 0.08, sampleOverlap: 0.10),
                minimumSentenceDuration: 0.55,
                preferredSentenceDuration: 4.5,
                maximumSentenceDuration: 10,
                mergeGap: 0.16,
                onsetPadding: 0.08,
                offsetPadding: 0.14,
                snapWindow: 0.36,
                semanticWeight: 1.25,
                pauseWeight: 0.90,
                acousticWeight: 0.75,
                speakerWeight: 1.40,
                splitPenalty: 0.78
            )
        case .whisperSemantic:
            return SpeechSegmentationProfile(
                vad: .init(threshold: 0.48, minSpeechDuration: 0.18, minSilenceDuration: 0.22, maxSpeechDuration: 14, speechPadding: 0.05, sampleOverlap: 0.08),
                minimumSentenceDuration: 0.45,
                preferredSentenceDuration: 4.0,
                maximumSentenceDuration: 9,
                mergeGap: 0.12,
                onsetPadding: 0.05,
                offsetPadding: 0.10,
                snapWindow: 0.24,
                semanticWeight: 1.60,
                pauseWeight: 0.58,
                acousticWeight: 0.22,
                speakerWeight: 1.55,
                splitPenalty: 0.82
            )
        case .semanticAcousticFusion:
            return SpeechSegmentationProfile(
                vad: .init(threshold: 0.50, minSpeechDuration: 0.25, minSilenceDuration: 0.36, maxSpeechDuration: 16, speechPadding: 0.09, sampleOverlap: 0.10),
                minimumSentenceDuration: 0.60,
                preferredSentenceDuration: 5.2,
                maximumSentenceDuration: 12,
                mergeGap: 0.18,
                onsetPadding: 0.09,
                offsetPadding: 0.17,
                snapWindow: 0.42,
                semanticWeight: 1.05,
                pauseWeight: 1.10,
                acousticWeight: 1.25,
                speakerWeight: 1.45,
                splitPenalty: 0.80
            )
        case .vadStandard:
            return SpeechSegmentationProfile(
                vad: .init(threshold: 0.50, minSpeechDuration: 0.28, minSilenceDuration: 0.32, maxSpeechDuration: 12, speechPadding: 0.10, sampleOverlap: 0.08),
                minimumSentenceDuration: 0.55,
                preferredSentenceDuration: 5.0,
                maximumSentenceDuration: 12,
                mergeGap: 0.18,
                onsetPadding: 0.08,
                offsetPadding: 0.14,
                snapWindow: 0.30,
                semanticWeight: 0,
                pauseWeight: 1,
                acousticWeight: 1,
                speakerWeight: 0,
                splitPenalty: 0
            )
        case .vadSensitive:
            return SpeechSegmentationProfile(
                vad: .init(threshold: 0.38, minSpeechDuration: 0.18, minSilenceDuration: 0.22, maxSpeechDuration: 7, speechPadding: 0.11, sampleOverlap: 0.08),
                minimumSentenceDuration: 0.35,
                preferredSentenceDuration: 3.2,
                maximumSentenceDuration: 7,
                mergeGap: 0.10,
                onsetPadding: 0.10,
                offsetPadding: 0.16,
                snapWindow: 0.28,
                semanticWeight: 0,
                pauseWeight: 1,
                acousticWeight: 1,
                speakerWeight: 0,
                splitPenalty: 0
            )
        case .vadRelaxed:
            return SpeechSegmentationProfile(
                vad: .init(threshold: 0.58, minSpeechDuration: 0.38, minSilenceDuration: 0.50, maxSpeechDuration: 18, speechPadding: 0.10, sampleOverlap: 0.10),
                minimumSentenceDuration: 0.80,
                preferredSentenceDuration: 8.0,
                maximumSentenceDuration: 18,
                mergeGap: 0.32,
                onsetPadding: 0.08,
                offsetPadding: 0.18,
                snapWindow: 0.40,
                semanticWeight: 0,
                pauseWeight: 1,
                acousticWeight: 1,
                speakerWeight: 0,
                splitPenalty: 0
            )
        }
    }
}

public struct VoiceActivityConfiguration: Equatable, Sendable {
    public var threshold: Float
    public var minSpeechDuration: Double
    public var minSilenceDuration: Double
    public var maxSpeechDuration: Double
    public var speechPadding: Double
    public var sampleOverlap: Double

    public init(
        threshold: Float,
        minSpeechDuration: Double,
        minSilenceDuration: Double,
        maxSpeechDuration: Double,
        speechPadding: Double,
        sampleOverlap: Double
    ) {
        self.threshold = min(0.99, max(0.01, threshold))
        self.minSpeechDuration = max(0.05, minSpeechDuration)
        self.minSilenceDuration = max(0.05, minSilenceDuration)
        self.maxSpeechDuration = max(1, maxSpeechDuration)
        self.speechPadding = max(0, speechPadding)
        self.sampleOverlap = max(0, sampleOverlap)
    }
}

public struct SpeechSegmentationProfile: Equatable, Sendable {
    public var vad: VoiceActivityConfiguration
    public var minimumSentenceDuration: Double
    public var preferredSentenceDuration: Double
    public var maximumSentenceDuration: Double
    public var mergeGap: Double
    public var onsetPadding: Double
    public var offsetPadding: Double
    public var snapWindow: Double
    public var semanticWeight: Double
    public var pauseWeight: Double
    public var acousticWeight: Double
    public var speakerWeight: Double
    public var splitPenalty: Double
}

public struct AudioPCMData: Sendable {
    public static let requiredSampleRate = 16_000

    public var samples: [Float]
    public var sampleRate: Int

    public init(samples: [Float], sampleRate: Int = requiredSampleRate) {
        self.samples = samples.map { $0.isFinite ? min(1, max(-1, $0)) : 0 }
        self.sampleRate = sampleRate
    }

    /// Internal fast path for decoder/cache output that has already been
    /// validated. The public initializer keeps its defensive sanitization for
    /// callers that construct PCM manually.
    init(uncheckedSamples: [Float], sampleRate: Int = requiredSampleRate) {
        self.samples = uncheckedSamples
        self.sampleRate = sampleRate
    }

    public var duration: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / Double(sampleRate)
    }

    public var isEmpty: Bool { samples.isEmpty || sampleRate <= 0 }

    public func waveform(samplesPerSecond: Double = 100) -> WaveformData {
        guard !isEmpty else { return .empty }
        let targetRate = max(10, min(1_000, samplesPerSecond))
        let samplesPerBin = max(1, Int(Double(sampleRate) / targetRate))
        let estimatedBins = samples.count / samplesPerBin + 1
        var peaks: [Float] = []
        var minima: [Float] = []
        var maxima: [Float] = []
        peaks.reserveCapacity(estimatedBins)
        minima.reserveCapacity(estimatedBins)
        maxima.reserveCapacity(estimatedBins)

        samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var index = 0
            while index < buffer.count {
                let count = min(samplesPerBin, buffer.count - index)
                let bin = baseAddress.advanced(by: index)
                var minimum: Float = 0
                var maximum: Float = 0
                vDSP_minv(bin, 1, &minimum, vDSP_Length(count))
                vDSP_maxv(bin, 1, &maximum, vDSP_Length(count))
                minima.append(minimum)
                maxima.append(maximum)
                peaks.append(max(abs(minimum), abs(maximum)))
                index += count
            }
        }
        return WaveformData(
            peaks: peaks,
            minPeaks: minima,
            maxPeaks: maxima,
            duration: duration,
            sampleRate: targetRate
        )
    }
}

public struct SpeechToken: Equatable, Sendable {
    public var text: String
    public var startTime: Double
    public var endTime: Double
    public var confidence: Float
    public var recognitionSegmentIndex: Int
    public var speakerTurnAfter: Bool
    /// SpeakerKit assignment after token/time overlap matching. Multiple IDs
    /// can mean either a turn boundary inside the token or true overlap;
    /// `speakerOverlap` is the authoritative simultaneous-speech flag.
    public var speakerIDs: [Int]
    public var speakerConfidence: Float
    public var speakerOverlap: Bool

    public init(
        text: String,
        startTime: Double,
        endTime: Double,
        confidence: Float = 1,
        recognitionSegmentIndex: Int = 0,
        speakerTurnAfter: Bool = false,
        speakerIDs: [Int] = [],
        speakerConfidence: Float = 0,
        speakerOverlap: Bool = false
    ) {
        self.text = text
        self.startTime = max(0, startTime)
        self.endTime = max(self.startTime, endTime)
        self.confidence = min(1, max(0, confidence))
        self.recognitionSegmentIndex = recognitionSegmentIndex
        self.speakerTurnAfter = speakerTurnAfter
        self.speakerIDs = Array(Set(speakerIDs)).sorted()
        self.speakerConfidence = min(1, max(0, speakerConfidence))
        self.speakerOverlap = speakerOverlap
    }
}

public struct VoiceActivitySegment: Equatable, Sendable {
    public var startTime: Double
    public var endTime: Double
    public var confidence: Float

    public init(startTime: Double, endTime: Double, confidence: Float = 1) {
        self.startTime = max(0, startTime)
        self.endTime = max(self.startTime, endTime)
        self.confidence = min(1, max(0, confidence))
    }

    public var duration: Double { max(0, endTime - startTime) }
}

public struct SpeechRecognitionTimeline: Sendable {
    public var tokens: [SpeechToken]
    public var voiceSegments: [VoiceActivitySegment]
    public var detectedLanguage: String
    public var speakerSegments: [SpeakerDiarizationSegment]

    public init(
        tokens: [SpeechToken],
        voiceSegments: [VoiceActivitySegment],
        detectedLanguage: String,
        speakerSegments: [SpeakerDiarizationSegment] = []
    ) {
        self.tokens = tokens
        self.voiceSegments = voiceSegments
        self.detectedLanguage = detectedLanguage
        self.speakerSegments = speakerSegments
    }
}
