import Foundation
import Combine
#if canImport(StudyMatePackage)
import StudyMatePackage
#endif

/// 句库词级时间戳对齐目标
public struct SentenceLibraryAlignmentTarget: Sendable {
    public let segmentID: UUID
    public let entryID: UUID
    public let startTime: Double
    public let endTime: Double
    public let originalText: String

    public init(
        segmentID: UUID,
        entryID: UUID,
        startTime: Double,
        endTime: Double,
        originalText: String
    ) {
        self.segmentID = segmentID
        self.entryID = entryID
        self.startTime = startTime
        self.endTime = endTime
        self.originalText = originalText
    }
}

/// 句库后台词级时间戳静默对齐服务。
/// 当从外部 SRT/LRC 导入的材料加入句库，或者进入无时间戳的句库学习时，
/// 在后台异步调用 Whisper 生成逐词时间戳，不阻塞主线程与音频播放，
/// 并在状态栏右侧呈现进度与完成提示。
@MainActor
public final class SentenceLibraryAlignmentService: ObservableObject {
    public static let shared = SentenceLibraryAlignmentService()

    @Published public private(set) var isAligning: Bool = false
    private var activeTask: Task<Void, Never>?
    private var activeTaskID = UUID()

    private init() {}

    /// 取消正在执行的对齐任务
    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
        isAligning = false
    }

    /// 基于复合/完整音频流（如原片媒体或句库合并会话音频）快速对齐多个句子的词级时间戳
    public func alignWordTokens(
        targets: [SentenceLibraryAlignmentTarget],
        audioURL: URL,
        libraryID: UUID,
        languageOverride: String? = nil
    ) {
        guard !targets.isEmpty else { return }

        let modelManager = WhisperModelManager.shared
        let modelLevel = modelManager.selectedModelLevel
        guard modelManager.isModelDownloaded(modelLevel) else {
            let isChinese = LanguageManager.shared.currentLanguage == .zh
            MainStatusCenter.shared.showInfo(
                isChinese
                    ? "Whisper 模型未下载，暂未自动补齐句库词级时间戳"
                    : "Whisper model not downloaded; skipping automatic word timestamp alignment"
            )
            return
        }

        let modelURL = modelManager.modelFileURL(for: modelLevel)
        let recognitionLanguage = languageOverride ?? PlaybackEngine.shared.effectiveSpeechRecognitionLanguage

        let isChinese = LanguageManager.shared.currentLanguage == .zh
        let preparingPhase = isChinese ? "正在准备句库词级时间戳对齐…" : "Preparing sentence library word timestamp alignment…"
        let aligningPhase = isChinese ? "Whisper 正在对齐词级时间戳…" : "Whisper is aligning word timestamps…"

        let taskID = UUID()
        self.activeTaskID = taskID
        self.isAligning = true

        let statusCenter = MainStatusCenter.shared
        let generation = statusCenter.begin(
            MainStatusProgress(
                fraction: 0.02,
                phase: preparingPhase,
                currentItem: "0/\(targets.count)"
            )
        )

        activeTask?.cancel()
        activeTask = Task.detached(priority: .utility) {
            defer {
                Task { @MainActor in
                    guard SentenceLibraryAlignmentService.shared.activeTaskID == taskID else { return }
                    SentenceLibraryAlignmentService.shared.isAligning = false
                    statusCenter.finish(generation: generation)
                }
            }

            do {
                // 1. 提取 PCM 数据
                let pcm = try await AudioPCMExtractor.shared.extract(from: audioURL) { progress in
                    Task { @MainActor in
                        guard SentenceLibraryAlignmentService.shared.activeTaskID == taskID else { return }
                        statusCenter.update(
                            MainStatusProgress(
                                fraction: min(0.15, max(0, progress) * 0.15),
                                phase: preparingPhase,
                                currentItem: "0/\(targets.count)"
                            ),
                            generation: generation
                        )
                    }
                }
                try Task.checkCancellation()

                // 2. 构造识别窗口
                let dummySegments = targets.map {
                    SentenceSegment(
                        id: $0.segmentID,
                        index: 0,
                        startTime: $0.startTime,
                        endTime: $0.endTime,
                        text: $0.originalText
                    )
                }
                let speechWindows = dummySegments.map {
                    VoiceActivitySegment(startTime: $0.startTime, endTime: $0.endTime, confidence: 1)
                }
                let hardBoundaries = Array(Set(dummySegments.flatMap { [$0.startTime, $0.endTime] })).sorted()

                // 3. 执行识别并提取词级 token
                let timeline = try await NativeSpeechRuntime.shared.transcribe(
                    pcm: pcm,
                    modelURL: modelURL,
                    language: recognitionLanguage,
                    configuration: SpeechSegmentationMode.intelligent.profile.vad,
                    speechWindows: speechWindows,
                    hardWindowBoundaries: hardBoundaries,
                    isolatedSpeechWindows: true
                ) { transcribeProgress in
                    Task { @MainActor in
                        guard SentenceLibraryAlignmentService.shared.activeTaskID == taskID else { return }
                        let f = 0.15 + min(1, max(0, transcribeProgress)) * 0.80
                        statusCenter.update(
                            MainStatusProgress(
                                fraction: f,
                                phase: aligningPhase,
                                currentItem: ""
                            ),
                            generation: generation
                        )
                    }
                }
                try Task.checkCancellation()

                let (_, recognizedTokens) = PlaybackEngine.recognizedOriginalTextsAndTokens(
                    for: dummySegments,
                    tokens: timeline.tokens
                )

                // 4. 持久化到 SQLite 数据库与 content.json
                var count = 0
                for target in targets {
                    if let tokens = recognizedTokens[target.segmentID], !tokens.isEmpty {
                        try? SentenceLibraryStore.shared.updateWordTokensAndText(
                            id: target.entryID,
                            originalText: target.originalText,
                            wordTokens: tokens,
                            in: libraryID
                        )
                        count += 1
                    }
                }
                let finalUpdatedCount = count

                // 5. 若当前会话正在学习此句库，同步更新内存中的 segments
                await MainActor.run {
                    guard SentenceLibraryAlignmentService.shared.activeTaskID == taskID else { return }
                    if PlaybackEngine.shared.activeSentenceLibraryID == libraryID {
                        var currentSegments = PlaybackEngine.shared.segments
                        var didModify = false
                        for (segID, tokens) in recognizedTokens where !tokens.isEmpty {
                            if let idx = currentSegments.firstIndex(where: { $0.id == segID }) {
                                currentSegments[idx].wordTokens = tokens
                                didModify = true
                            }
                        }
                        if didModify {
                            PlaybackEngine.shared.segments = currentSegments
                            PlaybackEngine.shared.persistCurrentProject()
                        }
                    }

                    if finalUpdatedCount > 0 {
                        statusCenter.showSuccess(
                            isChinese
                                ? "已自动对齐 \(finalUpdatedCount) 句的词级时间戳并存入句库"
                                : "Automatically aligned word timestamps for \(finalUpdatedCount) sentence(s)"
                        )
                    }
                }
            } catch is CancellationError {
                // 任务已取消
            } catch {
                await MainActor.run {
                    guard SentenceLibraryAlignmentService.shared.activeTaskID == taskID else { return }
                    statusCenter.showError(
                        isChinese
                            ? "句库词级时间戳对齐失败：\(error.localizedDescription)"
                            : "Sentence library word timestamp alignment failed: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    /// 基于句库内部独立的单句切片音频（.m4a）逐条补齐词级时间戳（在原片媒体缺失时的强健回退）
    public func alignWordTokensForEntries(
        entries: [SentenceLibraryEntry],
        libraryID: UUID,
        languageOverride: String? = nil
    ) {
        let targets = entries.filter { $0.wordTokens == nil || $0.wordTokens?.isEmpty == true }
        guard !targets.isEmpty else { return }

        let modelManager = WhisperModelManager.shared
        let modelLevel = modelManager.selectedModelLevel
        guard modelManager.isModelDownloaded(modelLevel) else {
            let isChinese = LanguageManager.shared.currentLanguage == .zh
            MainStatusCenter.shared.showInfo(
                isChinese
                    ? "Whisper 模型未下载，暂未自动补齐句库词级时间戳"
                    : "Whisper model not downloaded; skipping automatic word timestamp alignment"
            )
            return
        }

        let modelURL = modelManager.modelFileURL(for: modelLevel)
        let recognitionLanguage = languageOverride ?? PlaybackEngine.shared.effectiveSpeechRecognitionLanguage

        let isChinese = LanguageManager.shared.currentLanguage == .zh
        let aligningPhase = isChinese ? "Whisper 正在对齐句库词级时间戳…" : "Whisper is aligning word timestamps…"

        let taskID = UUID()
        self.activeTaskID = taskID
        self.isAligning = true

        let statusCenter = MainStatusCenter.shared
        let generation = statusCenter.begin(
            MainStatusProgress(
                fraction: 0.02,
                phase: aligningPhase,
                currentItem: "0/\(targets.count)"
            )
        )

        activeTask?.cancel()
        activeTask = Task.detached(priority: .utility) {
            defer {
                Task { @MainActor in
                    guard SentenceLibraryAlignmentService.shared.activeTaskID == taskID else { return }
                    SentenceLibraryAlignmentService.shared.isAligning = false
                    statusCenter.finish(generation: generation)
                }
            }

            var count = 0
            let total = targets.count

            for (index, entry) in targets.enumerated() {
                if Task.isCancelled { break }
                guard let clipURL = SentenceLibraryStore.shared.mediaURL(for: entry, libraryID: libraryID),
                      FileManager.default.fileExists(atPath: clipURL.path) else {
                    continue
                }

                do {
                    let pcm = try await AudioPCMExtractor.shared.extract(from: clipURL)
                    if Task.isCancelled { break }

                    let timeline = try await NativeSpeechRuntime.shared.transcribe(
                        pcm: pcm,
                        modelURL: modelURL,
                        language: recognitionLanguage,
                        configuration: SpeechSegmentationMode.intelligent.profile.vad,
                        speechWindows: [],
                        hardWindowBoundaries: [],
                        isolatedSpeechWindows: false
                    ) { _ in }
                    if Task.isCancelled { break }

                    let wordTokens = SpeechBoundaryOptimizer.shared.wordTokens(
                        from: timeline.tokens,
                        sentenceStartTime: 0
                    )

                    if !wordTokens.isEmpty {
                        try? SentenceLibraryStore.shared.updateWordTokensAndText(
                            id: entry.id,
                            originalText: entry.originalText,
                            wordTokens: wordTokens,
                            in: libraryID
                        )
                        count += 1
                    }

                    let fraction = Double(index + 1) / Double(total)
                    let currentItemLabel = "\(index + 1)/\(total)"
                    await MainActor.run {
                        guard SentenceLibraryAlignmentService.shared.activeTaskID == taskID else { return }
                        statusCenter.update(
                            MainStatusProgress(
                                fraction: fraction,
                                phase: aligningPhase,
                                currentItem: currentItemLabel
                            ),
                            generation: generation
                        )
                    }
                } catch {
                    continue
                }
            }

            let finalCount = count
            await MainActor.run {
                guard SentenceLibraryAlignmentService.shared.activeTaskID == taskID else { return }
                if finalCount > 0 {
                    statusCenter.showSuccess(
                        isChinese
                            ? "已自动对齐 \(finalCount) 句的词级时间戳并存入句库"
                            : "Automatically aligned word timestamps for \(finalCount) sentence(s)"
                    )
                }
            }
        }
    }
}
