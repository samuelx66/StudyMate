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
        try await detectVoiceActivityAnalysis(
            pcm: pcm,
            configuration: configuration
        ).segments
    }

    public func detectVoiceActivityAnalysis(
        pcm: AudioPCMData,
        configuration: VoiceActivityConfiguration
    ) async throws -> VoiceActivityAnalysis {
        guard pcm.sampleRate == AudioPCMData.requiredSampleRate, !pcm.isEmpty else {
            throw NativeSpeechRuntimeError.invalidPCM
        }
        let cancellation = NativeCancellation()

        return try await SpeechInferenceResourceScheduler.shared.withExclusiveStage {
            try await withTaskCancellationHandler {
                try await self.detectVoiceActivityLocked(
                    pcm: pcm,
                    configuration: configuration,
                    cancellation: cancellation
                )
            } onCancel: {
                cancellation.cancel()
            }
        }
    }

    private func detectVoiceActivityLocked(
        pcm: AudioPCMData,
        configuration: VoiceActivityConfiguration,
        cancellation: NativeCancellation
    ) throws -> VoiceActivityAnalysis {
        try Task.checkCancellation()
        let modelURL = try Self.sileroModelURL()
        let context = try loadVADContext(modelURL: modelURL)
        let contextHandle = NativeContextHandle(pointer: context)
        var outputPointer: UnsafeMutablePointer<MABVoiceActivitySegment>?
        var outputCount: Int32 = 0
        var probabilityPointer: UnsafeMutablePointer<Float>?
        var probabilityCount: Int32 = 0
        var probabilityFrameDuration: Double = 0
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
                &probabilityPointer,
                &probabilityCount,
                &probabilityFrameDuration,
                &errorBuffer,
                errorBuffer.count
            )
        }
        defer { mab_voice_activity_segments_free(outputPointer) }
        defer { mab_vad_probabilities_free(probabilityPointer) }
        if status == -2 || cancellation.isCancelled {
            throw CancellationError()
        }
        guard status == 0 else {
            throw NativeSpeechRuntimeError.inferenceFailed(Self.errorMessage(errorBuffer))
        }
        let segments: [VoiceActivitySegment]
        if let outputPointer, outputCount > 0 {
            segments = (0..<Int(outputCount)).map { index in
                let segment = outputPointer[index]
                return VoiceActivitySegment(
                    startTime: segment.start_time,
                    endTime: segment.end_time,
                    confidence: segment.confidence
                )
            }
        } else {
            segments = []
        }
        let probabilities: [VADProbabilityFrame]
        if let probabilityPointer, probabilityCount > 0, probabilityFrameDuration > 0 {
            probabilities = (0..<Int(probabilityCount)).map { index in
                VADProbabilityFrame(
                    time: (Double(index) + 0.5) * probabilityFrameDuration,
                    probability: probabilityPointer[index]
                )
            }
        } else {
            probabilities = []
        }
        return VoiceActivityAnalysis(
            segments: segments,
            probabilities: probabilities,
            frameDuration: probabilityFrameDuration
        )
    }

    public func transcribe(
        pcm: AudioPCMData,
        modelURL: URL,
        language: String,
        configuration: VoiceActivityConfiguration,
        useInternalVAD: Bool = true,
        speechWindows: [VoiceActivitySegment] = [],
        hardWindowBoundaries: [Double] = [],
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
                    hardWindowBoundaries: hardWindowBoundaries,
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
                    hardWindowBoundaries: hardWindowBoundaries,
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
        hardWindowBoundaries: [Double],
        progress: @escaping @Sendable (Double) -> Void,
        forceCPU: Bool
    ) async throws -> SpeechRecognitionTimeline {
        let context = try loadWhisperContext(modelURL: modelURL, forceCPU: forceCPU)
        let contextHandle = NativeContextHandle(pointer: context)
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

            // Stable whisper.cpp v1.9.1 does not expose the development
            // build's original-timeline mapping for internal VAD token times.
            // Run the same bundled Silero model first and transcribe its
            // external windows so all returned timestamps stay on the source
            // media timeline.
            let internalVoiceAnalysis = useInternalVAD
                ? try self.detectVoiceActivityLocked(
                    pcm: pcm,
                    configuration: configuration,
                    cancellation: cancellation
                )
                : VoiceActivityAnalysis(segments: [], probabilities: [], frameDuration: 0)
            let effectiveSpeechWindows = useInternalVAD ? internalVoiceAnalysis.segments : speechWindows

            // External Silero/SpeakerKit regions are used as Whisper's input
            // windows. This keeps noise and long silent stretches out of the
            // recognizer without allowing Whisper's own VAD windows to become
            // public sentence boundaries. A full-file pass remains available
            // for legacy callers that do not provide external windows.
            let ranges = effectiveSpeechWindows.isEmpty
                ? []
                : Self.transcriptionRanges(
                    effectiveSpeechWindows,
                    duration: pcm.duration,
                    sampleCount: pcm.samples.count,
                    hardBoundaries: hardWindowBoundaries
                )
            guard !ranges.isEmpty else {
                return SpeechRecognitionTimeline(tokens: [], voiceSegments: [], detectedLanguage: "")
            }

            var allTokens: [SpeechToken] = []
            var detectedLanguage = ""
            var effectiveLanguage = language
            allTokens.reserveCapacity(ranges.count * 32)

            for (windowIndex, range) in ranges.enumerated() {
                try Task.checkCancellation()
                whisperConfiguration.reset_context = Self.shouldResetWhisperContext(
                    windowIndex: windowIndex,
                    range: range,
                    previousRange: windowIndex > 0 ? ranges[windowIndex - 1] : nil,
                    hardBoundaries: hardWindowBoundaries,
                    sampleRate: pcm.sampleRate
                )
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
                    return effectiveLanguage.withCString { languageCode in
                        mab_whisper_transcribe(
                                contextHandle.pointer,
                                nil,
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
                if detectedLanguage.isEmpty, let languagePointer = result.detected_language {
                    detectedLanguage = String(cString: languagePointer)
                }
                if Self.isAutomaticLanguage(language),
                   Self.isAutomaticLanguage(effectiveLanguage),
                   let languagePointer = result.detected_language {
                    let candidate = String(cString: languagePointer)
                    let tokenCount = Int(result.token_count)
                    let windowDuration = Double(range.end - range.start) / Double(pcm.sampleRate)
                    let averageConfidence: Float = {
                        guard let pointer = result.tokens, tokenCount > 0 else { return 0 }
                        let sum = (0..<tokenCount).reduce(Float.zero) { $0 + pointer[$1].confidence }
                        return sum / Float(tokenCount)
                    }()
                    // Do not lock a language based on a tiny/noisy opening
                    // fragment. Once a representative window is available,
                    // reuse its language for the rest of this media request.
                    if !candidate.isEmpty,
                       candidate != "auto",
                       tokenCount >= 4,
                       windowDuration >= 2.0,
                       averageConfidence >= 0.45 {
                        effectiveLanguage = candidate
                    }
                }
                withExtendedLifetime(progressBox) {}
            }

            let tokens = Self.deduplicateWindowTokens(allTokens)
            let voiceSegments = useInternalVAD ? internalVoiceAnalysis.segments : speechWindows
            return SpeechRecognitionTimeline(
                tokens: tokens,
                voiceSegments: voiceSegments,
                detectedLanguage: detectedLanguage
            )
            } onCancel: {
                cancellation.cancel()
            }
    }

    private static func isAutomaticLanguage(_ language: String) -> Bool {
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "auto"
    }

    struct SampleRange: Sendable {
        var start: Int
        var end: Int
    }

    static func shouldResetWhisperContext(
        windowIndex: Int,
        range: SampleRange,
        previousRange: SampleRange?,
        hardBoundaries: [Double],
        sampleRate: Int = AudioPCMData.requiredSampleRate
    ) -> Bool {
        guard windowIndex > 0, let previousRange, sampleRate > 0 else { return true }
        let currentStart = Double(range.start) / Double(sampleRate)
        let currentEnd = Double(range.end) / Double(sampleRate)
        let previousEnd = Double(previousRange.end) / Double(sampleRate)
        // Each speech island carries up to 350 ms context on both sides, so a
        // remaining 800 ms range gap represents at least 1.5 s of real silence.
        if currentStart - previousEnd >= 0.8 { return true }

        // Reliable SpeakerKit turns are expanded by only 80 ms on each side.
        // Reset the rolling text prompt at that turn while preserving normal
        // context across overlapping technical chunks of the same speaker.
        return hardBoundaries.contains { boundary in
            boundary >= currentStart - 0.12
                && boundary <= min(currentEnd, currentStart + 0.24)
        }
    }

    static func transcriptionRanges(
        _ input: [VoiceActivitySegment],
        duration: Double,
        sampleCount: Int,
        hardBoundaries: [Double] = []
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
        let mergeGap = 0.20
        let context = 0.35
        let maximumWindow = 24.0
        var merged: [(start: Double, end: Double)] = []
        for interval in normalized {
            guard let last = merged.last else {
                merged.append(interval)
                continue
            }
            let crossesHardBoundary = hardBoundaries.contains {
                $0 >= last.end - 0.015 && $0 <= interval.start + 0.015
            }
            if !crossesHardBoundary,
               interval.start - last.end <= mergeGap,
               interval.end - last.start <= maximumWindow {
                merged[merged.count - 1].end = interval.end
            } else {
                merged.append(interval)
            }
        }

        var ranges: [SampleRange] = []
        for interval in merged {
            var expandedStart = max(0, interval.start - context)
            var expandedEnd = min(duration, interval.end + context)
            // Keep a small amount of phonetic context across a reliable turn,
            // but never let expansion recreate one large multi-speaker window.
            if let previousBoundary = hardBoundaries.last(where: { $0 <= interval.start + 0.015 }) {
                expandedStart = max(expandedStart, previousBoundary - 0.08)
            }
            if let nextBoundary = hardBoundaries.first(where: { $0 >= interval.end - 0.015 }) {
                expandedEnd = min(expandedEnd, nextBoundary + 0.08)
            }
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

    static func deduplicateWindowTokens(_ input: [SpeechToken]) -> [SpeechToken] {
        let windows = Dictionary(grouping: input) { token in
            max(0, token.recognitionSegmentIndex / 1_000_000)
        }
        var output: [SpeechToken] = []
        output.reserveCapacity(input.count)

        for windowIndex in windows.keys.sorted() {
            let current = (windows[windowIndex] ?? []).sorted {
                if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
                return $0.startTime < $1.startTime
            }
            guard !current.isEmpty else { continue }
            let duplicatePrefix = matchingOverlapPrefix(previous: output, current: current)
            output.append(contentsOf: current.dropFirst(duplicatePrefix))
        }

        // A single inference window has no cross-window duplication. Sorting
        // here also keeps the fallback path deterministic when two windows
        // disagree and both alternatives must be retained for the optimizer.
        return output.sorted {
            if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
            return $0.startTime < $1.startTime
        }
    }

    private static func matchingOverlapPrefix(
        previous: [SpeechToken],
        current: [SpeechToken]
    ) -> Int {
        guard !previous.isEmpty, !current.isEmpty else { return 0 }
        let previousLimit = min(12, previous.count)
        let currentLimit = min(12, current.count)
        var bestPrefixCount = 0
        var bestCharacterCount = 0

        for previousCount in 1...previousLimit {
            let previousStart = previous.count - previousCount
            let previousSlice = previous[previousStart..<previous.count]
            guard let previousFirst = previousSlice.first,
                  let previousLast = previousSlice.last else { continue }
            let previousText = normalizedOverlapText(previousSlice.map(\.text))
            guard !previousText.isEmpty else { continue }

            for currentCount in 1...currentLimit {
                let currentSlice = current[0..<currentCount]
                guard let currentFirst = currentSlice.first,
                      let currentLast = currentSlice.last else { continue }
                let currentText = normalizedOverlapText(currentSlice.map(\.text))
                guard previousText == currentText else { continue }

                // Duplicate windows describe the same source-time span even
                // when punctuation or token boundaries differ. Repeated words
                // spoken consecutively have distinct time spans and therefore
                // are deliberately retained.
                let startDelta = abs(previousFirst.startTime - currentFirst.startTime)
                let endDelta = abs(previousLast.endTime - currentLast.endTime)
                guard startDelta <= 0.30, endDelta <= 0.35 else { continue }
                let characterCount = previousText.unicodeScalars.count
                if characterCount > bestCharacterCount
                    || (characterCount == bestCharacterCount && currentCount > bestPrefixCount) {
                    bestCharacterCount = characterCount
                    bestPrefixCount = currentCount
                }
            }
        }
        return bestPrefixCount
    }

    private static func normalizedOverlapText(_ parts: [String]) -> String {
        parts.joined().lowercased().unicodeScalars.reduce(into: "") { result, scalar in
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
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
