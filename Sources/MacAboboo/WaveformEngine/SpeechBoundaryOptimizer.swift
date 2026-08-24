import Foundation

/// 将词级时间戳、标点、停顿、说话人变化和 Silero 边界放入同一个全局评分模型。
public final class SpeechBoundaryOptimizer: @unchecked Sendable {
    public static let shared = SpeechBoundaryOptimizer()

    public init() {}

    /// Attach an already-produced Whisper transcript to existing acoustic
    /// ranges without changing those ranges. Kept for import/legacy callers;
    /// the main pipeline now performs local semantic/acoustic fusion directly.
    public func attachingRecognizedText(
        to segments: [SentenceSegment],
        from timeline: SpeechRecognitionTimeline
    ) -> [SentenceSegment] {
        segments.map { segment in
            var copy = segment
            let matchingTokens = timeline.tokens.filter {
                $0.endTime > segment.startTime && $0.startTime < segment.endTime
            }
            if !matchingTokens.isEmpty {
                copy.text = joinTokenText(matchingTokens)
            }
            return copy
        }
    }

    public func optimize(
        mode: SpeechSegmentationMode,
        timeline: SpeechRecognitionTimeline?,
        voiceSegments: [VoiceActivitySegment],
        waveform: WaveformData,
        duration: Double,
        includeRecognizedText: Bool,
        speakerSegments: [SpeakerDiarizationSegment] = []
    ) -> [SentenceSegment] {
        let safeDuration = duration.isFinite ? max(0, duration) : 0
        guard safeDuration > 0 else { return [] }
        var profile = mode.profile
        // When there is no speaker diarization signal (single-speaker content such
        // as lectures, audiobooks, or monologues), the speakerWeight contributes
        // nothing. Compensate by raising pauseWeight and semanticWeight so that
        // natural pauses and punctuation can still win over splitPenalty.
        if speakerSegments.isEmpty, mode.requiresTranscription {
            profile.pauseWeight    = max(profile.pauseWeight,    1.20)
            profile.semanticWeight = max(profile.semanticWeight, 1.40)
        }
        let normalizedVoice = smoothOnsetEdges(
            normalizeVoiceSegments(voiceSegments, duration: safeDuration),
            waveform: waveform
        )
        let normalizedSpeakers = normalizeSpeakerSegments(speakerSegments, duration: safeDuration)
        let acousticSegments = optimizeVoiceActivity(
            voiceSegments: normalizedVoice,
            waveform: waveform,
            profile: profile,
            duration: safeDuration,
            speakerSegments: normalizedSpeakers
        )

        if mode.requiresTranscription,
           let timeline,
           !timeline.tokens.isEmpty {
            let result = optimizeSemanticTimeline(
                tokens: timeline.tokens,
                // The caller-provided VAD is the authoritative acoustic
                // timeline. Whisper may expose its own internal VAD windows,
                // but those windows are model chunks rather than reliable
                // sentence boundaries for noisy multi-speaker recordings.
                voiceSegments: normalizedVoice,
                speakerSegments: normalizedSpeakers.isEmpty
                    ? normalizeSpeakerSegments(timeline.speakerSegments, duration: safeDuration)
                    : normalizedSpeakers,
                acousticSegments: acousticSegments,
                profile: profile,
                duration: safeDuration,
                includeRecognizedText: includeRecognizedText
            )
            if !result.isEmpty { return result }
        }

        return acousticSegments
    }

    // MARK: - Semantic + acoustic local fusion

    private struct BoundaryCandidate {
        var tokenEndIndex: Int
        var time: Double
        var semanticStrength: Double
        var pauseStrength: Double
        var acousticStrength: Double
        var speakerStrength: Double
        var isHardSpeakerBoundary: Bool
        var isNaturalBoundary: Bool
        var isAcousticAnchor: Bool
        var isFinal: Bool
    }

