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
            minActiveOffset: 0.12,
            clusterDistanceThreshold: 0.64,
            minClusterSize: numberOfSpeakers == nil ? 2 : nil,
            // Keep raw overlap information. The sentence optimizer performs the
            // exclusive token assignment after Whisper timestamps are available.
            useExclusiveReconciliation: false,
            centroidSource: .finalAssignment,
            clipTimestamps: []
        )

        let timeline: SpeakerDiarizationTimeline
        do {
            timeline = try await diarizePCM(pcm, with: kit, options: options, progress: progress)
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
            timeline = try await diarizePCM(pcm, with: cpuKit, options: options, progress: progress)
        }
        try Task.checkCancellation()
        progress(1)
        return timeline
    }

    /// SpeakerKit currently accepts an owned `[Float]`. Media up to 15 minutes
    /// is diarized in a single global pass so VBx clustering sees all speaker
    /// turns at once. Longer recordings use 15-minute windows with 15-second
    /// context overlap and duration-weighted centroid reconciliation.
    private func diarizePCM(
        _ pcm: AudioPCMData,
        with kit: SpeakerKit,
        options: PyannoteDiarizationOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> SpeakerDiarizationTimeline {
        let chunkDuration = 15.0 * 60.0
        let contextOverlap = 15.0
        guard pcm.duration > chunkDuration + contextOverlap else {
            let audio = pcm.samples(in: 0..<pcm.sampleCount)
            let result = try await SpeechInferenceResourceScheduler.shared.withExclusiveStage {
                try await kit.diarize(
                    audioArray: audio,
                    options: options,
                    progressCallback: { callbackProgress in
                        progress(min(1, max(0, callbackProgress.fractionCompleted)))
                    }
                )
            }
            let rawTimeline = Self.makeTimeline(from: result, duration: pcm.duration)
            return Self.refineDiarizationTimeline(
                rawTimeline,
                centroids: result.speakerCentroidEmbeddings,
                duration: pcm.duration,
                requestedSpeakerCount: options.numberOfSpeakers
            )
        }

        let chunkCount = max(1, Int(ceil(pcm.duration / chunkDuration)))
        var accepted: [SpeakerDiarizationSegment] = []
        var globalCentroids: [Int: ([Float], Double)] = [:]
        var nextSpeakerID = 0

        for chunkIndex in 0..<chunkCount {
            try Task.checkCancellation()
            let coreStart = Double(chunkIndex) * chunkDuration
            let coreEnd = min(pcm.duration, coreStart + chunkDuration)
            let readStart = max(0, coreStart - contextOverlap)
            let readEnd = min(pcm.duration, coreEnd + contextOverlap)
            let sampleStart = max(0, Int(floor(readStart * Double(pcm.sampleRate))))
            let sampleEnd = min(pcm.sampleCount, Int(ceil(readEnd * Double(pcm.sampleRate))))
            let audio = pcm.samples(in: sampleStart..<sampleEnd)
            let baseProgress = Double(chunkIndex) / Double(chunkCount)
            let result = try await SpeechInferenceResourceScheduler.shared.withExclusiveStage {
                try await kit.diarize(
                    audioArray: audio,
                    options: options,
                    progressCallback: { callbackProgress in
                        let local = min(1, max(0, callbackProgress.fractionCompleted))
                        progress(baseProgress + local / Double(chunkCount))
                    }
                )
            }

            let localTimeline = Self.makeTimeline(
                from: result,
                duration: readEnd - readStart,
                timeOffset: readStart
            )
            let mapping = Self.reconcileSpeakerIDs(
                localTimeline: localTimeline,
                localCentroids: result.speakerCentroidEmbeddings,
                accepted: accepted,
                overlapStart: readStart,
                overlapEnd: coreStart,
                globalCentroids: globalCentroids,
                nextSpeakerID: &nextSpeakerID,
                maximumSpeakerCount: options.numberOfSpeakers
            )

            for segment in localTimeline.segments {
                let clippedStart = max(coreStart, segment.startTime)
                let clippedEnd = min(coreEnd, segment.endTime)
                guard clippedEnd - clippedStart >= 0.02 else { continue }
                let mappedIDs = Array(Set(segment.speakerIDs.compactMap { mapping[$0] })).sorted()
                guard !mappedIDs.isEmpty else { continue }
                accepted.append(SpeakerDiarizationSegment(
                    startTime: clippedStart,
                    endTime: clippedEnd,
                    speakerIDs: mappedIDs,
                    confidence: segment.confidence,
                    hasCalibratedConfidence: segment.hasCalibratedConfidence,
                    isOverlap: segment.isOverlap
                ))
            }
            Self.mergeCentroids(
                result.speakerCentroidEmbeddings,
                localTimeline: localTimeline,
                mapping: mapping,
                into: &globalCentroids
            )
        }

        let mergedTimeline = SpeakerDiarizationTimeline(
            segments: Self.mergeChunkSeams(accepted),
            speakerCount: nextSpeakerID
        )
        return Self.refineDiarizationTimeline(
            mergedTimeline,
            centroids: globalCentroids.mapValues(\.0),
            duration: pcm.duration,
            requestedSpeakerCount: options.numberOfSpeakers
        )
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

        let segmenterVariant = Self.preferredSegmenterVariant(in: modelFolder)
        let computeUnits: MLComputeUnits = useCoreML ? .all : .cpuOnly
        // Keep PLDA on CPU (it is small); schedule the neural segmenter
        // (preferring full-precision W32A32 when bundled) and embedder on
        // Core ML when available so Apple Silicon can use GPU/ANE.
        config.diarizer = SpeakerKitDiarizer.pyannote(
            config: config,
            segmenterModelInfo: .segmenter(variant: segmenterVariant, computeUnits: computeUnits),
            embedderModelInfo: .embedder(computeUnits: computeUnits),
            pldaModelInfo: .plda()
        )
        let newSpeakerKit = try await SpeakerKit(config)
        speakerKit = newSpeakerKit
        loadedModelFolder = modelFolder
        speakerBackend = requestedBackend
        return newSpeakerKit
    }

    private static func makeTimeline(
        from result: DiarizationResult,
        duration: Double,
        timeOffset: Double = 0
    ) -> SpeakerDiarizationTimeline {
        let rawSegments = result.segments.compactMap { segment -> SpeakerDiarizationSegment? in
            let localStart = min(duration, max(0, Double(segment.startTime)))
            let localEnd = min(duration, max(localStart, Double(segment.endTime)))
            let ids = segment.speaker.speakerIds
            guard localEnd - localStart >= 0.02, !ids.isEmpty else { return nil }
            return SpeakerDiarizationSegment(
                startTime: localStart + timeOffset,
                endTime: localEnd + timeOffset,
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

        let segments = recomputeOverlapsAndCoalesce(rawSegments)
        return SpeakerDiarizationTimeline(segments: segments, speakerCount: result.speakerCount)
    }

    /// Automatic post-diarization refinement for real study media where the
    /// exact number of speakers is usually unknown:
    /// 1. Consolidate over-split clusters whose voiceprint centroids are close.
    /// 2. Absorb transient micro-clusters (coughs, laughs, noisy interjections).
    /// 3. Smooth frame-level `A -> brief B -> A` sandwich flickers.
    /// 4. Compact surviving speaker IDs into contiguous `0..<N` order.
    static func refineDiarizationTimeline(
        _ timeline: SpeakerDiarizationTimeline,
        centroids: [Int: [Float]] = [:],
        duration: Double,
        requestedSpeakerCount: Int? = nil
    ) -> SpeakerDiarizationTimeline {
        guard !timeline.segments.isEmpty else { return timeline }
        var segments = recomputeOverlapsAndCoalesce(timeline.segments)
        guard !segments.isEmpty else { return timeline }

        var workingCentroids: [Int: (vector: [Float], weight: Double)] = [:]
        let initialDurations = speakingDurations(in: segments)
        let totalSpeechDuration = initialDurations.values.reduce(0, +)
        for (speakerID, vector) in centroids where !vector.isEmpty {
            let weight = max(0.2, initialDurations[speakerID] ?? 1.0)
            workingCentroids[speakerID] = (normalizedVector(vector), weight)
        }

        // Stage 1: Over-split voiceprint cluster consolidation when speaker count is unknown.
        if requestedSpeakerCount == nil, workingCentroids.count > 1 {
            var speakerRemap: [Int: Int] = [:]
            var currentDurations = initialDurations

            func resolve(_ id: Int) -> Int {
                var current = id
                while let next = speakerRemap[current], next != current {
                    current = next
                }
                return current
            }

            while workingCentroids.count > 1 {
                let activeIDs = workingCentroids.keys.sorted()
                var bestMerge: (major: Int, minor: Int, distance: Float)?

                for i in 0..<activeIDs.count {
                    for j in (i + 1)..<activeIDs.count {
                        let first = activeIDs[i]
                        let second = activeIDs[j]
                        guard let c1 = workingCentroids[first],
                              let c2 = workingCentroids[second],
                              let dist = cosineDistance(c1.vector, c2.vector) else { continue }
                        let d1 = currentDurations[first] ?? 0
                        let d2 = currentDurations[second] ?? 0
                        let (major, minor, minorDuration) = d1 >= d2
                            ? (first, second, d2)
                            : (second, first, d1)
                        let minorIsSmall = minorDuration < max(3.0, totalSpeechDuration * 0.10)
                        let threshold: Float = minorIsSmall ? 0.36 : 0.28
                        guard dist <= threshold else { continue }
                        if bestMerge == nil || dist < bestMerge!.distance {
                            bestMerge = (major, minor, dist)
                        }
                    }
                }

                guard let merge = bestMerge,
                      let majorEntry = workingCentroids[merge.major],
                      let minorEntry = workingCentroids[merge.minor] else {
                    break
                }
                speakerRemap[merge.minor] = merge.major
                let combinedWeight = majorEntry.weight + minorEntry.weight
                let combinedVector = normalizedVector(
                    zip(majorEntry.vector, minorEntry.vector).map {
                        Float((Double($0.0) * majorEntry.weight + Double($0.1) * minorEntry.weight) / max(0.001, combinedWeight))
                    }
                )
                workingCentroids[merge.major] = (combinedVector, combinedWeight)
                workingCentroids.removeValue(forKey: merge.minor)
                currentDurations[merge.major, default: 0] += currentDurations[merge.minor] ?? 0
                currentDurations.removeValue(forKey: merge.minor)
            }

            if !speakerRemap.isEmpty {
                segments = segments.map { segment in
                    var copy = segment
                    copy.speakerIDs = Array(Set(segment.speakerIDs.map(resolve))).sorted()
                    return copy
                }
                segments = recomputeOverlapsAndCoalesce(segments)
            }
        }

        // Stage 2: Micro-cluster absorption when speaker count is unknown.
        if requestedSpeakerCount == nil {
            let durations = speakingDurations(in: segments)
            let maxSegmentBySpeaker = maxSegmentDurations(in: segments)
            let totalDuration = durations.values.reduce(0, +)
            let majorSpeakers = durations.compactMap { id, dur -> Int? in
                dur >= 1.5 || (dur >= 0.80 && dur >= totalDuration * 0.18) ? id : nil
            }.sorted()

            if !majorSpeakers.isEmpty, durations.count > majorSpeakers.count {
                let microThreshold = min(1.5, max(0.35, totalDuration * 0.04))
                let microSpeakers = Set(durations.compactMap { id, dur -> Int? in
                    guard !majorSpeakers.contains(id) else { return nil }
                    let maxSeg = maxSegmentBySpeaker[id] ?? 0
                    if dur < 0.35 || (dur < microThreshold && maxSeg < 0.90) {
                        return id
                    }
                    return nil
                })

                if !microSpeakers.isEmpty {
                    let dominantMajor = majorSpeakers.max { (durations[$0] ?? 0) < (durations[$1] ?? 0) } ?? majorSpeakers[0]
                    var globalMicroTarget: [Int: Int] = [:]
                    for microID in microSpeakers {
                        guard let microCentroid = workingCentroids[microID]?.vector else { continue }
                        if let best = majorSpeakers.compactMap({ majorID -> (Int, Float)? in
                            guard let majorCentroid = workingCentroids[majorID]?.vector,
                                  let dist = cosineDistance(microCentroid, majorCentroid) else { return nil }
                            return (majorID, dist)
                        }).min(by: { $0.1 < $1.1 }), best.1 <= 0.58 {
                            globalMicroTarget[microID] = best.0
                        }
                    }

                    for index in segments.indices {
                        let currentIDs = segments[index].speakerIDs
                        guard currentIDs.contains(where: { microSpeakers.contains($0) }) else { continue }
                        let mapped = currentIDs.map { id -> Int in
                            guard microSpeakers.contains(id) else { return id }
                            if let target = globalMicroTarget[id] { return target }
                            return nearestMajorSpeaker(
                                to: index,
                                in: segments,
                                majorSpeakers: Set(majorSpeakers),
                                fallback: dominantMajor
                            )
                        }
                        segments[index].speakerIDs = Array(Set(mapped)).sorted()
                    }
                    segments = recomputeOverlapsAndCoalesce(segments)
                }
            }
        }

        // Stage 3: Sandwich de-flickering (A -> brief B -> A).
        for _ in 0..<2 {
            guard segments.count >= 3 else { break }
            var changed = false
            for index in 1..<(segments.count - 1) {
                let previous = segments[index - 1]
                let current = segments[index]
                let next = segments[index + 1]
                guard !previous.isOverlap,
                      !current.isOverlap,
                      !next.isOverlap,
                      let prevID = previous.primarySpeakerID,
                      let currID = current.primarySpeakerID,
                      let nextID = next.primarySpeakerID,
                      prevID == nextID,
                      currID != prevID else { continue }
                let gapBefore = max(0, current.startTime - previous.endTime)
                let gapAfter = max(0, next.startTime - current.endTime)
                guard current.duration <= 0.35,
                      gapBefore <= 0.16,
                      gapAfter <= 0.16,
                      previous.duration + next.duration >= max(0.80, current.duration * 3.0) else { continue }
                segments[index].speakerIDs = [prevID]
                changed = true
            }
            if changed {
                segments = recomputeOverlapsAndCoalesce(segments)
            } else {
                break
            }
        }

        // Stage 4: Compact speaker IDs into contiguous 0..<N in order of first appearance.
        var compactMapping: [Int: Int] = [:]
        var nextCompactID = 0
        for segment in segments {
            for id in segment.speakerIDs where compactMapping[id] == nil {
                compactMapping[id] = nextCompactID
                nextCompactID += 1
            }
        }
        if compactMapping.contains(where: { $0.key != $0.value }) {
            segments = segments.map { segment in
                var copy = segment
                copy.speakerIDs = Array(Set(segment.speakerIDs.compactMap { compactMapping[$0] })).sorted()
                return copy
            }
            segments = recomputeOverlapsAndCoalesce(segments)
        }

        return SpeakerDiarizationTimeline(
            segments: segments,
            speakerCount: max(nextCompactID, segments.flatMap(\.speakerIDs).max().map { $0 + 1 } ?? 0)
        )
    }

    private static func speakingDurations(in segments: [SpeakerDiarizationSegment]) -> [Int: Double] {
        var durations: [Int: Double] = [:]
        for segment in segments {
            let share = segment.duration / Double(max(1, segment.speakerIDs.count))
            for id in segment.speakerIDs {
                durations[id, default: 0] += share
            }
        }
        return durations
    }

    private static func maxSegmentDurations(in segments: [SpeakerDiarizationSegment]) -> [Int: Double] {
        var maxDurations: [Int: Double] = [:]
        for segment in segments {
            for id in segment.speakerIDs {
                maxDurations[id] = max(maxDurations[id] ?? 0, segment.duration)
            }
        }
        return maxDurations
    }

    private static func nearestMajorSpeaker(
        to targetIndex: Int,
        in segments: [SpeakerDiarizationSegment],
        majorSpeakers: Set<Int>,
        fallback: Int
    ) -> Int {
        let target = segments[targetIndex]
        var bestID: Int?
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, candidate) in segments.enumerated() where index != targetIndex {
            let candidateMajors = candidate.speakerIDs.filter { majorSpeakers.contains($0) }
            guard let majorID = candidateMajors.first else { continue }
            let temporalGap: Double
            if candidate.endTime <= target.startTime {
                temporalGap = target.startTime - candidate.endTime
            } else if candidate.startTime >= target.endTime {
                temporalGap = candidate.startTime - target.endTime
            } else {
                temporalGap = 0
            }
            if temporalGap < bestDistance {
                bestDistance = temporalGap
                bestID = majorID
            }
        }
        if let bestID, bestDistance <= 3.0 {
            return bestID
        }
        return fallback
    }

    private static func recomputeOverlapsAndCoalesce(
        _ input: [SpeakerDiarizationSegment]
    ) -> [SpeakerDiarizationSegment] {
        let sorted = input
            .filter { $0.endTime - $0.startTime >= 0.02 && !$0.speakerIDs.isEmpty }
            .sorted {
                if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
                return $0.startTime < $1.startTime
            }
        guard !sorted.isEmpty else { return [] }

        // First collapse overlapping or near-adjacent intervals that belong to
        // the exact same single speaker.
        var collapsed: [SpeakerDiarizationSegment] = []
        collapsed.reserveCapacity(sorted.count)
        for var segment in sorted {
            segment.speakerIDs = Array(Set(segment.speakerIDs)).sorted()
            if let last = collapsed.last,
               last.speakerIDs.count == 1,
               last.speakerIDs == segment.speakerIDs,
               segment.startTime - last.endTime <= 0.08 {
                collapsed[collapsed.count - 1].endTime = max(last.endTime, segment.endTime)
                collapsed[collapsed.count - 1].confidence = max(last.confidence, segment.confidence)
                collapsed[collapsed.count - 1].hasCalibratedConfidence =
                    last.hasCalibratedConfidence && segment.hasCalibratedConfidence
            } else {
                collapsed.append(segment)
            }
        }

        // Sweep to determine true multi-speaker overlap.
        var active: [(index: Int, end: Double, speakerIDs: Set<Int>)] = []
        var overlapFlags = [Bool](repeating: false, count: collapsed.count)

        for index in collapsed.indices {
            let start = collapsed[index].startTime
            active.removeAll { $0.end <= start + 0.02 }
            let currentIDs = Set(collapsed[index].speakerIDs)
            if currentIDs.count > 1 {
                overlapFlags[index] = true
            }
            for item in active {
                guard item.speakerIDs.union(currentIDs).count > 1 else { continue }
                overlapFlags[index] = true
                overlapFlags[item.index] = true
            }
            active.append((index, collapsed[index].endTime, currentIDs))
        }

        for index in collapsed.indices {
            collapsed[index].isOverlap = overlapFlags[index]
        }
        return mergeChunkSeams(collapsed)
    }

    static func reconcileSpeakerIDs(
        localTimeline: SpeakerDiarizationTimeline,
        localCentroids: [Int: [Float]],
        accepted: [SpeakerDiarizationSegment],
        overlapStart: Double,
        overlapEnd: Double,
        globalCentroids: [Int: ([Float], Double)],
        nextSpeakerID: inout Int,
        maximumSpeakerCount: Int?
    ) -> [Int: Int] {
        let localIDs = Set(localTimeline.segments.flatMap(\.speakerIDs)).sorted()
        var mapping: [Int: Int] = [:]
        var usedGlobalIDs = Set<Int>()

        // Step 1: Global best-first temporal overlap assignment in the seam window.
        struct OverlapCandidate {
            let localID: Int
            let globalID: Int
            let overlap: Double
        }
        var overlapCandidates: [OverlapCandidate] = []
        for localID in localIDs {
            var overlapByGlobal: [Int: Double] = [:]
            for local in localTimeline.segments where local.speakerIDs.contains(localID) {
                let localStart = max(overlapStart, local.startTime)
                let localEnd = min(overlapEnd, local.endTime)
                guard localEnd > localStart else { continue }
                for global in accepted {
                    let amount = min(localEnd, global.endTime) - max(localStart, global.startTime)
                    guard amount > 0 else { continue }
                    for globalID in global.speakerIDs {
                        overlapByGlobal[globalID, default: 0] += amount
                    }
                }
            }
            for (globalID, amount) in overlapByGlobal where amount >= 0.18 {
                overlapCandidates.append(OverlapCandidate(localID: localID, globalID: globalID, overlap: amount))
            }
        }
        overlapCandidates.sort {
            if abs($0.overlap - $1.overlap) > 1e-6 { return $0.overlap > $1.overlap }
            if $0.localID != $1.localID { return $0.localID < $1.localID }
            return $0.globalID < $1.globalID
        }
        for candidate in overlapCandidates {
            guard mapping[candidate.localID] == nil,
                  !usedGlobalIDs.contains(candidate.globalID) else { continue }
            mapping[candidate.localID] = candidate.globalID
            usedGlobalIDs.insert(candidate.globalID)
        }

        // Step 2: Global best-first voiceprint centroid matching across remaining speakers.
        struct CentroidCandidate {
            let localID: Int
            let globalID: Int
            let distance: Float
        }
        var centroidCandidates: [CentroidCandidate] = []
        for localID in localIDs where mapping[localID] == nil {
            guard let centroid = localCentroids[localID] else { continue }
            for (globalID, stored) in globalCentroids where !usedGlobalIDs.contains(globalID) {
                guard let distance = cosineDistance(centroid, stored.0),
                      distance <= 0.48 else { continue }
                centroidCandidates.append(CentroidCandidate(localID: localID, globalID: globalID, distance: distance))
            }
        }
        centroidCandidates.sort {
            if abs($0.distance - $1.distance) > 1e-6 { return $0.distance < $1.distance }
            if $0.localID != $1.localID { return $0.localID < $1.localID }
            return $0.globalID < $1.globalID
        }
        for candidate in centroidCandidates {
            guard mapping[candidate.localID] == nil,
                  !usedGlobalIDs.contains(candidate.globalID) else { continue }
            mapping[candidate.localID] = candidate.globalID
            usedGlobalIDs.insert(candidate.globalID)
        }

        // Step 3: Allocate new speaker IDs or clamp to maximumSpeakerCount.
        for localID in localIDs where mapping[localID] == nil {
            if let maximumSpeakerCount,
               globalCentroids.count >= maximumSpeakerCount,
               let centroid = localCentroids[localID],
               let nearest = globalCentroids.compactMap({ globalID, stored -> (Int, Float)? in
                   guard !usedGlobalIDs.contains(globalID),
                         let distance = cosineDistance(centroid, stored.0) else { return nil }
                   return (globalID, distance)
               }).min(by: { $0.1 < $1.1 }) {
                mapping[localID] = nearest.0
                usedGlobalIDs.insert(nearest.0)
            } else {
                mapping[localID] = nextSpeakerID
                usedGlobalIDs.insert(nextSpeakerID)
                nextSpeakerID += 1
            }
        }
        return mapping
    }

    static func mergeCentroids(
        _ localCentroids: [Int: [Float]],
        localTimeline: SpeakerDiarizationTimeline? = nil,
        mapping: [Int: Int],
        into globalCentroids: inout [Int: ([Float], Double)]
    ) {
        let localDurations = localTimeline.map { speakingDurations(in: $0.segments) } ?? [:]
        for (localID, rawCentroid) in localCentroids {
            guard let globalID = mapping[localID], !rawCentroid.isEmpty else { continue }
            let centroid = normalizedVector(rawCentroid)
            let localWeight = max(1.0, localDurations[localID] ?? 1.0)
            guard let existing = globalCentroids[globalID], existing.0.count == centroid.count else {
                globalCentroids[globalID] = (centroid, localWeight)
                continue
            }
            let existingNorm = normalizedVector(existing.0)
            let newWeight = existing.1 + localWeight
            let merged = normalizedVector(
                zip(existingNorm, centroid).map {
                    Float((Double($0.0) * existing.1 + Double($0.1) * localWeight) / newWeight)
                }
            )
            globalCentroids[globalID] = (merged, newWeight)
        }
    }

    private static func normalizedVector(_ vector: [Float]) -> [Float] {
        var normSquared: Double = 0
        for value in vector {
            let d = Double(value)
            normSquared += d * d
        }
        let norm = sqrt(normSquared)
        guard norm > 1e-12 else { return vector }
        return vector.map { Float(Double($0) / norm) }
    }

    private static func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Float? {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return nil }
        var dot: Double = 0
        var lhsNorm: Double = 0
        var rhsNorm: Double = 0
        for index in lhs.indices {
            let left = Double(lhs[index])
            let right = Double(rhs[index])
            dot += left * right
            lhsNorm += left * left
            rhsNorm += right * right
        }
        guard lhsNorm > 0, rhsNorm > 0 else { return nil }
        return Float(max(0, min(2, 1 - dot / sqrt(lhsNorm * rhsNorm))))
    }

    static func mergeChunkSeams(
        _ input: [SpeakerDiarizationSegment]
    ) -> [SpeakerDiarizationSegment] {
        let sorted = input.sorted {
            if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
            return $0.startTime < $1.startTime
        }
        var output: [SpeakerDiarizationSegment] = []
        output.reserveCapacity(sorted.count)
        for segment in sorted {
            if let last = output.last,
               last.speakerIDs == segment.speakerIDs,
               last.isOverlap == segment.isOverlap,
               segment.startTime - last.endTime <= 0.08 {
                output[output.count - 1].endTime = max(last.endTime, segment.endTime)
            } else {
                output.append(segment)
            }
        }
        return output
    }

    private static func bundledModelFolder() throws -> URL {
        let modelDirectoryName = "speakerkit-coreml"
        var candidates: [URL] = []

        if let bundle = StudyMateResourceBundle.bundle,
           let url = bundle.url(
            forResource: modelDirectoryName,
            withExtension: nil,
            subdirectory: "SpeakerKitModels"
        ) {
            candidates.append(url)
        }
        if let resourceURL = StudyMateResourceBundle.bundle?.resourceURL {
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
                .appendingPathComponent("Sources/StudyMate/Resources/SpeakerKitModels", isDirectory: true)
                .appendingPathComponent(modelDirectoryName, isDirectory: true)
        )

        if let folder = candidates.first(where: { Self.isUsableModelFolder($0) }) {
            return folder
        }
        throw SpeakerDiarizationEngineError.modelMissing
    }

    static func preferredSegmenterVariant(in folder: URL) -> String {
        let fullPrecision = folder.appendingPathComponent(
            "speaker_segmenter/pyannote-v3/W32A32/SpeakerSegmenter.mlmodelc"
        )
        if FileManager.default.fileExists(atPath: fullPrecision.path) {
            return "W32A32"
        }
        return "W8A16"
    }

    private static func isUsableModelFolder(_ folder: URL) -> Bool {
        let hasSegmenter = ["W32A32", "W8A16"].contains { variant in
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(
                    "speaker_segmenter/pyannote-v3/\(variant)/SpeakerSegmenter.mlmodelc"
                ).path
            )
        }
        let requiredPaths = [
            "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc",
            "speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc",
            "speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc"
        ]
        return hasSegmenter && requiredPaths.allSatisfy {
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
