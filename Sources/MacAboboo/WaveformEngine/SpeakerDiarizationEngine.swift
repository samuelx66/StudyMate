import Foundation
import CoreML
import SpeakerKit

/// 一段由 SpeakerKit 标注的说话人活动区间。
/// `speakerIDs` 允许多个 ID，表示该时间段存在重叠说话。
public struct SpeakerDiarizationSegment: Equatable, Sendable {
    public var startTime: Double
    public var endTime: Double
    public var speakerIDs: [Int]
    public var confidence: Float
    /// SpeakerKit currently exposes timestamps and labels but no calibrated
    /// per-segment posterior. Keep that distinction explicit so an unknown
    /// confidence is not mistaken for a failed or unreliable segment.
    public var hasCalibratedConfidence: Bool
    public var isOverlap: Bool

    public init(
        startTime: Double,
        endTime: Double,
        speakerIDs: [Int],
        confidence: Float = 1,
        hasCalibratedConfidence: Bool = true,
        isOverlap: Bool = false
    ) {
        self.startTime = max(0, startTime)
        self.endTime = max(self.startTime, endTime)
        self.speakerIDs = Array(Set(speakerIDs)).sorted()
        self.confidence = min(1, max(0, confidence))
        self.hasCalibratedConfidence = hasCalibratedConfidence
        self.isOverlap = isOverlap || self.speakerIDs.count > 1
    }

    public var duration: Double { max(0, endTime - startTime) }

    public var primarySpeakerID: Int? {
        speakerIDs.count == 1 ? speakerIDs[0] : nil
    }
}

/// 一次完整的说话人日志结果。结果保留原始重叠区间，字幕边界由优化器生成非重叠时间线。
public struct SpeakerDiarizationTimeline: Equatable, Sendable {
    public var segments: [SpeakerDiarizationSegment]
    public var speakerCount: Int

    public init(segments: [SpeakerDiarizationSegment], speakerCount: Int = 0) {
        self.segments = segments
            .filter { $0.endTime - $0.startTime >= 0.02 }
            .sorted {
                if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
                return $0.startTime < $1.startTime
            }
        self.speakerCount = max(speakerCount, self.segments.flatMap(\.speakerIDs).max().map { $0 + 1 } ?? 0)
    }

    public var isEmpty: Bool { segments.isEmpty }
}

/// Shared interpretation of SpeakerKit output. Only confident, exclusive and
/// near-adjacent speaker turns are hard boundaries; overlap regions remain
/// soft evidence for the sentence optimizer.
enum SpeakerTurnAnalysis {
    static func reliableBoundaries(
        in input: [SpeakerDiarizationSegment],
        duration: Double
    ) -> [Double] {
        guard duration.isFinite, duration > 0 else { return [] }
        let exclusive = input.compactMap { segment -> SpeakerDiarizationSegment? in
            let start = min(duration, max(0, segment.startTime))
            let end = min(duration, max(start, segment.endTime))
            // When the provider has a calibrated posterior, retain the
            // confidence gate. SpeakerKit 1.1 has no such value, so rely on a
            // stable exclusive interval instead of rejecting every real turn
            // merely because its confidence is represented as unknown.
            guard end - start >= 0.18,
                  (!segment.hasCalibratedConfidence || segment.confidence >= 0.35),
                  segment.speakerIDs.count == 1,
                  !segment.isOverlap else { return nil }
            return SpeakerDiarizationSegment(
                startTime: start,
                endTime: end,
                speakerIDs: segment.speakerIDs,
                confidence: segment.confidence,
                hasCalibratedConfidence: segment.hasCalibratedConfidence
            )
        }.sorted {
            if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
            return $0.startTime < $1.startTime
        }
        guard exclusive.count > 1 else { return [] }

        var boundaries: [Double] = []
        for index in 1..<exclusive.count {
            let previous = exclusive[index - 1]
            let current = exclusive[index]
            guard previous.primarySpeakerID != current.primarySpeakerID else { continue }

            // SpeakerKit 1.1 does not expose a calibrated posterior. Require
            // both sides of an unknown-confidence turn to persist long enough
            // to reject frame-level label flicker. Calibrated providers may
            // use a shorter persistence gate because confidence is available.
            let minimumPersistence = (previous.hasCalibratedConfidence && current.hasCalibratedConfidence)
                ? 0.25
                : 0.55
            guard previous.duration >= minimumPersistence,
                  current.duration >= minimumPersistence else { continue }

            // A -> brief B -> A is commonly identity flicker in music/noise.
            // Keep it as soft evidence in the optimizer, but never make both
            // edges mandatory Whisper window boundaries.
            let next = index + 1 < exclusive.count ? exclusive[index + 1] : nil
            let previousPrevious = index >= 2 ? exclusive[index - 2] : nil
            let entersShortReturn = current.duration < 1.0
                && next?.primarySpeakerID == previous.primarySpeakerID
                && (next?.startTime ?? .greatestFiniteMagnitude) - current.endTime <= 0.16
            let leavesShortReturn = previous.duration < 1.0
                && previousPrevious?.primarySpeakerID == current.primarySpeakerID
                && previous.startTime - (previousPrevious?.endTime ?? -Double.greatestFiniteMagnitude) <= 0.16
            guard !entersShortReturn, !leavesShortReturn else { continue }

            // A material overlap is not a clean turn boundary. Long silence is
            // already separated by VAD and does not need a speaker hard split.
            let gap = current.startTime - previous.endTime
            guard gap >= -0.04, gap <= 1.20 else { continue }
            let boundary = min(duration, max(0, (previous.endTime + current.startTime) / 2))
            guard boundary > 0.01, boundary < duration - 0.01 else { continue }
            if let last = boundaries.last, abs(last - boundary) < 0.04 {
                boundaries[boundaries.count - 1] = (last + boundary) / 2
            } else {
                boundaries.append(boundary)
            }
        }
        return boundaries
    }
}