    private func optimizeSemanticTimeline(
        tokens inputTokens: [SpeechToken],
        voiceSegments: [VoiceActivitySegment],
        speakerSegments: [SpeakerDiarizationSegment],
        acousticSegments: [SentenceSegment],
        profile: SpeechSegmentationProfile,
        duration: Double,
        includeRecognizedText: Bool
    ) -> [SentenceSegment] {
        guard !acousticSegments.isEmpty else { return [] }
        let constrainedTokens = constrainTokensToSpeech(
            sanitizeTokens(inputTokens, duration: duration),
            acousticSegments: acousticSegments
        )
        let tokens = assignSpeakerMetadata(
            to: constrainedTokens,
            speakerSegments: speakerSegments
        )
        guard !tokens.isEmpty else { return [] }
        let candidates = makeCandidates(
            tokens: tokens,
            voiceSegments: voiceSegments,
            acousticSegments: acousticSegments,
            speakerSegments: speakerSegments,
            profile: profile
        )
        guard candidates.count == tokens.count + 1 else { return [] }

        let count = tokens.count
        let negativeInfinity = -Double.greatestFiniteMagnitude
        var scores = [Double](repeating: negativeInfinity, count: count + 1)
        var previous = [Int](repeating: -1, count: count + 1)
        scores[0] = 0

        // A reliable change from one speaker to another is a hard boundary.
        // Prefix sums keep the dynamic-programming loop O(n²) while preventing
        // a candidate sentence from swallowing a speaker transition.
        var hardBoundaryPrefix = [Int](repeating: 0, count: candidates.count + 1)
        for index in candidates.indices {
            hardBoundaryPrefix[index + 1] = hardBoundaryPrefix[index]
                + (candidates[index].isHardSpeakerBoundary ? 1 : 0)
        }

        // Token confidence is not a boundary by itself, but it should reduce
        // the score of a range made mostly from uncertain Whisper output. This
        // helps reject short hallucinated bursts in music/noise without
        // hard-dropping valid low-volume words.
        var confidencePrefix = [Double](repeating: 0, count: count + 1)
        for index in tokens.indices {
            confidencePrefix[index + 1] = confidencePrefix[index]
                + Double(tokens[index].confidence)
        }

        for endIndex in 1...count {
            let endToken = tokens[endIndex - 1]
            for startIndex in stride(from: endIndex - 1, through: 0, by: -1) {
                guard scores[startIndex] > negativeInfinity / 2 else { continue }
                if endIndex - startIndex > 1 {
                    let internalHardBoundaries = hardBoundaryPrefix[endIndex]
                        - hardBoundaryPrefix[startIndex + 1]
                    if internalHardBoundaries > 0 { continue }
                }
                let startToken = tokens[startIndex]
                let speechDuration = max(0.01, endToken.endTime - startToken.startTime)
                if speechDuration > profile.maximumSentenceDuration,
                   endIndex - startIndex > 1 {
                    // Tokens are time-sorted, so moving `startIndex` further
                    // left can only make the range longer. Stop this inner
                    // loop instead of scanning the entire transcript for
                    // every end token (important for long recordings).
                    break
                }

                var score = scores[startIndex]
                score += durationScore(
                    speechDuration,
                    tokenCount: endIndex - startIndex,
                    profile: profile,
                    isFirst: startIndex == 0,
                    isFinal: endIndex == count
                )
                let tokenCount = endIndex - startIndex
                let averageConfidence = (confidencePrefix[endIndex] - confidencePrefix[startIndex])
                    / Double(max(1, tokenCount))
                score += (averageConfidence - 0.5) * 0.35
                if averageConfidence < 0.20, tokenCount <= 2, !isLikelyPunctuationOnly(tokens[startIndex..<endIndex]) {
                    score -= 0.80
                }
                if endIndex < count {
                    let candidate = candidates[endIndex]
                    score += candidate.semanticStrength * profile.semanticWeight
                    score += candidate.pauseStrength * profile.pauseWeight
                    score += candidate.acousticStrength * profile.acousticWeight
                    score += candidate.speakerStrength * profile.speakerWeight
                    score -= profile.splitPenalty
                    if !candidate.isNaturalBoundary {
                        // Do not let a token/window boundary win merely
                        // because the transcript happens to contain many
                        // short tokens. A split needs punctuation, a real
                        // pause/acoustic edge, or an exclusive speaker turn.
                        score -= profile.splitPenalty * 1.8
                    }
                    if speechDuration < profile.minimumSentenceDuration,
                       !candidate.isNaturalBoundary {
                        score -= 2.2
                    }
                }

                if score > scores[endIndex] {
                    scores[endIndex] = score
                    previous[endIndex] = startIndex
                }
            }
        }

        let ranges = recoverTokenRanges(previous: previous, tokenCount: count)
        guard !ranges.isEmpty else { return [] }

        var segments: [SentenceSegment] = []
        var internalBoundaries: [Double] = []
        var naturalBoundaries: [Bool] = []
        segments.reserveCapacity(ranges.count)
        internalBoundaries.reserveCapacity(max(0, ranges.count - 1))
        naturalBoundaries.reserveCapacity(ranges.count)

        for (rangeIndex, range) in ranges.enumerated() {
            let first = tokens[range.lowerBound]
            let last = tokens[range.upperBound - 1]
            let start = calibratedStart(
                speechStart: first.startTime,
                voiceSegments: voiceSegments,
                profile: profile,
                duration: duration
            )
            let end = calibratedEnd(
                speechEnd: last.endTime,
                voiceSegments: voiceSegments,
                profile: profile,
                duration: duration
            )
            let text = includeRecognizedText ? joinTokenText(Array(tokens[range])) : ""
            let speakerIDs = Array(Set(tokens[range].flatMap(\.speakerIDs))).sorted()
            let speakerOverlap = !speakerOverlapIDs(
                in: first.startTime...last.endTime,
                speakerSegments: speakerSegments
            ).isEmpty || tokens[range].contains { $0.speakerOverlap }
            segments.append(SentenceSegment(
                index: rangeIndex + 1,
                startTime: start,
                endTime: max(start + 0.05, end),
                text: text,
                translation: "",
                speakerID: speakerIDs.count == 1 ? speakerIDs[0] : nil,
                speakerIDs: speakerIDs,
                isSpeakerOverlap: speakerOverlap
            ))
            naturalBoundaries.append(
                range.upperBound == count || candidates[range.upperBound].isNaturalBoundary
            )
            if range.upperBound < count {
                internalBoundaries.append(candidates[range.upperBound].time)
            }
        }

        resolveSemanticBoundaries(
            segments: &segments,
            desiredBoundaries: internalBoundaries,
            duration: duration
        )
        enforceSemanticMinimumDuration(
            segments: &segments,
            naturalBoundaries: &naturalBoundaries,
            profile: profile
        )
        enforceMaximumDuration(
            segments: &segments,
            maximum: profile.maximumSentenceDuration,
            duration: duration
        )
        return reindexed(segments)
    }

