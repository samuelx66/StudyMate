import Foundation

public enum SpeechSegmentationStage: Sendable {
    case decodingAudio(Double)
    case detectingVoice
    case diarizing(Double)
    case transcribing(Double)
    case optimizing
}

/// 限制进度回调频率，避免长文件的每个解码块/模型窗口都在主线程创建
/// 一个新的 UI Task。它只压缩通知，不改变模型执行或断句结果。
private final class SpeechStageProgressGate: @unchecked Sendable {
    private let callback: @Sendable (SpeechSegmentationStage) -> Void
    private let lock = NSLock()
    private var lastKind = -1
    private var lastValue = -1.0
    private var lastEmission = 0.0

    init(callback: @escaping @Sendable (SpeechSegmentationStage) -> Void) {
        self.callback = callback
    }

    func send(_ stage: SpeechSegmentationStage) {
        let (kind, value, force): (Int, Double, Bool) = {
            switch stage {
            case .decodingAudio(let progress): return (0, progress, progress >= 0.999)
            case .detectingVoice: return (1, 0, true)
            case .diarizing(let progress): return (2, progress, progress >= 0.999)
            case .transcribing(let progress): return (3, progress, progress >= 0.999)
            case .optimizing: return (4, 1, true)
            }
        }()
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let shouldEmit = force
            || kind != lastKind
            || value - lastValue >= 0.01
            || now - lastEmission >= 0.05
        if shouldEmit {
            lastKind = kind
            lastValue = value
            lastEmission = now
        }
        lock.unlock()
        guard shouldEmit else { return }
        callback(stage)
    }
}

public struct SpeechSegmentationRequest: Sendable {
    public var mediaURL: URL
    public var mode: SpeechSegmentationMode
    public var whisperModelURL: URL?
    public var recognitionLanguage: String
    public var includeRecognizedText: Bool
    public var enableSpeakerDiarization: Bool
    public var numberOfSpeakers: Int?
    /// PlaybackEngine 已经生成的同源波形。非空且时长匹配时直接复用，
    /// 避免打开文件后再次遍历整份 PCM；不匹配时流水线仍会安全重建。
    public var waveformData: WaveformData?

    public init(
        mediaURL: URL,
        mode: SpeechSegmentationMode,
        whisperModelURL: URL?,
        recognitionLanguage: String,
        includeRecognizedText: Bool,
        enableSpeakerDiarization: Bool = true,
        numberOfSpeakers: Int? = nil,
        waveformData: WaveformData? = nil
    ) {
        self.mediaURL = mediaURL
        self.mode = mode
        self.whisperModelURL = whisperModelURL
        self.recognitionLanguage = recognitionLanguage
        self.includeRecognizedText = includeRecognizedText
        self.enableSpeakerDiarization = enableSpeakerDiarization
        self.numberOfSpeakers = numberOfSpeakers
        self.waveformData = waveformData
    }
}

public struct SpeechSegmentationOutput: Sendable {
    public var segments: [SentenceSegment]
    public var detectedLanguage: String
    public var warnings: [String]

    public init(
        segments: [SentenceSegment],
        detectedLanguage: String,
        warnings: [String] = []
    ) {
        self.segments = segments
        self.detectedLanguage = detectedLanguage
        self.warnings = warnings
    }
}

