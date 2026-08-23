import Foundation

#if SWIFT_PACKAGE
import CSpeechRuntime
#endif

private final class NativeProgressBox: @unchecked Sendable {
    let callback: @Sendable (Double) -> Void
    init(callback: @escaping @Sendable (Double) -> Void) { self.callback = callback }
}

private func nativeSpeechProgressCallback(_ progress: Double, _ userData: UnsafeMutableRawPointer?) {
    guard let userData else { return }
    Unmanaged<NativeProgressBox>.fromOpaque(userData).takeUnretainedValue().callback(progress)
}

private final class NativeCancellation: @unchecked Sendable {
    let pointer: OpaquePointer?

    init() {
        pointer = mab_cancellation_token_create()
    }

    func cancel() {
        mab_cancellation_token_cancel(pointer)
    }

    deinit {
        mab_cancellation_token_free(pointer)
    }
}

private struct WhisperGPUInferenceFailure: Error {}

/// C model handles are confined to their owning actor and are only borrowed
/// during a synchronous inference call. The wrapper makes that ownership
/// explicit to Swift's Sendable diagnostics without moving the handle across
/// actors in practice.
private struct NativeContextHandle: @unchecked Sendable {
    let pointer: OpaquePointer
}

/// 对 whisper.cpp C API 的串行、可取消封装。模型上下文按路径复用，避免每次断句重新加载。
public actor NativeSpeechRuntime {
    public static let shared = NativeSpeechRuntime()

    private var whisperContext: OpaquePointer?
    private var loadedWhisperModelPath: String?
    private var whisperBackend: SpeechInferenceBackend = .cpu
    private var whisperGPUUnavailable = false
    private var vadContext: OpaquePointer?

    public init() {}

    deinit {
        mab_whisper_free(whisperContext)
        mab_vad_free(vadContext)
    }

    /// Release model contexts under system memory pressure. They are loaded
    /// lazily with the same configuration on the next segmentation request.
    public func unloadModels() async {
        try? await SpeechInferenceResourceScheduler.shared.withExclusiveStage {
            await self.unloadModelsLocked()
        }
    }

    private func unloadModelsLocked() {
        mab_whisper_free(whisperContext)
        whisperContext = nil
        loadedWhisperModelPath = nil
        whisperBackend = .cpu
        whisperGPUUnavailable = false
        mab_vad_free(vadContext)
        vadContext = nil
    }

    public func detectVoiceActivity(
        pcm: AudioPCMData,
        configuration: VoiceActivityConfiguration
    ) async throws -> [VoiceActivitySegment] {
        guard pcm.sampleRate == AudioPCMData.requiredSampleRate, !pcm.isEmpty else {
            throw NativeSpeechRuntimeError.invalidPCM
        }
        let modelURL = try Self.sileroModelURL()
        let context = try loadVADContext(modelURL: modelURL)
        let contextHandle = NativeContextHandle(pointer: context)
        let cancellation = NativeCancellation()

        return try await SpeechInferenceResourceScheduler.shared.withExclusiveStage {
            try await withTaskCancellationHandler {
            try Task.checkCancellation()
            var outputPointer: UnsafeMutablePointer<MABVoiceActivitySegment>?
            var outputCount: Int32 = 0
            var errorBuffer = [CChar](repeating: 0, count: 512)
            let status = pcm.samples.withUnsafeBufferPointer { samples in
                mab_vad_detect(
                    contextHandle.pointer,
                    samples.baseAddress,
                    Int32(clamping: samples.count),
                    Self.nativeVADConfiguration(configuration),
                    cancellation.pointer,
                    &outputPointer,
                    &outputCount,
                    &errorBuffer,
                    errorBuffer.count
                )
            }
            defer { mab_voice_activity_segments_free(outputPointer) }
            if status == -2 || cancellation.isCancelled {
                throw CancellationError()
            }
            guard status == 0 else {
                throw NativeSpeechRuntimeError.inferenceFailed(Self.errorMessage(errorBuffer))
            }
            guard let outputPointer, outputCount > 0 else { return [] }
            return (0..<Int(outputCount)).map { index in
                let segment = outputPointer[index]
                return VoiceActivitySegment(
                    startTime: segment.start_time,
                    endTime: segment.end_time,
                    confidence: segment.confidence
                )
            }
            } onCancel: {
                cancellation.cancel()
            }
        }
    }

    public func transcribe(
        pcm: AudioPCMData,
        modelURL: URL,
        language: String,
        configuration: VoiceActivityConfiguration,
        useInternalVAD: Bool = true,
        speechWindows: [VoiceActivitySegment] = [],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> SpeechRecognitionTimeline {
        guard pcm.sampleRate == AudioPCMData.requiredSampleRate, !pcm.isEmpty else {
            throw NativeSpeechRuntimeError.invalidPCM
        }
        return try await SpeechInferenceResourceScheduler.shared.withExclusiveStage {
            do {
                return try await self.transcribeLocked(
                    pcm: pcm,
                    modelURL: modelURL,
                    language: language,
                    configuration: configuration,
                    useInternalVAD: useInternalVAD,
                    speechWindows: speechWindows,
                    progress: progress,
                    forceCPU: false
                )
            } catch is WhisperGPUInferenceFailure {
                // A context can be created successfully but still reject a
                // Metal kernel on a particular macOS/model combination. Mark
                // that backend unavailable and rerun the same windows on CPU
                // once, without changing any sentence-boundary inputs.
                await self.markWhisperGPUUnavailable()
                return try await self.transcribeLocked(
                    pcm: pcm,
                    modelURL: modelURL,
                    language: language,
                    configuration: configuration,
                    useInternalVAD: useInternalVAD,
                    speechWindows: speechWindows,
                    progress: progress,
                    forceCPU: true
                )
            }
        }
    }

    private func transcribeLocked(
        pcm: AudioPCMData,
        modelURL: URL,
        language: String,
        configuration: VoiceActivityConfiguration,
        useInternalVAD: Bool,
        speechWindows: [VoiceActivitySegment],
        progress: @escaping @Sendable (Double) -> Void,
        forceCPU: Bool
    ) async throws -> SpeechRecognitionTimeline {
        let context = try loadWhisperContext(modelURL: modelURL, forceCPU: forceCPU)
        let contextHandle = NativeContextHandle(pointer: context)
        let vadModelURL = useInternalVAD ? try Self.sileroModelURL() : nil
        let cancellation = NativeCancellation()

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            var whisperConfiguration = MABWhisperConfig()
            whisperConfiguration.thread_count = SpeechInferenceResourcePolicy.current().whisperThreadCount
            whisperConfiguration.beam_size = 5
            whisperConfiguration.no_speech_threshold = 0.60
            whisperConfiguration.suppress_non_speech_tokens = true
            whisperConfiguration.enable_tinydiarize = false
            whisperConfiguration.vad = Self.nativeVADConfiguration(configuration)

            // External Silero/SpeakerKit regions are used as Whisper's input
            // windows. This keeps noise and long silent stretches out of the
            // recognizer without allowing Whisper's own VAD windows to become
            // public sentence boundaries. A full-file pass remains available
            // for legacy callers that do not provide external windows.
            let ranges = useInternalVAD || speechWindows.isEmpty
                ? [SampleRange(start: 0, end: pcm.samples.count)]
                : Self.transcriptionRanges(
                    speechWindows,
                    duration: pcm.duration,
                    sampleCount: pcm.samples.count
                )
            guard !ranges.isEmpty else {
                return SpeechRecognitionTimeline(tokens: [], voiceSegments: [], detectedLanguage: "")
            }

            var allTokens: [SpeechToken] = []
            var externalVoiceSegments: [VoiceActivitySegment] = []
            var detectedLanguage = ""
            allTokens.reserveCapacity(ranges.count * 32)

            for (windowIndex, range) in ranges.enumerated() {
                try Task.checkCancellation()
                let progressStart = Double(windowIndex) / Double(ranges.count)
                let progressSpan = 1.0 / Double(ranges.count)
                let progressBox = NativeProgressBox { localProgress in
                    progress(progressStart + min(1, max(0, localProgress)) * progressSpan)
                }
                let progressOpaque = Unmanaged.passUnretained(progressBox).toOpaque()
                var result = MABTranscriptionResult()
                var errorBuffer = [CChar](repeating: 0, count: 512)
                // `pcm.samples` is one contiguous, validated Float32 buffer.
                // Pass a pointer into the requested window instead of copying
                // up to 24 seconds of audio for every Whisper call. The
                // pointer remains valid for the complete synchronous C call.
                let status = pcm.samples.withUnsafeBufferPointer { sampleBuffer in
                    guard let baseAddress = sampleBuffer.baseAddress,
                          range.start >= 0,
                          range.end <= sampleBuffer.count,
                          range.end > range.start else {
                        return Int32(-1)
                    }
                    let windowPointer = baseAddress.advanced(by: range.start)
                    let windowCount = Int32(clamping: range.end - range.start)
                    return language.withCString { languageCode in
                        let transcribe: (UnsafePointer<CChar>?) -> Int32 = { vadPath in
                            mab_whisper_transcribe(
                                contextHandle.pointer,
                                vadPath,
                                windowPointer,
                                windowCount,
                                languageCode,
                                whisperConfiguration,
                                cancellation.pointer,
                                nativeSpeechProgressCallback,
                                progressOpaque,
                                &result,
                                &errorBuffer,
                                errorBuffer.count
                            )
                        }
                        guard useInternalVAD, let vadModelURL else {
                            return transcribe(nil)
                        }
                        return vadModelURL.path.withCString { vadPath in
                            transcribe(vadPath)
                        }
                    }
                }
                defer { mab_transcription_result_free(&result) }
                if status == -2 || cancellation.isCancelled {
                    throw CancellationError()
                }
                guard status == 0 else {
                    if !forceCPU, whisperBackend == .metal {
                        mab_whisper_free(whisperContext)
                        whisperContext = nil
                        whisperBackend = .cpu
                        throw WhisperGPUInferenceFailure()
                    }
                    throw NativeSpeechRuntimeError.inferenceFailed(Self.errorMessage(errorBuffer))
                }

                let timeOffset = Double(range.start) / Double(pcm.sampleRate)
                if let pointer = result.tokens, result.token_count > 0 {
                    for index in 0..<Int(result.token_count) {
                        let token = pointer[index]
                        let text = token.text.map { String(cString: $0) } ?? ""
                        guard !text.isEmpty else { continue }
                        allTokens.append(SpeechToken(
                            text: text,
                            startTime: token.start_time + timeOffset,
                            endTime: token.end_time + timeOffset,
                            confidence: token.confidence,
                            recognitionSegmentIndex: windowIndex * 1_000_000 + Int(token.segment_index),
                            speakerTurnAfter: token.speaker_turn_after
                        ))
                    }
                }
                if let pointer = result.voice_segments, result.voice_segment_count > 0 {
                    for index in 0..<Int(result.voice_segment_count) {
                        let segment = pointer[index]
                        externalVoiceSegments.append(VoiceActivitySegment(
                            startTime: segment.start_time + timeOffset,
                            endTime: segment.end_time + timeOffset,
                            confidence: segment.confidence
                        ))
                    }
                }
                if detectedLanguage.isEmpty, let languagePointer = result.detected_language {
                    detectedLanguage = String(cString: languagePointer)
                }
                withExtendedLifetime(progressBox) {}
            }

            let tokens = Self.deduplicateWindowTokens(allTokens)
            let voiceSegments = useInternalVAD
                ? externalVoiceSegments
                : speechWindows
            return SpeechRecognitionTimeline(
                tokens: tokens,
                voiceSegments: voiceSegments,
                detectedLanguage: detectedLanguage
            )
            } onCancel: {
                cancellation.cancel()
            }
    }

    private struct SampleRange: Sendable {
        var start: Int
        var end: Int
    }

    private static func transcriptionRanges(
        _ input: [VoiceActivitySegment],
        duration: Double,
        sampleCount: Int
    ) -> [SampleRange] {
        guard duration > 0, sampleCount > 0 else { return [] }
        let normalized = input.compactMap { segment -> (start: Double, end: Double)? in
            let start = min(duration, max(0, segment.startTime))
            let end = min(duration, max(start, segment.endTime))
            guard end - start >= 0.04 else { return nil }
            return (start, end)
        }.sorted { $0.start < $1.start }
        guard !normalized.isEmpty else { return [] }

        // Merge nearby speech islands first so Whisper sees enough context for
        // connected words, but cap each inference window to keep timestamps
        // stable and memory bounded on long recordings.
        let mergeGap = 0.65
        let context = 0.35
        let maximumWindow = 24.0
        var merged: [(start: Double, end: Double)] = []
        for interval in normalized {
            guard let last = merged.last else {
                merged.append(interval)
                continue
            }
            if interval.start - last.end <= mergeGap,
               interval.end - last.start <= maximumWindow {
                merged[merged.count - 1].end = interval.end
            } else {
                merged.append(interval)
            }
        }

        var ranges: [SampleRange] = []
        for interval in merged {
            let expandedStart = max(0, interval.start - context)
            let expandedEnd = min(duration, interval.end + context)
            var cursor = expandedStart
            while cursor < expandedEnd - 0.01 {
                let end = min(expandedEnd, cursor + maximumWindow)
                let startIndex = min(sampleCount - 1, max(0, Int((cursor * Double(AudioPCMData.requiredSampleRate)).rounded(.down))))
                let endIndex = min(sampleCount, max(startIndex + 1, Int((end * Double(AudioPCMData.requiredSampleRate)).rounded(.up))))
                ranges.append(SampleRange(start: startIndex, end: endIndex))
                if end >= expandedEnd { break }
                // Keep a small overlap so a word crossing a window edge is
                // present in both windows and can be deduplicated afterwards.
                cursor = end - 0.50
            }
        }
        return ranges
    }

    private static func deduplicateWindowTokens(_ input: [SpeechToken]) -> [SpeechToken] {
        let sorted = input.sorted {
            if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
            return $0.startTime < $1.startTime
        }
        var output: [SpeechToken] = []
        output.reserveCapacity(sorted.count)
        for token in sorted {
            if let lastIndex = output.indices.last {
                let last = output[lastIndex]
                let lhs = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let rhs = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let overlap = max(0, min(last.endTime, token.endTime) - max(last.startTime, token.startTime))
                let shorter = max(0.01, min(last.endTime - last.startTime, token.endTime - token.startTime))
                if !lhs.isEmpty, lhs.caseInsensitiveCompare(rhs) == .orderedSame,
                   overlap / shorter >= 0.45 {
                    if token.confidence > last.confidence { output[lastIndex] = token }
                    continue
                }
            }
            output.append(token)
        }
        return output
    }

    private func loadWhisperContext(
        modelURL: URL,
        forceCPU: Bool = false
    ) throws -> OpaquePointer {
        let modelPath = modelURL.standardizedFileURL.path
        let policy = SpeechInferenceResourcePolicy.current()
        if loadedWhisperModelPath != modelPath {
            mab_whisper_free(whisperContext)
            whisperContext = nil
            loadedWhisperModelPath = nil
            whisperBackend = .cpu
            whisperGPUUnavailable = false
        }
        if (forceCPU || !policy.preferWhisperMetal), whisperBackend == .metal {
            mab_whisper_free(whisperContext)
            whisperContext = nil
            whisperBackend = .cpu
        }
        if let whisperContext { return whisperContext }

        let shouldTryMetal = !forceCPU && policy.preferWhisperMetal && !whisperGPUUnavailable
        let attempts = shouldTryMetal ? [true, false] : [false]
        var lastError = "未知的本地语音模型加载错误"

        for useGPU in attempts {
            var errorBuffer = [CChar](repeating: 0, count: 512)
            let context = modelPath.withCString { path in
                mab_whisper_create(path, useGPU, &errorBuffer, errorBuffer.count)
            }
            if let context {
                whisperContext = context
                loadedWhisperModelPath = modelPath
                whisperBackend = useGPU ? .metal : .cpu
                return context
            }
            lastError = Self.errorMessage(errorBuffer)
            if useGPU {
                // Persist the failed backend choice for this model lifetime so
                // every subsequent sentence does not pay another failed Metal
                // initialization cost.
                whisperGPUUnavailable = true
            }
        }
        throw NativeSpeechRuntimeError.modelLoadFailed(lastError)
    }

    private func markWhisperGPUUnavailable() {
        whisperGPUUnavailable = true
    }

    private func loadVADContext(modelURL: URL) throws -> OpaquePointer {
        if let vadContext { return vadContext }
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let threadCount = SpeechInferenceResourcePolicy.current().vadThreadCount
        let context = modelURL.path.withCString { path in
            // Silero 只有约 1 MB，CPU 推理更快也更稳定；Metal 留给 Whisper 主模型。
            mab_vad_create(path, false, threadCount, &errorBuffer, errorBuffer.count)
        }
        guard let context else {
            throw NativeSpeechRuntimeError.modelLoadFailed(Self.errorMessage(errorBuffer))
        }
        vadContext = context
        return context
    }

    private static func nativeVADConfiguration(_ configuration: VoiceActivityConfiguration) -> MABVADConfig {
        var result = MABVADConfig()
        result.threshold = configuration.threshold
        result.min_speech_duration_ms = Int32(clamping: Int((configuration.minSpeechDuration * 1_000).rounded()))
        result.min_silence_duration_ms = Int32(clamping: Int((configuration.minSilenceDuration * 1_000).rounded()))
        result.max_speech_duration_s = Float(configuration.maxSpeechDuration)
        result.speech_pad_ms = Int32(clamping: Int((configuration.speechPadding * 1_000).rounded()))
        result.samples_overlap_s = Float(configuration.sampleOverlap)
        return result
    }

    private static func sileroModelURL() throws -> URL {
        let filename = "ggml-silero-v6.2.0"
        if let url = MacAbobooResourceBundle.bundle?.url(forResource: filename, withExtension: "bin", subdirectory: "Models")
            ?? MacAbobooResourceBundle.bundle?.url(forResource: filename, withExtension: "bin") {
            return url
        }
        let candidates = [
            Bundle.main.url(forResource: filename, withExtension: "bin", subdirectory: "Models"),
            Bundle.main.url(forResource: filename, withExtension: "bin"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/MacAboboo/Resources/Models/ggml-silero-v6.2.0.bin")
        ].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw NativeSpeechRuntimeError.vadModelMissing
        }
        return url
    }

    private static func errorMessage(_ buffer: [CChar]) -> String {
        buffer.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress, baseAddress.pointee != 0 else {
                return "未知的本地语音推理错误"
            }
            return String(cString: baseAddress)
        }
    }
}

private extension NativeCancellation {
    var isCancelled: Bool { mab_cancellation_token_is_cancelled(pointer) }
}

public enum NativeSpeechRuntimeError: LocalizedError {
    case invalidPCM
    case vadModelMissing
    case modelLoadFailed(String)
    case inferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPCM: return "断句运行时只接受 16 kHz 单声道音频。"
        case .vadModelMissing: return "应用内置的 Silero VAD 模型缺失。"
        case .modelLoadFailed(let message): return "本地语音模型加载失败：\(message)"
        case .inferenceFailed(let message): return "本地语音识别失败：\(message)"
        }
    }
}