    /// Whisper can emit very short token groups around a noisy turn. Keep a
    /// short segment when punctuation, an overlap, or a real speaker turn
    /// justifies it; otherwise merge it with the adjacent segment belonging to
    /// the same speaker. This makes the profile minimum a practical lower
    /// bound instead of a soft DP preference that padding can undo later.
    private func enforceSemanticMinimumDuration(
        segments: inout [SentenceSegment],
        naturalBoundaries: inout [Bool],
        profile: SpeechSegmentationProfile
    ) {
        guard segments.count > 1, profile.minimumSentenceDuration > 0 else { return }
        guard naturalBoundaries.count == segments.count else { return }

        func sameSpeaker(_ left: SentenceSegment, _ right: SentenceSegment) -> Bool {
            if left.isSpeakerOverlap || right.isSpeakerOverlap { return false }
            if left.speakerIDs.isEmpty && right.speakerIDs.isEmpty { return true }
            return left.speakerIDs == right.speakerIDs
        }

        func canMerge(_ left: SentenceSegment, _ right: SentenceSegment) -> Bool {
            sameSpeaker(left, right)
                && left.endTime - left.startTime + right.endTime - right.startTime
                    <= profile.maximumSentenceDuration + 0.001
        }

        func mergedText(_ left: String, _ right: String) -> String {
            let lhs = left.trimmingCharacters(in: .whitespacesAndNewlines)
            let rhs = right.trimmingCharacters(in: .whitespacesAndNewlines)
            if lhs.isEmpty { return rhs }
            if rhs.isEmpty { return lhs }
            return "\(lhs) \(rhs)"
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var index = 0
        while index < segments.count {
            let short = segments[index]
            guard short.duration + 0.001 < profile.minimumSentenceDuration else {
                index += 1
                continue
            }
            if naturalBoundaries[index] || short.isSpeakerOverlap || short.speakerIDs.count > 1 {
                index += 1
                continue
            }

            let previous = index > 0 ? segments[index - 1] : nil
            let next = index + 1 < segments.count ? segments[index + 1] : nil
            let canMergePrevious = previous.map { canMerge($0, short) } ?? false
            let canMergeNext = next.map { canMerge(short, $0) } ?? false

            if canMergePrevious && canMergeNext {
                let previousDistance = abs((previous?.duration ?? 0) + short.duration - profile.preferredSentenceDuration)
                let nextDistance = abs(short.duration + (next?.duration ?? 0) - profile.preferredSentenceDuration)
                if previousDistance <= nextDistance {
                    segments[index - 1].endTime = short.endTime
                    segments[index - 1].text = mergedText(segments[index - 1].text, short.text)
                    segments[index - 1].isSpeakerOverlap = segments[index - 1].isSpeakerOverlap || short.isSpeakerOverlap
                    naturalBoundaries[index - 1] = naturalBoundaries[index - 1] || naturalBoundaries[index]
                    segments.remove(at: index)
                    naturalBoundaries.remove(at: index)
                } else {
                    segments[index + 1].startTime = short.startTime
                    segments[index + 1].text = mergedText(short.text, segments[index + 1].text)
                    segments[index + 1].isSpeakerOverlap = segments[index + 1].isSpeakerOverlap || short.isSpeakerOverlap
                    naturalBoundaries[index + 1] = naturalBoundaries[index + 1] || naturalBoundaries[index]
                    segments.remove(at: index)
                    naturalBoundaries.remove(at: index)
                }
                continue
            }
            if canMergePrevious {
                segments[index - 1].endTime = short.endTime
                segments[index - 1].text = mergedText(segments[index - 1].text, short.text)
                segments[index - 1].isSpeakerOverlap = segments[index - 1].isSpeakerOverlap || short.isSpeakerOverlap
                naturalBoundaries[index - 1] = naturalBoundaries[index - 1] || naturalBoundaries[index]
                segments.remove(at: index)
                naturalBoundaries.remove(at: index)
                continue
            }
            if canMergeNext {
                segments[index + 1].startTime = short.startTime
                segments[index + 1].text = mergedText(short.text, segments[index + 1].text)
                segments[index + 1].isSpeakerOverlap = segments[index + 1].isSpeakerOverlap || short.isSpeakerOverlap
                naturalBoundaries[index + 1] = naturalBoundaries[index + 1] || naturalBoundaries[index]
                segments.remove(at: index)
                naturalBoundaries.remove(at: index)
                continue
            }
            index += 1
        }
    }

    /// Keep Whisper tokens inside externally detected speech and attenuate
    /// tokens that only graze an acoustic interval. This is a local guard
    /// against hallucinated words in music/silence; it does not discard a
    /// complete transcript when a few windows are uncertain.
    private func constrainTokensToSpeech(
        _ tokens: [SpeechToken],
        acousticSegments: [SentenceSegment]
    ) -> [SpeechToken] {
        guard !tokens.isEmpty, !acousticSegments.isEmpty else { return [] }
        var result: [SpeechToken] = []
        result.reserveCapacity(tokens.count)
        for token in tokens {
            let duration = max(0.01, token.endTime - token.startTime)
            let overlap = acousticSegments.map {
                max(0, min(token.endTime, $0.endTime) - max(token.startTime, $0.startTime))
            }.max() ?? 0
            let midpoint = (token.startTime + token.endTime) / 2
            let midpointInside = acousticSegments.contains {
                midpoint >= $0.startTime - 0.04 && midpoint <= $0.endTime + 0.04
            }
            let nearestBoundaryDistance = acousticSegments
                .flatMap { [abs($0.startTime - token.startTime), abs($0.endTime - token.endTime)] }
                .min() ?? .greatestFiniteMagnitude

            var copy = token
            if overlap >= max(0.025, duration * 0.20) || midpointInside {
                result.append(copy)
                continue
            }
            if overlap > 0.01 || nearestBoundaryDistance <= 0.12 {
                let coverage = min(1, max(overlap / duration, 0.18))
                copy.confidence *= Float(coverage)
                result.append(copy)
            }
        }
        return result
    }

    private func sanitizeTokens(_ tokens: [SpeechToken], duration: Double) -> [SpeechToken] {
        let sorted = tokens
            .filter { token in
                let trimmed = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty
                    && !trimmed.hasPrefix("<|")
                    && token.startTime.isFinite
                    && token.endTime.isFinite
                    && token.endTime >= token.startTime
                    && token.startTime < duration
            }
            .map { token in
                var copy = token
                copy.startTime = min(duration, max(0, copy.startTime))
                copy.endTime = min(duration, max(copy.startTime + 0.01, copy.endTime))
                return copy
            }
            .sorted {
                if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
                return $0.startTime < $1.startTime
            }

        // Whisper can occasionally emit the same token twice with nearly
        // identical timestamps when the input contains a loud transient. Keep
        // the more confident copy, but never collapse legitimate repeated words
        // that have distinct time ranges.
        var deduplicated: [SpeechToken] = []
        deduplicated.reserveCapacity(sorted.count)
        for token in sorted {
            if let lastIndex = deduplicated.indices.last {
                let last = deduplicated[lastIndex]
                let overlap = max(0, min(last.endTime, token.endTime) - max(last.startTime, token.startTime))
                let shorterDuration = max(0.01, min(last.endTime - last.startTime, token.endTime - token.startTime))
                let sameText = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(token.text.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
                if sameText, overlap / shorterDuration >= 0.65 {
                    if token.confidence > last.confidence {
                        deduplicated[lastIndex] = token
                    }
                    continue
                }
            }
            deduplicated.append(token)
        }
        return deduplicated
    }

    private func makeCandidates(
        tokens: [SpeechToken],
        voiceSegments: [VoiceActivitySegment],
        acousticSegments: [SentenceSegment],
        speakerSegments: [SpeakerDiarizationSegment],
        profile: SpeechSegmentationProfile
    ) -> [BoundaryCandidate] {
        var result: [BoundaryCandidate] = []
        result.reserveCapacity(tokens.count + 1)
        result.append(BoundaryCandidate(
            tokenEndIndex: 0,
            time: tokens[0].startTime,
            semanticStrength: 0,
            pauseStrength: 0,
            acousticStrength: 0,
            speakerStrength: 0,
            isHardSpeakerBoundary: false,
            isNaturalBoundary: false,
            isAcousticAnchor: false,
            isFinal: false
        ))

        for index in tokens.indices {
            let token = tokens[index]
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil
            let gap = next.map { max(0, $0.startTime - token.endTime) } ?? 0
            let time = next.map { gap >= 0.04 ? (token.endTime + $0.startTime) / 2 : token.endTime }
                ?? token.endTime
            let localConfidence = min(1.0, max(0.0, Double(token.confidence)))
            let semantic = punctuationStrength(in: token.text) * localConfidence
            let segmentTransition = next.map { $0.recognitionSegmentIndex != token.recognitionSegmentIndex } ?? false
            let pause = min(1.25, gap / max(0.12, profile.vad.minSilenceDuration))
            let acousticVoiceStrength = acousticBoundaryStrength(
                time: time,
                currentEnd: token.endTime,
                nextStart: next?.startTime,
                voiceSegments: voiceSegments,
                snapWindow: profile.snapWindow
            )
            let acousticAnchorStrength = acousticSentenceBoundaryStrength(
                time: time,
                acousticSegments: acousticSegments,
                snapWindow: profile.snapWindow
            )
            let acoustic = max(acousticVoiceStrength * 0.65, acousticAnchorStrength)
            let currentSpeakerIDs = Set(token.speakerIDs)
            let nextSpeakerIDs = Set(next?.speakerIDs ?? [])
            let speakerChanged = !currentSpeakerIDs.isEmpty
                && !nextSpeakerIDs.isEmpty
                && currentSpeakerIDs.isDisjoint(with: nextSpeakerIDs)
            let reliableSpeakerChange = speakerChanged
                && !token.speakerOverlap
                && !(next?.speakerOverlap ?? false)
                && token.speakerConfidence >= 0.35
                && (next?.speakerConfidence ?? 0) >= 0.35
            // A diarization change inside an overlap is useful context, but it
            // is not a safe place to force a subtitle split. Treat it as a
            // weak signal and reserve the full score for an exclusive turn.
            let exclusiveSpeakerChange = !token.speakerOverlap
                && !(next?.speakerOverlap ?? false)
            let speakerStrength: Double =
                (token.speakerTurnAfter || speakerChanged)
                    ? (exclusiveSpeakerChange ? 1 : 0.28)
                    : 0
            // Whisper's recognition segment index often changes at an
            // inference-window boundary. Only retain a small semantic hint
            // when that change is corroborated by an actual pause or acoustic
            // boundary; otherwise it must not compete with punctuation/VAD.
            let segmentTransitionStrength = segmentTransition
                && (pause >= 0.35 || acoustic >= 0.60)
                ? 0.05 * localConfidence
                : 0
            let semanticStrength = max(
                semantic,
                segmentTransitionStrength
            )
            let isAcousticAnchor = acousticAnchorStrength >= 0.55
            let isNaturalBoundary = semantic >= 0.32
                || pause >= 0.35
                || acoustic >= 0.55
                || speakerStrength >= 0.75
            result.append(BoundaryCandidate(
                tokenEndIndex: index + 1,
                time: time,
                semanticStrength: semanticStrength,
                pauseStrength: pause,
                acousticStrength: acoustic,
                speakerStrength: speakerStrength,
                isHardSpeakerBoundary: reliableSpeakerChange,
                isNaturalBoundary: isNaturalBoundary,
                isAcousticAnchor: isAcousticAnchor,
                isFinal: index == tokens.count - 1
            ))
        }
        return result
    }

    private func punctuationStrength(in text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return 0 }
        if ".?!。？！…؟｡．".contains(last) { return 1 }
        if ";:；：".contains(last) { return 0.62 }
        if ",，、".contains(last) { return 0.36 }
        return 0
    }

    private func isLikelyPunctuationOnly(_ tokens: ArraySlice<SpeechToken>) -> Bool {
        let text = tokens
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined()
        guard !text.isEmpty else { return false }
        return text.allSatisfy { character in
            character.isPunctuation || character.isWhitespace || character.isSymbol
        }
    }

    private func acousticBoundaryStrength(
        time: Double,
        currentEnd: Double,
        nextStart: Double?,
        voiceSegments: [VoiceActivitySegment],
        snapWindow: Double
    ) -> Double {
        guard !voiceSegments.isEmpty, snapWindow > 0 else { return 0 }
        let nearestEndDistance = voiceSegments.map { abs($0.endTime - currentEnd) }.min() ?? .greatestFiniteMagnitude
        let nearestStartDistance = nextStart.map { start in
            voiceSegments.map { abs($0.startTime - start) }.min() ?? .greatestFiniteMagnitude
        } ?? .greatestFiniteMagnitude
        let nearestBoundaryDistance = voiceSegments.flatMap { [abs($0.startTime - time), abs($0.endTime - time)] }.min()
            ?? .greatestFiniteMagnitude
        let distance = min(nearestEndDistance, nearestStartDistance, nearestBoundaryDistance)
        return max(0, 1 - distance / snapWindow)
    }

    /// Sentence ranges produced by the acoustic path are low-energy anchors,
    /// not mandatory cuts. A Whisper boundary close to one of these anchors
    /// receives a strong local score; this lets reliable semantic punctuation
    /// move a boundary inside a long voice interval without allowing noisy
    /// token/window transitions to ignore the acoustic structure completely.
    private func acousticSentenceBoundaryStrength(
        time: Double,
        acousticSegments: [SentenceSegment],
        snapWindow: Double
    ) -> Double {
        guard !acousticSegments.isEmpty, snapWindow > 0 else { return 0 }
        let distance = acousticSegments
            .dropFirst()
            .map { abs($0.startTime - time) }
            .min() ?? .greatestFiniteMagnitude
        guard distance.isFinite else { return 0 }
        return max(0, 1 - distance / max(0.12, snapWindow))
    }

    private func durationScore(
        _ duration: Double,
        tokenCount: Int,
        profile: SpeechSegmentationProfile,
        isFirst: Bool,
        isFinal: Bool
    ) -> Double {
        var score = -0.16 * abs(duration - profile.preferredSentenceDuration)
            / max(0.5, profile.preferredSentenceDuration)
        if duration < profile.minimumSentenceDuration {
            let ratio = (profile.minimumSentenceDuration - duration) / profile.minimumSentenceDuration
            score -= (isFirst || isFinal ? 1.2 : 2.8) * ratio
        }
        if duration > profile.maximumSentenceDuration {
            let ratio = (duration - profile.maximumSentenceDuration) / profile.maximumSentenceDuration
            score -= 8 + ratio * 12
        } else if duration > profile.maximumSentenceDuration * 0.82 {
            score -= (duration / profile.maximumSentenceDuration - 0.82) * 1.2
        }
        if tokenCount == 1 && duration < 0.30 && !isFinal { score -= 1.4 }
        return score
    }

    private func recoverTokenRanges(previous: [Int], tokenCount: Int) -> [Range<Int>] {
        guard tokenCount > 0, previous.indices.contains(tokenCount), previous[tokenCount] >= 0 else { return [] }
        var reversed: [Range<Int>] = []
        var end = tokenCount
        var safety = tokenCount + 1
        while end > 0, safety > 0 {
            let start = previous[end]
            guard start >= 0, start < end else { return [] }
            reversed.append(start..<end)
            end = start
            safety -= 1
        }
        guard end == 0 else { return [] }
        return reversed.reversed()
    }

    private func calibratedStart(
        speechStart: Double,
        voiceSegments: [VoiceActivitySegment],
        profile: SpeechSegmentationProfile,
        duration: Double
    ) -> Double {
        let candidate = voiceSegments
            .filter { $0.startTime <= speechStart + 0.08 && abs($0.startTime - speechStart) <= profile.snapWindow }
            .min { abs($0.startTime - speechStart) < abs($1.startTime - speechStart) }
        return min(duration, max(0, candidate?.startTime ?? speechStart - profile.onsetPadding))
    }

    private func calibratedEnd(
        speechEnd: Double,
        voiceSegments: [VoiceActivitySegment],
        profile: SpeechSegmentationProfile,
        duration: Double
    ) -> Double {
        let candidate = voiceSegments
            .filter { $0.endTime >= speechEnd - 0.08 && abs($0.endTime - speechEnd) <= profile.snapWindow }
            .min { abs($0.endTime - speechEnd) < abs($1.endTime - speechEnd) }
        return min(duration, max(0, candidate?.endTime ?? speechEnd + profile.offsetPadding))
    }

    private func resolveSemanticBoundaries(
        segments: inout [SentenceSegment],
        desiredBoundaries: [Double],
        duration: Double
    ) {
        guard segments.count > 1 else {
            if !segments.isEmpty { segments[0].endTime = min(duration, segments[0].endTime) }
            return
        }
        for index in 0..<(segments.count - 1) {
            let leftMinimum = segments[index].startTime + 0.05
            let rightMaximum = segments[index + 1].endTime - 0.05
            let desired = desiredBoundaries.indices.contains(index)
                ? desiredBoundaries[index]
                : (segments[index].endTime + segments[index + 1].startTime) / 2
            let boundary = min(rightMaximum, max(leftMinimum, desired))
            if segments[index].endTime > segments[index + 1].startTime {
                segments[index].endTime = boundary
                segments[index + 1].startTime = boundary
            } else {
                segments[index].endTime = min(segments[index].endTime, boundary)
                segments[index + 1].startTime = max(segments[index + 1].startTime, boundary)
            }
        }
        segments[segments.count - 1].endTime = min(duration, segments[segments.count - 1].endTime)
    }

    /// Apply the profile's maximum after all padding and boundary calibration.
    /// The DP already prefers legal token ranges; this final pass protects the
    /// public result from padding, timestamp anomalies, and overlap repair.
    private func enforceMaximumDuration(
        segments: inout [SentenceSegment],
        maximum: Double,
        duration: Double
    ) {
        guard maximum.isFinite, maximum > 0, duration > 0 else { return }
        let minimumSpan = min(0.05, maximum)
        var previousEnd = 0.0
        for index in segments.indices {
            let start = min(duration, max(previousEnd, max(0, segments[index].startTime)))
            let requestedEnd = min(duration, max(start + minimumSpan, segments[index].endTime))
            let end = min(requestedEnd, start + maximum)
            guard end > start else {
                segments[index].startTime = start
                segments[index].endTime = min(duration, start + minimumSpan)
                previousEnd = segments[index].endTime
                continue
            }
            segments[index].startTime = start
            segments[index].endTime = end
            previousEnd = end
        }
        segments.removeAll { $0.endTime - $0.startTime < minimumSpan }
    }

    /// Return the identities that are active simultaneously inside a range.
    /// Merely seeing two IDs over time is a turn change, not overlap.
    private func speakerOverlapIDs(
        in range: ClosedRange<Double>,
        speakerSegments: [SpeakerDiarizationSegment]
    ) -> Set<Int> {
        let lower = range.lowerBound
        let upper = range.upperBound
        guard upper - lower >= 0.02, !speakerSegments.isEmpty else { return [] }

        var points = [lower, upper]
        for segment in speakerSegments where segment.endTime > lower && segment.startTime < upper {
            points.append(max(lower, segment.startTime))
            points.append(min(upper, segment.endTime))
        }
        let sortedPoints = Array(Set(points)).sorted()
        guard sortedPoints.count >= 2 else { return [] }

        var overlapIDs = Set<Int>()
        for (left, right) in zip(sortedPoints, sortedPoints.dropFirst()) {
            guard right - left >= 0.02 else { continue }
            let midpoint = (left + right) / 2
            let activeIDs = Set(speakerSegments
                .filter { midpoint >= $0.startTime && midpoint < $0.endTime }
                .flatMap(\.speakerIDs))
            if activeIDs.count > 1 {
                overlapIDs.formUnion(activeIDs)
            }
        }
        return overlapIDs
    }

    // MARK: - VAD-only optimization

    private func optimizeVoiceActivity(
        voiceSegments: [VoiceActivitySegment],
        waveform: WaveformData,
        profile: SpeechSegmentationProfile,
        duration: Double,
        speakerSegments: [SpeakerDiarizationSegment]
    ) -> [SentenceSegment] {
        // SpeakerKit can recover speech that Silero misses under heavy noise.
        // Use its coverage as a fallback (and union it with VAD coverage when
        // both are available) instead of returning an empty timeline.
        let effectiveVoiceSegments: [VoiceActivitySegment]
        if speakerSegments.isEmpty {
            effectiveVoiceSegments = voiceSegments
        } else {
            let waveformBaseline = waveformNoiseFloor(waveform)
            let speakerCoverage = speakerCoverageSegments(
                speakerSegments: speakerSegments,
                voiceSegments: voiceSegments,
                waveform: waveform,
                waveformBaseline: waveformBaseline
            ).map {
                VoiceActivitySegment(startTime: $0.startTime, endTime: $0.endTime, confidence: $0.confidence)
            }
            effectiveVoiceSegments = mergeOverlappingVoiceSegments(voiceSegments + speakerCoverage)
        }
        guard !effectiveVoiceSegments.isEmpty else { return [] }
        // Once diarization is available, do not merge across a short VAD gap:
        // it may be the only observable turn boundary in noisy dialogue.
        let merged = speakerSegments.isEmpty
            ? mergeVoiceSegments(effectiveVoiceSegments, profile: profile)
            : effectiveVoiceSegments
        var ranges: [(start: Double, end: Double)] = []
        for segment in merged {
            let baseRanges = speakerSegments.isEmpty
                ? [(start: segment.startTime, end: segment.endTime)]
                : speakerAwareVoiceRanges(
                    start: segment.startTime,
                    end: segment.endTime,
                    speakerSegments: speakerSegments,
                    mergeGap: profile.mergeGap
                )
            for range in baseRanges {
                ranges.append(contentsOf: splitLongVoiceSegment(
                    start: range.start,
                    end: range.end,
                    waveform: waveform,
                    profile: profile
                ))
            }
        }
        if speakerSegments.isEmpty {
            ranges = mergeShortVoiceRanges(ranges, profile: profile)
        } else {
            // SpeakerKit can produce very short identity flickers around a
            // noisy turn. Preserve genuine brief interjections, but do not
            // expose sub-80ms diarization jitter as a subtitle range.
            ranges = stabilizeSpeakerRanges(ranges, minimumDuration: 0.08)
        }
        resolveRangeOverlaps(&ranges)
        ranges = ranges.flatMap {
            splitLongVoiceSegment(
                start: $0.start,
                end: $0.end,
                waveform: waveform,
                profile: profile
            )
        }

        return ranges.enumerated().compactMap { index, range in
            let start = min(duration, max(0, range.start))
            let end = min(duration, max(start, range.end))
            guard end - start >= 0.05 else { return nil }
            let metadata = speakerMetadata(
                start: start,
                end: end,
                speakerSegments: speakerSegments
            )
            return SentenceSegment(
                index: index + 1,
                startTime: start,
                endTime: end,
                speakerID: metadata.ids.count == 1 ? metadata.ids[0] : nil,
                speakerIDs: metadata.ids,
                isSpeakerOverlap: metadata.isOverlap
            )
        }
    }

    private func speakerCoverageSegments(
        speakerSegments: [SpeakerDiarizationSegment],
        voiceSegments: [VoiceActivitySegment],
        waveform: WaveformData,
        waveformBaseline: Float
    ) -> [SpeakerDiarizationSegment] {
        guard !voiceSegments.isEmpty else {
            // SpeakerKit is the only available speech evidence in this case.
            // Keep it when no waveform is available (the synthetic/test and
            // imported-timeline path), otherwise still require a conservative
            // acoustic gate so music-only false positives do not become text
            // ranges merely because Silero returned no intervals.
            guard !waveform.isEmpty else { return speakerSegments }
            return speakerSegments.filter {
                hasAcousticSupport(
                    start: $0.startTime,
                    end: $0.endTime,
                    waveform: waveform,
                    baseline: waveformBaseline
                )
            }
        }
        return speakerSegments.filter { speaker in
            let overlap = voiceSegments.map {
                max(0, min(speaker.endTime, $0.endTime) - max(speaker.startTime, $0.startTime))
            }.max() ?? 0
            return overlap >= 0.05 || hasAcousticSupport(
                start: speaker.startTime,
                end: speaker.endTime,
                waveform: waveform,
                baseline: waveformBaseline
            )
        }
    }

    private func waveformNoiseFloor(_ waveform: WaveformData) -> Float {
        guard !waveform.isEmpty else { return 0 }
        // A long recording can contain hundreds of thousands of waveform bins.
        // A bounded evenly-spaced sample gives the same robust lower percentile
        // without sorting the full array once per SpeakerKit interval.
        let stride = max(1, waveform.peaks.count / 20_000)
        var samples: [Float] = []
        samples.reserveCapacity((waveform.peaks.count + stride - 1) / stride)
        for index in Swift.stride(from: 0, to: waveform.peaks.count, by: stride) {
            samples.append(waveform.peaks[index])
        }
        samples.sort()
        return samples[min(samples.count - 1, Int(Double(samples.count) * 0.10))]
    }

    private func hasAcousticSupport(
        start: Double,
        end: Double,
        waveform: WaveformData,
        baseline: Float
    ) -> Bool {
        guard !waveform.isEmpty, end > start, waveform.sampleRate > 0 else { return false }
        let lower = max(0, min(start, waveform.duration))
        let upper = max(lower, min(end, waveform.duration))
        let startIndex = max(0, Int(lower * waveform.sampleRate))
        let endIndex = min(waveform.peaks.count, max(startIndex + 1, Int(ceil(upper * waveform.sampleRate))))
        guard endIndex > startIndex else { return false }

        let segmentPeaks = waveform.peaks[startIndex..<endIndex]
        let sum = segmentPeaks.reduce(0, +)
        let mean = sum / Float(segmentPeaks.count)
        let peak = segmentPeaks.max() ?? 0
        // Keep the threshold deliberately conservative: this is only a gate
        // for SpeakerKit's recovery coverage, not a replacement for Silero.
        if baseline >= 0.05 {
            return mean >= baseline * 0.70
        }
        return mean >= max(0.008, baseline + 0.005)
            && peak >= max(0.02, baseline + 0.01)
    }

    /// Split a VAD interval at every diarization boundary while preserving
    /// overlap intervals. The returned ranges are non-overlapping and retain
    /// even very short speaker turns instead of merging them away.
    private func speakerAwareVoiceRanges(
        start: Double,
        end: Double,
        speakerSegments: [SpeakerDiarizationSegment],
        mergeGap: Double
    ) -> [(start: Double, end: Double)] {
        guard end - start >= 0.02 else { return [] }
        var breakpoints = [start, end]
        for speaker in speakerSegments where speaker.endTime > start && speaker.startTime < end {
            breakpoints.append(min(end, max(start, speaker.startTime)))
            breakpoints.append(min(end, max(start, speaker.endTime)))
        }
        let points = Array(Set(breakpoints)).sorted()
        guard points.count >= 2 else { return [(start, end)] }
        let rawRanges = zip(points, points.dropFirst()).compactMap { left, right -> (start: Double, end: Double, ids: [Int])? in
            guard right - left >= 0.02 else { return nil }
            let midpoint = (left + right) / 2
            return (left, right, activeSpeakerIDs(at: midpoint, in: speakerSegments))
        }
        guard !rawRanges.isEmpty else { return [] }
        var merged: [(start: Double, end: Double, ids: [Int])] = []
        for range in rawRanges {
            if let last = merged.last,
               last.ids == range.ids,
               range.start - last.end <= mergeGap {
                merged[merged.count - 1].end = range.end
            } else {
                merged.append(range)
            }
        }
        return merged.map { ($0.start, $0.end) }
    }

    private func stabilizeSpeakerRanges(
        _ input: [(start: Double, end: Double)],
        minimumDuration: Double
    ) -> [(start: Double, end: Double)] {
        guard input.count > 1, minimumDuration > 0 else { return input }
        var ranges = input
        var index = 0
        while index < ranges.count {
            guard ranges[index].end - ranges[index].start < minimumDuration else {
                index += 1
                continue
            }

            if index > 0, index + 1 < ranges.count {
                let previousDuration = ranges[index - 1].end - ranges[index - 1].start
                let nextDuration = ranges[index + 1].end - ranges[index + 1].start
                if previousDuration >= nextDuration {
                    ranges[index - 1].end = ranges[index].end
                } else {
                    ranges[index + 1].start = ranges[index].start
                }
                ranges.remove(at: index)
                continue
            }
            if index > 0 {
                ranges[index - 1].end = ranges[index].end
                ranges.remove(at: index)
                continue
            }
            if index + 1 < ranges.count {
                ranges[index + 1].start = ranges[index].start
                ranges.remove(at: index)
                continue
            }
            index += 1
        }
        return ranges
    }

    private func activeSpeakerIDs(
        at time: Double,
        in speakerSegments: [SpeakerDiarizationSegment]
    ) -> [Int] {
        Array(Set(speakerSegments
            .filter { time >= $0.startTime && time < $0.endTime }
            .flatMap(\.speakerIDs))).sorted()
    }

    private func normalizeSpeakerSegments(
        _ segments: [SpeakerDiarizationSegment],
        duration: Double
    ) -> [SpeakerDiarizationSegment] {
        let normalized: [SpeakerDiarizationSegment] = segments.compactMap { segment -> SpeakerDiarizationSegment? in
            let start = min(duration, max(0, segment.startTime))
            let end = min(duration, max(start, segment.endTime))
            let ids = Array(Set(segment.speakerIDs)).sorted()
            guard end - start >= 0.05, !ids.isEmpty else { return nil }
            return SpeakerDiarizationSegment(
                startTime: start,
                endTime: end,
                speakerIDs: ids,
                confidence: segment.confidence,
                isOverlap: ids.count > 1
            )
        }.sorted {
            if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
            return $0.startTime < $1.startTime
        }

        // Merge adjacent windows with the same identity set. This removes
        // frame-level churn while preserving true overlap intervals.
        var smoothed: [SpeakerDiarizationSegment] = []
        for segment in normalized {
            guard let last = smoothed.last else {
                smoothed.append(segment)
                continue
            }
            if last.speakerIDs == segment.speakerIDs,
               segment.startTime - last.endTime <= 0.08 {
                smoothed[smoothed.count - 1].endTime = max(last.endTime, segment.endTime)
                smoothed[smoothed.count - 1].confidence = max(last.confidence, segment.confidence)
                smoothed[smoothed.count - 1].isOverlap = last.isOverlap || segment.isOverlap
            } else {
                smoothed.append(segment)
            }
        }
        return smoothed
    }

    /// Assign speaker labels to Whisper tokens by time overlap, using a
    /// midpoint fallback for very small timestamp errors at turn edges.
    private func assignSpeakerMetadata(
        to tokens: [SpeechToken],
        speakerSegments: [SpeakerDiarizationSegment]
    ) -> [SpeechToken] {
        guard !speakerSegments.isEmpty else { return tokens }
        var result: [SpeechToken] = []
        result.reserveCapacity(tokens.count)
        var speakerCursor = 0
        var activeSpeakers: [SpeakerDiarizationSegment] = []

        for token in tokens {
            while speakerCursor < speakerSegments.count,
                  speakerSegments[speakerCursor].startTime < token.endTime {
                activeSpeakers.append(speakerSegments[speakerCursor])
                speakerCursor += 1
            }
            activeSpeakers.removeAll { $0.endTime <= token.startTime }

            var copy = token
            let tokenDuration = max(0.01, token.endTime - token.startTime)
            var overlapBySpeaker: [Int: Double] = [:]
            for speaker in activeSpeakers {
                let overlap = max(0, min(token.endTime, speaker.endTime) - max(token.startTime, speaker.startTime))
                guard overlap > 0 else { continue }
                let share = overlap / Double(max(1, speaker.speakerIDs.count))
                for id in speaker.speakerIDs {
                    overlapBySpeaker[id, default: 0] += share
                }
            }

            if overlapBySpeaker.isEmpty {
                let midpoint = (token.startTime + token.endTime) / 2
                if let speaker = activeSpeakers.first(where: { midpoint >= $0.startTime && midpoint < $0.endTime }) {
                    for id in speaker.speakerIDs {
                        overlapBySpeaker[id, default: 0] += tokenDuration / Double(max(1, speaker.speakerIDs.count))
                    }
                }
            }
            guard !overlapBySpeaker.isEmpty else {
                result.append(copy)
                continue
            }
            let maxOverlap = overlapBySpeaker.values.max() ?? 0
            let threshold = max(0.02, maxOverlap * 0.35)
            let ids = overlapBySpeaker
                .filter { $0.value >= threshold }
                .map(\.key)
                .sorted()
            copy.speakerIDs = ids
            copy.speakerConfidence = Float(min(1.0, maxOverlap / tokenDuration))
            copy.speakerOverlap = !speakerOverlapIDs(
                in: token.startTime...token.endTime,
                speakerSegments: activeSpeakers
            ).isEmpty
            result.append(copy)
        }
        return result
    }

    private func speakerMetadata(
        start: Double,
        end: Double,
        speakerSegments: [SpeakerDiarizationSegment]
    ) -> (ids: [Int], isOverlap: Bool) {
        guard end > start else { return ([], false) }
        var weights: [Int: Double] = [:]
        for speaker in speakerSegments {
            let intersection = max(0, min(end, speaker.endTime) - max(start, speaker.startTime))
            guard intersection > 0 else { continue }
            let share = intersection / Double(max(1, speaker.speakerIDs.count))
            for id in speaker.speakerIDs { weights[id, default: 0] += share }
        }
        let maximum = weights.values.max() ?? 0
        let ids = weights.filter { $0.value >= max(0.02, maximum * 0.35) }.map(\.key).sorted()
        let overlapIDs = speakerOverlapIDs(
            in: start...end,
            speakerSegments: speakerSegments
        )
        return (ids, !overlapIDs.isEmpty)
    }

    private func normalizeVoiceSegments(
        _ segments: [VoiceActivitySegment],
        duration: Double
    ) -> [VoiceActivitySegment] {
        segments.compactMap { segment in
            let start = min(duration, max(0, segment.startTime))
            let end = min(duration, max(start, segment.endTime))
            guard end - start >= 0.02 else { return nil }
            return VoiceActivitySegment(startTime: start, endTime: end, confidence: segment.confidence)
        }.sorted { $0.startTime < $1.startTime }
    }

    private func mergeOverlappingVoiceSegments(
        _ segments: [VoiceActivitySegment]
    ) -> [VoiceActivitySegment] {
        var result: [VoiceActivitySegment] = []
        for segment in segments.sorted(by: { $0.startTime < $1.startTime }) {
            guard let last = result.last else {
                result.append(segment)
                continue
            }
            if segment.startTime <= last.endTime + 0.02 {
                result[result.count - 1].endTime = max(last.endTime, segment.endTime)
                result[result.count - 1].confidence = max(last.confidence, segment.confidence)
            } else {
                result.append(segment)
            }
        }
        return result
    }

    private func mergeVoiceSegments(
        _ segments: [VoiceActivitySegment],
        profile: SpeechSegmentationProfile
    ) -> [VoiceActivitySegment] {
        var result: [VoiceActivitySegment] = []
        for segment in segments {
            guard let last = result.last else {
                result.append(segment)
                continue
            }
            let gap = segment.startTime - last.endTime
            let mergedDuration = max(last.endTime, segment.endTime) - last.startTime
            if gap <= profile.mergeGap && mergedDuration <= profile.maximumSentenceDuration {
                result[result.count - 1].endTime = max(last.endTime, segment.endTime)
                result[result.count - 1].confidence = max(last.confidence, segment.confidence)
            } else {
                result.append(segment)
            }
        }
        return result
    }

    private func splitLongVoiceSegment(
        start: Double,
        end: Double,
        waveform: WaveformData,
        profile: SpeechSegmentationProfile
    ) -> [(start: Double, end: Double)] {
        var output: [(start: Double, end: Double)] = []
        var cursor = start
        while end - cursor > profile.maximumSentenceDuration {
            let minimumSplit = cursor + profile.minimumSentenceDuration
            let maximumSplit = min(end - profile.minimumSentenceDuration, cursor + profile.maximumSentenceDuration)
            guard maximumSplit > minimumSplit else { break }
            let preferred = min(maximumSplit, cursor + profile.preferredSentenceDuration)
            let searchRadius = min(
                profile.preferredSentenceDuration * 0.45,
                max(0.25, (maximumSplit - minimumSplit) / 2)
            )
            let searchStart = max(minimumSplit, preferred - searchRadius)
            let searchEnd = min(maximumSplit, preferred + searchRadius)
            let split = lowestEnergyTime(
                waveform: waveform,
                range: searchStart...searchEnd,
                preferred: preferred
            ) ?? preferred
            output.append((cursor, split))
            cursor = split
        }
        if end - cursor >= 0.05 { output.append((cursor, end)) }
        return output
    }

    private func lowestEnergyTime(
        waveform: WaveformData,
        range: ClosedRange<Double>,
        preferred: Double
    ) -> Double? {
        guard !waveform.isEmpty, waveform.sampleRate > 0 else { return nil }
        let startIndex = max(0, Int((range.lowerBound * waveform.sampleRate).rounded(.up)))
        let endIndex = min(waveform.peaks.count - 1, Int((range.upperBound * waveform.sampleRate).rounded(.down)))
        guard endIndex >= startIndex else { return nil }
        let radius = max(1, Int(waveform.sampleRate * 0.04))
        var bestIndex = startIndex
        var bestScore = Double.greatestFiniteMagnitude
        for index in startIndex...endIndex {
            let localStart = max(0, index - radius)
            let localEnd = min(waveform.peaks.count - 1, index + radius)
            var energy: Double = 0
            for sampleIndex in localStart...localEnd {
                energy += Double(waveform.peaks[sampleIndex])
            }
            energy /= Double(localEnd - localStart + 1)
            let time = Double(index) / waveform.sampleRate
            let distancePenalty = abs(time - preferred) / max(0.5, range.upperBound - range.lowerBound) * 0.12
            let score = energy + distancePenalty
            if score < bestScore {
                bestScore = score
                bestIndex = index
            }
        }
        return Double(bestIndex) / waveform.sampleRate
    }

    private func mergeShortVoiceRanges(
        _ ranges: [(start: Double, end: Double)],
        profile: SpeechSegmentationProfile
    ) -> [(start: Double, end: Double)] {
        guard ranges.count > 1 else { return ranges }
        var result: [(start: Double, end: Double)] = []
        var index = 0
        while index < ranges.count {
            let current = ranges[index]
            if current.end - current.start < profile.minimumSentenceDuration {
                if let previous = result.last,
                   current.end - previous.start <= profile.maximumSentenceDuration,
                   current.start - previous.end <= profile.mergeGap {
                    result[result.count - 1].end = current.end
                    index += 1
                    continue
                }
                if index + 1 < ranges.count {
                    let next = ranges[index + 1]
                    if next.end - current.start <= profile.maximumSentenceDuration,
                       next.start - current.end <= profile.mergeGap {
                        result.append((current.start, next.end))
                        index += 2
                        continue
                    }
                }
            }
            result.append(current)
            index += 1
        }
        return result
    }

    private func resolveRangeOverlaps(_ ranges: inout [(start: Double, end: Double)]) {
        guard ranges.count > 1 else { return }
        let sorted = ranges.sorted {
            if $0.start == $1.start { return $0.end < $1.end }
            return $0.start < $1.start
        }
        var resolved: [(start: Double, end: Double)] = []
        resolved.reserveCapacity(sorted.count)

        for rawRange in sorted {
            let normalizedStart = max(0, rawRange.start)
            var current = (
                start: normalizedStart,
                end: max(normalizedStart, rawRange.end)
            )
            guard let previous = resolved.indices.last else {
                resolved.append(current)
                continue
            }
            guard current.start < resolved[previous].end else {
                resolved.append(current)
                continue
            }

            let previousDuration = resolved[previous].end - resolved[previous].start
            let currentDuration = current.end - current.start
            let minimumPreviousEnd = resolved[previous].start + 0.05
            let maximumCurrentStart = current.end - 0.05

            if minimumPreviousEnd <= maximumCurrentStart {
                // There is room for both ranges. Split at a stable midpoint,
                // then carry that exact boundary forward to avoid a one-frame
                // overlap caused by independent rounding.
                let midpoint = (resolved[previous].end + current.start) / 2
                let boundary = min(maximumCurrentStart, max(minimumPreviousEnd, midpoint))
                resolved[previous].end = boundary
                current.start = boundary
                resolved.append(current)
            } else if previousDuration >= currentDuration {
                // The intervals are too small to preserve both at the minimum
                // subtitle duration. Keep the longer previous range and let
                // the final minimum-duration filter drop the remainder.
                current.start = resolved[previous].end
                if current.end - current.start >= 0.05 {
                    resolved.append(current)
                }
            } else {
                // Prefer the longer current range and trim the previous one.
                resolved[previous].end = current.start
                if resolved[previous].end - resolved[previous].start < 0.05 {
                    resolved.removeLast()
                }
                resolved.append(current)
            }
        }
        ranges = resolved
    }

    private func joinTokenText(_ tokens: [SpeechToken]) -> String {
        var output = ""
        for token in tokens {
            let raw = token.text.replacingOccurrences(of: "\n", with: " ")
            guard !raw.isEmpty else { continue }
            let startsWithWhitespace = raw.first?.isWhitespace == true
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            if !output.isEmpty,
               !startsWithWhitespace,
               shouldInsertSpace(previous: output.last, next: clean.first) {
                output.append(" ")
            } else if startsWithWhitespace,
                      !output.isEmpty,
                      output.last?.isWhitespace != true,
                      !isNoSpaceBeforePunctuation(clean.first) {
                output.append(" ")
            }
            output.append(clean)
        }
        var normalized = output.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        for punctuation in [".", ",", "?", "!", ";", ":", "…", "。", "，", "？", "！", "；", "：", "、", "｡", "．", "؟", ")", "]", "}", "」", "』", "”", "’", "'", "\""] {
            normalized = normalized.replacingOccurrences(of: " \(punctuation)", with: punctuation)
        }
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldInsertSpace(previous: Character?, next: Character?) -> Bool {
        guard let previous, let next else { return false }
        if isNoSpaceBeforePunctuation(next) { return false }
        if "([{“‘".contains(previous) { return false }
        if isCJK(previous) || isCJK(next) { return false }
        return true
    }

    private func isNoSpaceBeforePunctuation(_ character: Character?) -> Bool {
        guard let character else { return false }
        return ".,?!;:…。，“”‘’？！；：、｡．؟)]}".contains(character)
    }

    private func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0x3040...0x30FF, 0xAC00...0xD7AF:
                return true
            default:
                return false
            }
        }
    }

    /// Pull each VAD onset slightly left when the waveform shows rising energy
    /// before the model's reported start time. Silero operates on 32 ms frames,
    /// so soft consonant onsets (/p/ /t/ /k/ /s/) can be quantized to the next
    /// frame boundary. A 3-frame weighted look-back (up to 60 ms) corrects this
    /// without altering offsets or confidence ordering.
    private func smoothOnsetEdges(
        _ segments: [VoiceActivitySegment],
        waveform: WaveformData
    ) -> [VoiceActivitySegment] {
        guard !waveform.isEmpty, waveform.sampleRate > 0 else { return segments }
        let rate = waveform.sampleRate
        let peaks = waveform.peaks
        let maxLookback = 0.060  // max 60 ms look-back
        let frameSize = 0.020    // 20 ms analysis frame

        return segments.map { segment in
            let onsetIndex = max(0, Int((segment.startTime * rate).rounded(.up)))
            guard onsetIndex < peaks.count else { return segment }

            // Search window: [onset - 60ms, onset]
            let searchStart = max(0, Int(((segment.startTime - maxLookback) * rate).rounded(.down)))
            guard searchStart < onsetIndex else { return segment }

            let frameSamples = max(1, Int(frameSize * rate))
            var bestTime = segment.startTime
            var prevEnergy: Float = 0

            // Slide a 20ms frame from left to right; find the first frame
            // where energy already exceeds 40% of the onset frame's energy.
            // That is where speech "really" began.
            let onsetEnd = min(peaks.count, onsetIndex + frameSamples)
            let onsetSlice = peaks[onsetIndex..<onsetEnd]
            let onsetEnergy: Float = onsetSlice.isEmpty ? 0
                : onsetSlice.reduce(0, +) / Float(onsetSlice.count)

            guard onsetEnergy > 0.005 else { return segment }
            let riseThreshold = onsetEnergy * 0.40

            var frameStart = searchStart
            while frameStart < onsetIndex {
                let frameEnd = min(peaks.count, frameStart + frameSamples)
                let slice = peaks[frameStart..<frameEnd]
                let energy: Float = slice.isEmpty ? 0
                    : slice.reduce(0, +) / Float(slice.count)
                if energy >= riseThreshold, prevEnergy < riseThreshold {
                    // Rising edge found – move onset here, but never overlap
                    // with the previous segment.
                    bestTime = Double(frameStart) / rate
                    break
                }
                prevEnergy = energy
                frameStart += frameSamples
            }

            guard bestTime < segment.startTime - 0.005 else { return segment }
            return VoiceActivitySegment(
                startTime: bestTime,
                endTime: segment.endTime,
                confidence: segment.confidence
            )
        }
    }

    private func reindexed(_ segments: [SentenceSegment]) -> [SentenceSegment] {
        segments.enumerated().map { index, segment in
            var copy = segment
            copy.index = index + 1
            return copy
        }
    }
}