/// 三种用户预设共用的唯一断句编排入口；内部仍接受六个 profile。
public actor SpeechSegmentationPipeline {
    public static let shared = SpeechSegmentationPipeline()

    private let pcmExtractor: AudioPCMExtractor
    private let runtime: NativeSpeechRuntime
    private let optimizer: SpeechBoundaryOptimizer
    private let speakerDiarizer: SpeakerDiarizationEngine
    private var voiceCache: [String: [VoiceActivitySegment]] = [:]
    private var diarizationCache: [String: SpeakerDiarizationTimeline] = [:]
    private var transcriptionCache: [String: SpeechRecognitionTimeline] = [:]
    private var voiceCacheOrder: [String] = []
    private var diarizationCacheOrder: [String] = []
    private var transcriptionCacheOrder: [String] = []
    private let maxCacheEntries = 8

    public init(
        pcmExtractor: AudioPCMExtractor = .shared,
        runtime: NativeSpeechRuntime = .shared,
        optimizer: SpeechBoundaryOptimizer = .shared,
        speakerDiarizer: SpeakerDiarizationEngine = .shared
    ) {
        self.pcmExtractor = pcmExtractor
        self.runtime = runtime
        self.optimizer = optimizer
        self.speakerDiarizer = speakerDiarizer
    }

    public func run(
        request: SpeechSegmentationRequest,
        stageChanged: @escaping @Sendable (SpeechSegmentationStage) -> Void,
        preview: @escaping @Sendable ([SentenceSegment]) -> Void
    ) async throws -> SpeechSegmentationOutput {
        let progressGate = SpeechStageProgressGate(callback: stageChanged)
        let emitStage: @Sendable (SpeechSegmentationStage) -> Void = { stage in
            progressGate.send(stage)
        }
        emitStage(.decodingAudio(0))
        let pcm = try await pcmExtractor.extract(from: request.mediaURL) { progress in
            emitStage(.decodingAudio(progress))
        }
        try Task.checkCancellation()
        let profile = request.mode.profile
        let mediaKey = Self.mediaFingerprint(for: request.mediaURL)
        let detection = try await detectVoiceAndSpeakers(
            request: request,
            pcm: pcm,
            profile: profile,
            mediaKey: mediaKey,
            stageChanged: emitStage
        )
        let voiceSegments = detection.voiceSegments
        let speakerTimeline = detection.speakerTimeline
        var warnings = detection.warnings
        try Task.checkCancellation()
        // Waveform bins are only needed by the optimizer. Build them after the
        // model stages have started so the first visible progress update is not
        // delayed by this UI-oriented representation pass.
        let waveform = Self.reusableWaveform(
            request.waveformData,
            duration: pcm.duration
        ) ?? pcm.waveform()

        let initialSegments = optimizer.optimize(
            mode: request.mode,
            timeline: nil,
            voiceSegments: voiceSegments,
            waveform: waveform,
            duration: pcm.duration,
            includeRecognizedText: false,
            speakerSegments: speakerTimeline.segments
        )
        preview(initialSegments)

        guard request.mode.requiresTranscription else {
            return SpeechSegmentationOutput(
                segments: initialSegments,
                detectedLanguage: "",
                warnings: warnings
            )
        }
        let speechWindows = transcriptionWindows(
            voiceSegments: voiceSegments,
            speakerSegments: speakerTimeline.segments,
            duration: pcm.duration
        )
        guard !speechWindows.isEmpty else {
            return SpeechSegmentationOutput(
                segments: [],
                detectedLanguage: "",
                warnings: warnings
            )
        }
        guard let modelURL = request.whisperModelURL,
              FileManager.default.fileExists(atPath: modelURL.path) else {
            throw SpeechSegmentationPipelineError.whisperModelMissing
        }

        emitStage(.transcribing(0))
        let windowFingerprint = Self.windowFingerprint(speechWindows)
        // The external windows are part of the cache identity. The internal
        // profile name is intentionally absent because with external VAD the
        // Whisper C API receives the same configuration and PCM windows;
        // switching presets can therefore reuse the exact token timeline.
        let transcriptionKey = "\(mediaKey)|whisper|\(modelURL.standardizedFileURL.path)|\(request.recognitionLanguage)|external-vad|\(windowFingerprint)|windowed-v3"
        var timeline: SpeechRecognitionTimeline
        if let cached = transcriptionCache[transcriptionKey] {
            touch(transcriptionKey, in: &transcriptionCacheOrder)
            timeline = cached
            emitStage(.transcribing(1))
        } else {
            timeline = try await runtime.transcribe(
                pcm: pcm,
                modelURL: modelURL,
                language: request.recognitionLanguage,
                configuration: profile.vad,
                useInternalVAD: false,
                speechWindows: speechWindows
            ) { progress in
                emitStage(.transcribing(progress))
            }
            insert(
                timeline,
                into: &transcriptionCache,
                order: &transcriptionCacheOrder,
                key: transcriptionKey
            )
        }
        try Task.checkCancellation()
        timeline.speakerSegments = speakerTimeline.segments

        emitStage(.optimizing)
        // Silero + SpeakerKit is the authoritative acoustic/turn timeline.
        // Whisper token timestamps are useful semantic evidence, but its
        // optional internal VAD windows must never replace the external VAD
        // boundaries for noisy multi-speaker media.
        let finalSegments = optimizer.optimize(
            mode: request.mode,
            timeline: timeline,
            voiceSegments: voiceSegments,
            waveform: waveform,
            duration: pcm.duration,
            includeRecognizedText: request.includeRecognizedText,
            speakerSegments: speakerTimeline.segments
        )
        if timeline.tokens.isEmpty, !finalSegments.isEmpty {
            warnings.append("Whisper 未返回可用的词级时间戳，已使用声学边界完成断句。")
        }
        return SpeechSegmentationOutput(
            segments: finalSegments,
            detectedLanguage: timeline.detectedLanguage,
            warnings: warnings
        )
    }

    private func transcriptionWindows(
        voiceSegments: [VoiceActivitySegment],
        speakerSegments: [SpeakerDiarizationSegment],
        duration: Double
    ) -> [VoiceActivitySegment] {
        let speakerWindows = speakerSegments.map {
            VoiceActivitySegment(
                startTime: $0.startTime,
                endTime: $0.endTime,
                confidence: $0.confidence
            )
        }
        let combined = (voiceSegments + speakerWindows).sorted { $0.startTime < $1.startTime }
        guard !combined.isEmpty else { return [] }
        var merged: [VoiceActivitySegment] = []
        for segment in combined {
            let start = min(duration, max(0, segment.startTime))
            let end = min(duration, max(start, segment.endTime))
            guard end - start >= 0.04 else { continue }
            guard let last = merged.last else {
                merged.append(VoiceActivitySegment(startTime: start, endTime: end, confidence: segment.confidence))
                continue
            }
            if start <= last.endTime + 0.35 {
                merged[merged.count - 1].endTime = max(last.endTime, end)
                merged[merged.count - 1].confidence = max(last.confidence, segment.confidence)
            } else {
                merged.append(VoiceActivitySegment(startTime: start, endTime: end, confidence: segment.confidence))
            }
        }
        return merged
    }

    private func detectVoiceAndSpeakers(
        request: SpeechSegmentationRequest,
        pcm: AudioPCMData,
        profile: SpeechSegmentationProfile,
        mediaKey: String,
        stageChanged: @escaping @Sendable (SpeechSegmentationStage) -> Void
    ) async throws -> (
        voiceSegments: [VoiceActivitySegment],
        speakerTimeline: SpeakerDiarizationTimeline,
        warnings: [String]
    ) {
        let voiceKey = "\(mediaKey)|vad|\(request.mode.rawValue)"
        let diarizationKey = "\(mediaKey)|speaker|\(request.numberOfSpeakers.map { String($0) } ?? "auto")"
        let cachedVoice = voiceCache[voiceKey]
        let cachedDiarization = request.enableSpeakerDiarization
            ? diarizationCache[diarizationKey]
            : nil
        if cachedVoice != nil { touch(voiceKey, in: &voiceCacheOrder) }
        if cachedDiarization != nil { touch(diarizationKey, in: &diarizationCacheOrder) }

        stageChanged(.detectingVoice)
        if request.enableSpeakerDiarization {
            stageChanged(.diarizing(cachedDiarization == nil ? 0 : 1))
        }

        // The two models operate on independent actor instances. Start them
        // together so SpeakerKit's relatively expensive embedding pass does
        // not add the full Silero VAD latency to every first-open operation.
        let runtime = self.runtime
        let speakerDiarizer = self.speakerDiarizer
        let voiceTask: Task<[VoiceActivitySegment], Error>? = cachedVoice == nil
            ? Task {
                try await runtime.detectVoiceActivity(
                    pcm: pcm,
                    configuration: profile.vad
                )
            }
            : nil
        let diarizationTask: Task<SpeakerDiarizationTimeline, Error>? = request.enableSpeakerDiarization && cachedDiarization == nil
            ? Task {
                try await speakerDiarizer.diarize(
                    pcm: pcm,
                    numberOfSpeakers: request.numberOfSpeakers,
                    progress: { progress in
                        stageChanged(.diarizing(progress))
                    }
                )
            }
            : nil
        defer {
            // A cancellation or an early VAD failure must not leave the other
            // model running after this pipeline request has already ended.
            voiceTask?.cancel()
            diarizationTask?.cancel()
        }

        let voiceSegments: [VoiceActivitySegment]
        if let cachedVoice {
            voiceSegments = cachedVoice
        } else {
            do {
                voiceSegments = try await voiceTask?.value ?? []
                insert(voiceSegments, into: &voiceCache, order: &voiceCacheOrder, key: voiceKey)
            } catch {
                diarizationTask?.cancel()
                throw error
            }
        }
        try Task.checkCancellation()

        var speakerTimeline = cachedDiarization ?? SpeakerDiarizationTimeline(segments: [])
        var warnings: [String] = []
        if let diarizationTask {
            do {
                speakerTimeline = try await diarizationTask.value
                insert(
                    speakerTimeline,
                    into: &diarizationCache,
                    order: &diarizationCacheOrder,
                    key: diarizationKey
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Keep the Silero result, but surface the quality downgrade
                // instead of silently presenting it as full diarization.
                warnings.append("SpeakerKit 未能完成说话人分离，已降级为 Silero VAD 断句。")
            }
        }

        if request.enableSpeakerDiarization {
            stageChanged(.diarizing(1))
        }
        return (voiceSegments, speakerTimeline, warnings)
    }

    private func insert<Value>(
        _ value: Value,
        into cache: inout [String: Value],
        order: inout [String],
        key: String
    ) {
        cache[key] = value
        touch(key, in: &order)
        while cache.count > maxCacheEntries, !order.isEmpty {
            let oldestKey = order.removeFirst()
            cache.removeValue(forKey: oldestKey)
        }
    }

    private func touch(_ key: String, in order: inout [String]) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
    }

    public func clearCaches() {
        voiceCache.removeAll(keepingCapacity: false)
        diarizationCache.removeAll(keepingCapacity: false)
        transcriptionCache.removeAll(keepingCapacity: false)
        voiceCacheOrder.removeAll(keepingCapacity: false)
        diarizationCacheOrder.removeAll(keepingCapacity: false)
        transcriptionCacheOrder.removeAll(keepingCapacity: false)
    }

    private static func reusableWaveform(
        _ candidate: WaveformData?,
        duration: Double
    ) -> WaveformData? {
        guard let candidate,
              !candidate.isEmpty,
              duration.isFinite,
              duration > 0,
              abs(candidate.duration - duration) <= max(0.05, duration * 0.002) else {
            return nil
        }
        return candidate
    }

    private static func windowFingerprint(_ windows: [VoiceActivitySegment]) -> String {
        var hasher = Hasher()
        hasher.combine(windows.count)
        for window in windows {
            hasher.combine(Int((window.startTime * 10_000).rounded()))
            hasher.combine(Int((window.endTime * 10_000).rounded()))
            hasher.combine(Int((Double(window.confidence) * 1_000).rounded()))
        }
        return String(hasher.finalize(), radix: 16)
    }

    private static func mediaFingerprint(for url: URL) -> String {
        let standardized = url.standardizedFileURL
        let values = try? standardized.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? -1
        let modification = values?.contentModificationDate?.timeIntervalSince1970 ?? -1
        return "\(standardized.path)|\(size)|\(String(format: "%.6f", modification))"
    }
}

public enum SpeechSegmentationPipelineError: LocalizedError {
    case whisperModelMissing

    public var errorDescription: String? {
        switch self {
        case .whisperModelMissing:
            return "所选 Whisper 模型尚未下载。请先在设置中下载模型，或改用快速断句预设。"
        }
    }
}
