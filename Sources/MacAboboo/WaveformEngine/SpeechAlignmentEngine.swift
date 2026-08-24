import Foundation

/// 进程内 Whisper 词级时间轴兼容接口。
/// 新断句流程直接使用 `SpeechSegmentationPipeline`；此类型保留给既有调用方与导入工具。
public final class SpeechAlignmentEngine: @unchecked Sendable {
    public static let shared = SpeechAlignmentEngine()

    public struct WordTimestamp: Sendable {
        public let word: String
        public let startTime: Double
        public let endTime: Double
        public let confidence: Float

        public init(word: String, startTime: Double, endTime: Double, confidence: Float = 1) {
            self.word = word
            self.startTime = startTime
            self.endTime = endTime
            self.confidence = confidence
        }
    }

    public struct TranscribedSentence: Sendable {
        public let text: String
        public let startTime: Double
        public let endTime: Double
        public let words: [WordTimestamp]

        public init(text: String, startTime: Double, endTime: Double, words: [WordTimestamp] = []) {
            self.text = text
            self.startTime = startTime
            self.endTime = endTime
            self.words = words
        }
    }

    public init() {}

    public func transcribeAudio(
        from audioURL: URL,
        locale: Locale = Locale(identifier: "und"),
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [TranscribedSentence] {
        let modelInfo = await MainActor.run {
            let manager = WhisperModelManager.shared
            let level = manager.selectedModelLevel
            return (manager.modelFileURL(for: level), manager.isModelDownloaded(level))
        }
        let modelURL = modelInfo.0
        guard modelInfo.1 else {
            throw SpeechSegmentationPipelineError.whisperModelMissing
        }

        let pcm = try await AudioPCMExtractor.shared.extract(from: audioURL) { progress in
            progressHandler?(progress * 0.18)
        }
        try Task.checkCancellation()
        let languageCode = Self.languageCode(for: locale)
        let profile = SpeechSegmentationMode.intelligent.profile
        let timeline = try await NativeSpeechRuntime.shared.transcribe(
            pcm: pcm,
            modelURL: modelURL,
            language: languageCode,
            configuration: profile.vad
        ) { progress in
            progressHandler?(0.18 + progress * 0.78)
        }
        try Task.checkCancellation()

        let segments = SpeechBoundaryOptimizer.shared.optimize(
            mode: .intelligent,
            timeline: timeline,
            voiceSegments: timeline.voiceSegments,
            waveform: pcm.waveform(),
            duration: pcm.duration,
            includeRecognizedText: true
        )
        progressHandler?(1)
        return segments.map { segment in
            let matching = timeline.tokens.filter { token in
                token.endTime > segment.startTime && token.startTime < segment.endTime
            }
            let words = matching.map {
                WordTimestamp(
                    word: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    confidence: $0.confidence
                )
            }.filter { !$0.word.isEmpty }
            return TranscribedSentence(
                text: segment.text,
                startTime: words.first?.startTime ?? segment.startTime,
                endTime: words.last?.endTime ?? segment.endTime,
                words: words
            )
        }
    }

    private static func languageCode(for locale: Locale) -> String {
        guard let code = locale.language.languageCode?.identifier,
              code != "und",
              !code.isEmpty else {
            return "auto"
        }
        return code
    }
}