/// SpeakerKit 的本地模型加载与推理封装。
///
/// 模型默认从应用资源中读取，不依赖首次启动联网下载。模型目录必须保留
/// `speaker_segmenter`、`speaker_embedder` 和 `speaker_clusterer` 的原始层级。
public actor SpeakerDiarizationEngine {
    public static let shared = SpeakerDiarizationEngine()

    private var speakerKit: SpeakerKit?
    private var loadedModelFolder: URL?
    private var speakerBackend: SpeechInferenceBackend = .cpu
    private var speakerAccelerationUnavailable = false

    public init() {}

    public func diarize(
        pcm: AudioPCMData,
        numberOfSpeakers: Int? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> SpeakerDiarizationTimeline {
        guard pcm.sampleRate == AudioPCMData.requiredSampleRate, !pcm.isEmpty else {
            throw SpeakerDiarizationEngineError.invalidPCM
        }
        try Task.checkCancellation()

        let kit = try await loadSpeakerKit()
        let options = PyannoteDiarizationOptions(
            numberOfSpeakers: numberOfSpeakers,
            // Suppress frame-level identity flicker while still preserving
            // normal short replies and overlap regions.
            minActiveOffset: 0.08,
            clusterDistanceThreshold: 0.60,
            minClusterSize: nil,
            // Keep raw overlap information. The sentence optimizer performs the
            // exclusive token assignment after Whisper timestamps are available.
            useExclusiveReconciliation: false,
            centroidSource: .finalAssignment,
            clipTimestamps: []
        )

        let result: DiarizationResult
        do {
            result = try await SpeechInferenceResourceScheduler.shared.withExclusiveStage {
                try await kit.diarize(
                    audioArray: pcm.samples,
                    options: options,
                    progressCallback: { callbackProgress in
                        progress(min(1, max(0, callbackProgress.fractionCompleted)))
                    }
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Core ML backends vary across macOS versions and model variants.
            // If the accelerated path cannot load or infer, unload it once and
            // retry the identical SpeakerKit options on CPU. The fallback is
            // deliberately outside the boundary optimizer, so sentence logic
            // and overlap preservation remain unchanged.
            guard speakerBackend == .coreML else { throw error }
            await kit.unloadModels()
            speakerKit = nil
            loadedModelFolder = nil
            speakerAccelerationUnavailable = true
            let cpuKit = try await loadSpeakerKit(forceCPU: true)
            result = try await SpeechInferenceResourceScheduler.shared.withExclusiveStage {
                try await cpuKit.diarize(
                    audioArray: pcm.samples,
                    options: options,
                    progressCallback: { callbackProgress in
                        progress(min(1, max(0, callbackProgress.fractionCompleted)))
                    }
                )
            }
        }
        try Task.checkCancellation()
        progress(1)
        return Self.makeTimeline(from: result, duration: pcm.duration)
    }

    public func unloadModels() async {
        try? await SpeechInferenceResourceScheduler.shared.withExclusiveStage {
            await self.unloadModelsLocked()
        }
    }

    private func unloadModelsLocked() async {
        await speakerKit?.unloadModels()
        speakerKit = nil
        loadedModelFolder = nil
        speakerBackend = .cpu
        speakerAccelerationUnavailable = false
    }

    private func loadSpeakerKit(forceCPU: Bool = false) async throws -> SpeakerKit {
        let modelFolder = try Self.bundledModelFolder()
        let policy = SpeechInferenceResourcePolicy.current()
        let useCoreML = !forceCPU && policy.preferSpeakerCoreML && !speakerAccelerationUnavailable
        let requestedBackend: SpeechInferenceBackend = useCoreML ? .coreML : .cpu
        if let speakerKit,
           loadedModelFolder?.standardizedFileURL == modelFolder.standardizedFileURL,
           speakerBackend == requestedBackend {
            return speakerKit
        }

        if speakerKit != nil {
            await speakerKit?.unloadModels()
            speakerKit = nil
            loadedModelFolder = nil
        }

        let config = PyannoteConfig(
            modelFolder: modelFolder.path,
            download: false,
            load: false,
            verbose: false,
            fullRedundancy: true,
            concurrentSegmenterWorkers: policy.speakerSegmenterWorkers,
            concurrentEmbedderWorkers: policy.speakerEmbedderWorkers
        )

        if useCoreML {
            // Keep PLDA on CPU (it is small); schedule the neural segmenter
            // and embedder on Core ML so Apple Silicon can use GPU/ANE.
            config.diarizer = SpeakerKitDiarizer.pyannote(
                config: config,
                segmenterModelInfo: .segmenter(computeUnits: .all),
                embedderModelInfo: .embedder(computeUnits: .all),
                pldaModelInfo: .plda()
            )
        }
        let newSpeakerKit = try await SpeakerKit(config)
        speakerKit = newSpeakerKit
        loadedModelFolder = modelFolder
        speakerBackend = requestedBackend
        return newSpeakerKit
    }

    private static func makeTimeline(
        from result: DiarizationResult,
        duration: Double
    ) -> SpeakerDiarizationTimeline {
        let rawSegments = result.segments.compactMap { segment -> SpeakerDiarizationSegment? in
            let start = min(duration, max(0, Double(segment.startTime)))
            let end = min(duration, max(start, Double(segment.endTime)))
            let ids = segment.speaker.speakerIds
            guard end - start >= 0.02, !ids.isEmpty else { return nil }
            return SpeakerDiarizationSegment(
                startTime: start,
                endTime: end,
                speakerIDs: ids,
                // SpeakerKit's public diarization result exposes labels and
                // timestamps, but not a calibrated per-segment posterior.
                // Zero means "unknown", not "certain"; callers must apply
                // temporal/acoustic gating instead of treating this as 1.0.
                confidence: 0,
                hasCalibratedConfidence: false,
                isOverlap: ids.count > 1
            )
        }

        guard !rawSegments.isEmpty else {
            return SpeakerDiarizationTimeline(segments: [], speakerCount: result.speakerCount)
        }

        // SpeakerKit can return one segment per speaker. Mark cross-segment
        // overlaps with a sweep instead of an O(n²) all-pairs comparison.
        var segments = rawSegments.sorted {
            if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
            return $0.startTime < $1.startTime
        }
        var active: [(index: Int, end: Double, speakerIDs: Set<Int>)] = []
        var overlapFlags = [Bool](repeating: false, count: segments.count)

        for index in segments.indices {
            let start = segments[index].startTime
            active.removeAll { $0.end <= start + 0.02 }
            let currentIDs = Set(segments[index].speakerIDs)
            for item in active {
                // Overlapping intervals belonging to the same speaker are
                // usually diarization window artifacts, not two voices. Only
                // mark true overlap when the active identity sets contain more
                // than one distinct speaker.
                guard item.speakerIDs.union(currentIDs).count > 1 else { continue }
                overlapFlags[index] = true
                overlapFlags[item.index] = true
            }
            active.append((index, segments[index].endTime, currentIDs))
        }

        for index in segments.indices where overlapFlags[index] {
            segments[index].isOverlap = true
        }
        return SpeakerDiarizationTimeline(segments: segments, speakerCount: result.speakerCount)
    }

    private static func bundledModelFolder() throws -> URL {
        let modelDirectoryName = "speakerkit-coreml"
        var candidates: [URL] = []

        if let bundle = MacAbobooResourceBundle.bundle,
           let url = bundle.url(
            forResource: modelDirectoryName,
            withExtension: nil,
            subdirectory: "SpeakerKitModels"
        ) {
            candidates.append(url)
        }
        if let resourceURL = MacAbobooResourceBundle.bundle?.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("SpeakerKitModels", isDirectory: true)
                .appendingPathComponent(modelDirectoryName, isDirectory: true))
        }

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("SpeakerKitModels", isDirectory: true)
                .appendingPathComponent(modelDirectoryName, isDirectory: true))
            candidates.append(resourceURL.appendingPathComponent(modelDirectoryName, isDirectory: true))
        }

        // Development fallback for a directly launched executable.
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/MacAboboo/Resources/SpeakerKitModels", isDirectory: true)
                .appendingPathComponent(modelDirectoryName, isDirectory: true)
        )

        if let folder = candidates.first(where: { Self.isUsableModelFolder($0) }) {
            return folder
        }
        throw SpeakerDiarizationEngineError.modelMissing
    }

    private static func isUsableModelFolder(_ folder: URL) -> Bool {
        // SpeakerKit selects W32A32 segmenter on macOS 14 and W8A16 from
        // macOS 15 onward. Keep both variants in the app so the same release
        // works on the minimum supported OS and newer Apple Silicon systems.
        let segmenterVariant: String
        if #available(macOS 15, *) {
            segmenterVariant = "W8A16"
        } else {
            segmenterVariant = "W32A32"
        }
        let requiredPaths = [
            "speaker_segmenter/pyannote-v3/\(segmenterVariant)/SpeakerSegmenter.mlmodelc",
            "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc",
            "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc",
            "speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc"
        ]
        return requiredPaths.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }
}

public enum SpeakerDiarizationEngineError: LocalizedError {
    case invalidPCM
    case modelMissing

    public var errorDescription: String? {
        switch self {
        case .invalidPCM:
            return "说话人分离只接受 16 kHz 单声道音频。"
        case .modelMissing:
            return "SpeakerKit 说话人模型缺失，请重新安装完整应用包。"
        }
    }
}
