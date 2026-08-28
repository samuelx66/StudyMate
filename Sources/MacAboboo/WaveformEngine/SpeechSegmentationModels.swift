import Accelerate
import Foundation

/// 用户可见、内部也实际执行的两种断句模式。
public enum SpeechSegmentationMode: String, CaseIterable, Codable, Sendable {
    /// Silero + SpeakerKit，不启动 Whisper，优先速度与较低资源占用。
    case fast
    /// Silero + SpeakerKit + Whisper，按内容和局部证据自适应融合。
    case intelligent

    public var requiresTranscription: Bool {
        self == .intelligent
    }

    /// 模式的稳定基础参数。智能模式的最终权重和软时长目标会由
    /// `SpeechBoundaryOptimizer` 根据内容统计及每个候选边界继续调整。
    public var profile: SpeechSegmentationProfile {
        switch self {
        case .intelligent:
            return SpeechSegmentationProfile(
                vad: .init(threshold: 0.44, minSpeechDuration: 0.20, minSilenceDuration: 0.26, maxSpeechDuration: 16, speechPadding: 0.08, sampleOverlap: 0.10),
                minimumSentenceDuration: 0.45,
                preferredSentenceDuration: 4.6,
                maximumSentenceDuration: 12,
                mergeGap: 0.16,
                onsetPadding: 0.08,
                offsetPadding: 0.15,
                snapWindow: 0.36,
                semanticWeight: 1.35,
                pauseWeight: 0.95,
                acousticWeight: 0.75,
                speakerWeight: 1.50,
                splitPenalty: 0.80
            )
        case .fast:
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
        var minima: [Float] = []
        var maxima: [Float] = []
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
                index += count
            }
        }
        return WaveformData(
            uncheckedPeaks: [],
            minPeaks: minima,
            maxPeaks: maxima,
            duration: duration,
            sampleRate: targetRate
        )
    }
}

/// 本地语音模型的执行后端。它只描述推理运行时的资源选择，不参与断句边界计算。
public enum SpeechInferenceBackend: String, Sendable {
    case cpu
    case metal
    case coreML
}

/// 统一的推理资源预算。
///
/// 断句算法仍由 `SpeechBoundaryOptimizer` 完整决定；本策略只限制线程数、
/// SpeakerKit 工作线程和模型阶段并发，避免 Silero、SpeakerKit 与 Whisper
/// 同时抢占所有 CPU 核心。资源预算会根据当前机器核心数和热状态自适应，
/// 不写入用户设置，也不会改变任何 profile 的阈值或权重。
public struct SpeechInferenceResourcePolicy: Equatable, Sendable {
    public let whisperThreadCount: Int32
    public let vadThreadCount: Int32
    public let speakerSegmenterWorkers: Int
    public let speakerEmbedderWorkers: Int
    public let preferWhisperMetal: Bool
    public let preferSpeakerCoreML: Bool

    public static func current(
        processorCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> SpeechInferenceResourcePolicy {
        let cores = max(1, processorCount)
        let constrained = thermalState == .serious || thermalState == .critical

        // Keep a few cores available for AVPlayer, waveform drawing and the
        // main actor. The previous fixed upper bound of eight threads could
        // oversubscribe smaller machines and make the UI visibly stutter.
        let whisperThreads = constrained
            ? max(2, min(4, cores - 4))
            : max(2, min(6, cores - 3))
        let vadThreads = constrained
            ? 2
            : max(2, min(4, max(2, cores / 2)))
        let segmenterWorkers = constrained
            ? 1
            : max(1, min(2, max(1, cores / 4)))
        let embedderWorkers = constrained
            ? 1
            : max(1, min(2, max(1, cores / 4)))

        #if arch(arm64)
        let speakerAccelerated = !constrained
        // The bundled whisper.cpp Metal backend currently aborts during
        // process teardown on some macOS 14/Apple Silicon combinations. An
        // abort cannot be caught as a normal inference error, so keep the
        // stable CPU path as the release default. Developers can opt in after
        // upgrading the vendor framework to a fixed build.
        let whisperMetalOptIn = !constrained
            && ProcessInfo.processInfo.environment["MACABOBOO_ENABLE_WHISPER_METAL"] == "1"
        #else
        let speakerAccelerated = false
        let whisperMetalOptIn = false
        #endif

        return SpeechInferenceResourcePolicy(
            whisperThreadCount: Int32(whisperThreads),
            vadThreadCount: Int32(vadThreads),
            speakerSegmenterWorkers: segmenterWorkers,
            speakerEmbedderWorkers: embedderWorkers,
            preferWhisperMetal: whisperMetalOptIn,
            preferSpeakerCoreML: speakerAccelerated
        )
    }

    public init(
        whisperThreadCount: Int32,
        vadThreadCount: Int32,
        speakerSegmenterWorkers: Int,
        speakerEmbedderWorkers: Int,
        preferWhisperMetal: Bool,
        preferSpeakerCoreML: Bool
    ) {
        self.whisperThreadCount = max(1, whisperThreadCount)
        self.vadThreadCount = max(1, vadThreadCount)
        self.speakerSegmenterWorkers = max(1, speakerSegmenterWorkers)
        self.speakerEmbedderWorkers = max(1, speakerEmbedderWorkers)
        self.preferWhisperMetal = preferWhisperMetal
        self.preferSpeakerCoreML = preferSpeakerCoreML
    }
}

/// 跨 Silero、SpeakerKit 和 Whisper 的单阶段资源闸门。
///
/// 模型内部仍可使用自身的有限 worker 并行，但不同模型阶段不再同时
/// 启动多个全量推理任务。这样既保留现有算法顺序，又避免打开长视频时
/// 三套模型叠加造成 CPU 峰值和界面卡顿。
public actor SpeechInferenceResourceScheduler {
    public static let shared = SpeechInferenceResourceScheduler()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var availablePermits: Int
    private var waiters: [Waiter] = []

    public init(permits: Int = 1) {
        self.availablePermits = max(1, permits)
    }

    public func withExclusiveStage<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire()
        do {
            try Task.checkCancellation()
        } catch {
            release()
            throw error
        }
        do {
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            let waiter = waiters.removeFirst()
            // Transfer the permit directly to the resumed waiter.
            waiter.continuation.resume()
        }
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

/// One posterior emitted by the bundled Silero model. `time` is the center of
/// the model frame on the original media timeline, not a waveform-energy
/// estimate. Keeping this evidence separate from final VAD intervals lets the
/// boundary optimizer measure valley depth and onset/offset slopes directly.
public struct VADProbabilityFrame: Equatable, Sendable {
    public var time: Double
    public var probability: Float

    public init(time: Double, probability: Float) {
        self.time = max(0, time)
        self.probability = min(1, max(0, probability))
    }
}

public struct VoiceActivityAnalysis: Equatable, Sendable {
    public var segments: [VoiceActivitySegment]
    public var probabilities: [VADProbabilityFrame]
    public var frameDuration: Double

    public init(
        segments: [VoiceActivitySegment],
        probabilities: [VADProbabilityFrame],
        frameDuration: Double
    ) {
        self.segments = segments
        self.probabilities = probabilities
        self.frameDuration = max(0, frameDuration)
    }
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
