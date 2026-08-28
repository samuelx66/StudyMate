import Foundation

/// 将词级时间戳、标点、停顿、说话人变化和 Silero 边界放入同一个全局评分模型。
public final class SpeechBoundaryOptimizer: @unchecked Sendable {
    public static let shared = SpeechBoundaryOptimizer()

    public init() {}

    /// Formats Whisper tokens with the same spacing and punctuation rules used
    /// by intelligent segmentation. Manual original-text regeneration reuses
    /// this path so its subtitle text is identical to text produced during a
    /// normal intelligent segmentation run.
    public func joinedRecognizedText(_ tokens: [SpeechToken]) -> String {
        joinTokenText(tokens)
    }


    public func optimize(
        mode: SpeechSegmentationMode,
        timeline: SpeechRecognitionTimeline?,
        voiceSegments: [VoiceActivitySegment],
        waveform: WaveformData,
        duration: Double,
        includeRecognizedText: Bool,
        speakerSegments: [SpeakerDiarizationSegment] = [],
        vadProbabilities: [VADProbabilityFrame] = []
    ) -> [SentenceSegment] {
        let safeDuration = duration.isFinite ? max(0, duration) : 0
        guard safeDuration > 0 else { return [] }
        let normalizedVoice = normalizeVoiceSegments(voiceSegments, duration: safeDuration)
        let normalizedSpeakers = normalizeSpeakerSegments(speakerSegments, duration: safeDuration)
        let semanticSpeakers: [SpeakerDiarizationSegment]
        if normalizedSpeakers.isEmpty, let timeline {
            semanticSpeakers = normalizeSpeakerSegments(
                timeline.speakerSegments,
                duration: safeDuration
            )
        } else {
            semanticSpeakers = normalizedSpeakers
        }
        let profile = effectiveProfile(
            mode: mode,
            speakerSegments: semanticSpeakers,
            tokens: timeline?.tokens ?? [],
            voiceSegments: normalizedVoice,
            duration: safeDuration
        )
        let acousticSegments = optimizeVoiceActivity(
            voiceSegments: normalizedVoice,
            waveform: waveform,
            profile: profile,
            duration: safeDuration,
            speakerSegments: normalizedSpeakers,
            stableSpeakerBoundariesOnly: mode == .intelligent
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
                speakerSegments: semanticSpeakers,
                acousticSegments: acousticSegments,
                profile: profile,
                duration: safeDuration,
                includeRecognizedText: includeRecognizedText,
                vadProbabilities: vadProbabilities
            )
            if !result.isEmpty { return result }
        }

        return acousticSegments
    }

    /// Derive one stable content baseline before local candidate scoring. This
    /// is not a user-selected sentence length: it measures actual turn rate,
    /// overlap, speech rate, pause density and Whisper reliability.
    func effectiveProfile(
        mode: SpeechSegmentationMode,
        speakerSegments: [SpeakerDiarizationSegment],
        tokens: [SpeechToken] = [],
        voiceSegments: [VoiceActivitySegment] = [],
        duration: Double
    ) -> SpeechSegmentationProfile {
        var profile = mode.profile
        guard mode == .intelligent, duration > 0 else { return profile }

        let reliableTurns = SpeakerTurnAnalysis.reliableBoundaries(
            in: speakerSegments,
            duration: duration
        )
        let minutes = max(1.0 / 60.0, duration / 60.0)
        let turnsPerMinute = Double(reliableTurns.count) / minutes
        let overlapDuration = speakerSegments
            .filter(\.isOverlap)
            .reduce(0.0) { partial, segment in
                partial + max(0, min(duration, segment.endTime) - max(0, segment.startTime))
            }
        let overlapRatio = min(1, overlapDuration / duration)

        let usableTokens = tokens.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.endTime > $0.startTime
        }
        let averageTokenConfidence = usableTokens.isEmpty
            ? 1.0
            : usableTokens.reduce(0.0) { $0 + Double($1.confidence) } / Double(usableTokens.count)
        let speechDuration = max(0.01, voiceSegments.reduce(0.0) { $0 + $1.duration })
        let tokensPerSecond = Double(usableTokens.count) / speechDuration
        let meaningfulPauses = zip(voiceSegments, voiceSegments.dropFirst()).filter {
            $1.startTime - $0.endTime >= 0.18
        }.count
        let pausesPerMinute = Double(meaningfulPauses) / minutes

        // Interpolate between monologue and dialogue instead of switching at
        // one turn-rate threshold. Nearly identical recordings therefore do
        // not jump to a different segmentation personality.
        let dialogue = smoothRamp(turnsPerMinute, lower: 1.5, upper: 6.0)
        profile.minimumSentenceDuration = interpolate(0.45, 0.30, dialogue)
        profile.preferredSentenceDuration = interpolate(5.0, 3.8, dialogue)
        profile.semanticWeight = interpolate(1.55, 1.30, dialogue)
        profile.pauseWeight = interpolate(1.15, 0.85, dialogue)
        profile.speakerWeight = interpolate(1.25, 1.80, dialogue)
        profile.splitPenalty = interpolate(0.80, 0.68, dialogue)

        if !usableTokens.isEmpty {
            let fastSpeech = smoothRamp(tokensPerSecond, lower: 2.4, upper: 4.0)
            let slowSpeech = 1 - smoothRamp(tokensPerSecond, lower: 0.9, upper: 1.8)
            profile.preferredSentenceDuration = interpolate(
                profile.preferredSentenceDuration,
                min(profile.preferredSentenceDuration, 3.55),
                fastSpeech
            )
            profile.minimumSentenceDuration = interpolate(
                profile.minimumSentenceDuration,
                min(profile.minimumSentenceDuration, 0.30),
                fastSpeech
            )
            profile.preferredSentenceDuration = interpolate(
                profile.preferredSentenceDuration,
                max(profile.preferredSentenceDuration, 5.6),
                slowSpeech
            )
        }

        let pauseRichness = smoothRamp(pausesPerMinute, lower: 2.0, upper: 10.0)
        profile.pauseWeight = interpolate(profile.pauseWeight, max(profile.pauseWeight, 1.22), pauseRichness)
        profile.mergeGap = interpolate(0.18, 0.14, pauseRichness)
        profile.semanticWeight = interpolate(max(profile.semanticWeight, 1.50), profile.semanticWeight, pauseRichness)

        // Whisper remains valuable in noise, but its influence decreases
        // gradually as the actual token confidence weakens.
        let recognitionReliability = smoothRamp(averageTokenConfidence, lower: 0.30, upper: 0.68)
        profile.semanticWeight *= interpolate(0.62, 1.0, recognitionReliability)
        profile.pauseWeight = interpolate(max(profile.pauseWeight, 1.22), profile.pauseWeight, recognitionReliability)
        profile.acousticWeight = interpolate(max(profile.acousticWeight, 1.18), profile.acousticWeight, recognitionReliability)

        // During simultaneous speech a label transition is not a clean
        // subtitle boundary. Attenuate it continuously as overlap grows.
        let overlap = smoothRamp(overlapRatio, lower: 0.02, upper: 0.16)
        profile.speakerWeight *= interpolate(1.0, 0.68, overlap)
        profile.semanticWeight = interpolate(profile.semanticWeight, max(profile.semanticWeight, 1.45), overlap)
        profile.pauseWeight = interpolate(profile.pauseWeight, max(profile.pauseWeight, 1.05), overlap)

        // Learning sentences may be naturally short, but never allow adaptive
        // tuning to weaken the hard maximum used by final safety enforcement.
        profile.maximumSentenceDuration = 12
        return profile
    }

    private func smoothRamp(_ value: Double, lower: Double, upper: Double) -> Double {
        guard upper > lower else { return value >= upper ? 1 : 0 }
        let normalized = min(1, max(0, (value - lower) / (upper - lower)))
        return normalized * normalized * (3 - 2 * normalized)
    }

    private func interpolate(_ from: Double, _ to: Double, _ amount: Double) -> Double {
        from + (to - from) * min(1, max(0, amount))
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

    private struct AdaptiveBoundaryPolicy {
        var semanticWeight: Double
        var pauseWeight: Double
        var acousticWeight: Double
        var speakerWeight: Double
        var splitPenalty: Double
    }

    private func optimizeSemanticTimeline(
        tokens inputTokens: [SpeechToken],
        voiceSegments: [VoiceActivitySegment],
        speakerSegments: [SpeakerDiarizationSegment],
        acousticSegments: [SentenceSegment],
        profile: SpeechSegmentationProfile,
        duration: Double,
        includeRecognizedText: Bool,
        vadProbabilities: [VADProbabilityFrame]
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
            profile: profile,
            vadProbabilities: vadProbabilities
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
                    isFinal: endIndex == count,
                    allowsShortReply: endIndex < count
                        && candidates[endIndex].isHardSpeakerBoundary
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
                    let policy = adaptiveBoundaryPolicy(for: candidate, profile: profile)
                    score += candidate.semanticStrength * policy.semanticWeight
                    score += candidate.pauseStrength * policy.pauseWeight
                    score += candidate.acousticStrength * policy.acousticWeight
                    score += candidate.speakerStrength * policy.speakerWeight
                    score -= policy.splitPenalty
                    if !candidate.isNaturalBoundary {
                        // Do not let a token/window boundary win merely
                        // because the transcript happens to contain many
                        // short tokens. A split needs punctuation, a real
                        // pause/acoustic edge, or an exclusive speaker turn.
                        score -= policy.splitPenalty * 1.8
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
                duration: duration,
                vadProbabilities: vadProbabilities
            )
            let end = calibratedEnd(
                speechEnd: last.endTime,
                voiceSegments: voiceSegments,
                profile: profile,
                duration: duration,
                vadProbabilities: vadProbabilities
            )
            // Keep recognized text internally through post-processing even
            // when the user disabled subtitle saving. Boundary decisions must
            // be identical for both toggle states; clear it only at the end.
            let text = joinTokenText(Array(tokens[range]))
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
        mergeSemanticFragments(
            segments: &segments,
            speakerSegments: speakerSegments,
            profile: profile,
            duration: duration,
            protectedBoundaries: candidates
                .filter { $0.speakerStrength >= 0.75 }
                .map(\.time)
        )
        enforceMaximumDuration(
            segments: &segments,
            maximum: profile.maximumSentenceDuration,
            duration: duration
        )
        let reindexedSegments = reindexed(segments)
        guard !includeRecognizedText else { return reindexedSegments }
        return reindexedSegments.map { segment in
            var copy = segment
            copy.text = ""
            return copy
        }
    }

    /// Repair timestamp-level fragments left by Whisper around window edges or
    /// noisy short words. This is deliberately conservative: a complete
    /// terminal sentence or a stable SpeakerKit turn is never merged merely
    /// because it is short.
    private func mergeSemanticFragments(
        segments: inout [SentenceSegment],
        speakerSegments: [SpeakerDiarizationSegment],
        profile: SpeechSegmentationProfile,
        duration: Double,
        protectedBoundaries: [Double]
    ) {
        guard segments.count > 1 else { return }
        let hardTurns = SpeakerTurnAnalysis.reliableBoundaries(
            in: speakerSegments,
            duration: duration
        )
        var index = 0
        while index + 1 < segments.count {
            let current = segments[index]
            let next = segments[index + 1]
            let gap = max(0, next.startTime - current.endTime)
            let text = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let punctuationOnly = !text.isEmpty && text.allSatisfy {
                $0.isPunctuation || $0.isWhitespace || $0.isSymbol
            }
            let endsTerminal = text.last.map { ".?!。？！…؟｡．".contains($0) } ?? false
            let endsSoftPunctuation = text.last.map { ",，、;:；：".contains($0) } ?? false
            let implausiblyShort = current.duration < 0.25
            let incompleteShortPhrase = current.duration < 1.25 && !endsTerminal
            let softClause = current.duration < 2.0 && endsSoftPunctuation
            let stableTurn = (hardTurns + protectedBoundaries).contains {
                abs($0 - (current.endTime + next.startTime) / 2) <= 0.20
            }
            let combinedSpan = next.endTime - current.startTime
            guard gap <= 0.55,
                  (!stableTurn || implausiblyShort),
                  combinedSpan <= profile.maximumSentenceDuration + 0.001,
                  punctuationOnly || implausiblyShort || incompleteShortPhrase || softClause else {
                index += 1
                continue
            }

            segments[index].endTime = next.endTime
            segments[index].text = joinSegmentTexts(current.text, next.text)
            segments[index].translation = joinSegmentTexts(current.translation, next.translation)
            let ids = Array(Set(current.speakerIDs + next.speakerIDs)).sorted()
            segments[index].speakerIDs = ids
            segments[index].speakerID = ids.count == 1 ? ids[0] : nil
            segments[index].isSpeakerOverlap = current.isSpeakerOverlap || next.isSpeakerOverlap
            segments.remove(at: index + 1)
        }
    }

    private func joinSegmentTexts(_ left: String, _ right: String) -> String {
        let lhs = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = right.trimmingCharacters(in: .whitespacesAndNewlines)
        if lhs.isEmpty { return rhs }
        if rhs.isEmpty { return lhs }
        let noLeadingSpace = rhs.first.map { $0.isPunctuation || $0.isSymbol } ?? false
        return noLeadingSpace ? lhs + rhs : lhs + " " + rhs
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
        profile: SpeechSegmentationProfile,
        vadProbabilities: [VADProbabilityFrame]
    ) -> [BoundaryCandidate] {
        var result: [BoundaryCandidate] = []
        let reliableSpeakerBoundaries = SpeakerTurnAnalysis.reliableBoundaries(
            in: speakerSegments,
            duration: max(tokens.last?.endTime ?? 0, voiceSegments.last?.endTime ?? 0)
        )
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
            let posteriorStrength = vadPosteriorBoundaryStrength(
                at: time,
                probabilities: vadProbabilities,
                window: min(0.22, profile.snapWindow)
            )
            let acousticAnchorStrength = acousticSentenceBoundaryStrength(
                time: time,
                acousticSegments: acousticSegments,
                snapWindow: profile.snapWindow
            )
            let acoustic = max(
                posteriorStrength,
                max(acousticVoiceStrength * 0.65, acousticAnchorStrength)
            )
            let currentSpeakerIDs = Set(token.speakerIDs)
            let nextSpeakerIDs = Set(next?.speakerIDs ?? [])
            let speakerChanged = !currentSpeakerIDs.isEmpty
                && !nextSpeakerIDs.isEmpty
                && currentSpeakerIDs.isDisjoint(with: nextSpeakerIDs)
            let nearStableSpeakerTurn = reliableSpeakerBoundaries.contains {
                abs($0 - time) <= 0.20
            }
            let reliableSpeakerChange = speakerChanged
                && !token.speakerOverlap
                && !(next?.speakerOverlap ?? false)
                && token.speakerConfidence >= 0.35
                && (next?.speakerConfidence ?? 0) >= 0.35
                && nearStableSpeakerTurn
            // A diarization change inside an overlap is useful context, but it
            // is not a safe place to force a subtitle split. Treat it as a
            // weak signal and reserve the full score for an exclusive turn.
            let exclusiveSpeakerChange = !token.speakerOverlap
                && !(next?.speakerOverlap ?? false)
            let speakerStrength: Double = {
                if token.speakerTurnAfter { return 1 }
                guard speakerChanged else { return 0 }
                guard exclusiveSpeakerChange else { return 0.22 }
                return nearStableSpeakerTurn ? 1 : 0.16
            }()
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

    /// Score a boundary from the real Silero posterior curve. A convincing
    /// boundary is both locally quiet and visibly lower than the speech on
    /// either side. This stays useful in background music where waveform
    /// energy never reaches a clean valley.
    private func vadPosteriorBoundaryStrength(
        at time: Double,
        probabilities: [VADProbabilityFrame],
        window: Double
    ) -> Double {
        guard !probabilities.isEmpty, window > 0 else { return 0 }
        let nearby = probabilities.filter { abs($0.time - time) <= window }
        guard !nearby.isEmpty else { return 0 }
        let centerRadius = min(0.055, window * 0.35)
        let center = nearby.filter { abs($0.time - time) <= centerRadius }
        let left = nearby.filter { $0.time < time - centerRadius }
        let right = nearby.filter { $0.time > time + centerRadius }
        let centerMinimum = Double((center.isEmpty ? nearby : center).map(\.probability).min() ?? 1)
        let centerAverage = averageProbability(center.isEmpty ? nearby : center)
        let leftAverage = averageProbability(left)
        let rightAverage = averageProbability(right)
        let flankFloor = min(leftAverage, rightAverage)
        let valleyDepth = max(0, flankFloor - centerAverage)
        let quietStrength = max(0, min(1, (0.58 - centerMinimum) / 0.50))
        let valleyStrength = max(0, min(1, valleyDepth / 0.42))
        // A low posterior alone is meaningful for an actual token gap, while
        // the flank comparison prevents isolated low frames inside speech
        // from becoming overly attractive split points.
        return min(1, quietStrength * 0.62 + valleyStrength * 0.72)
    }

    private func averageProbability(_ frames: [VADProbabilityFrame]) -> Double {
        guard !frames.isEmpty else { return 0 }
        return frames.reduce(0.0) { $0 + Double($1.probability) } / Double(frames.count)
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
        isFinal: Bool,
        allowsShortReply: Bool
    ) -> Double {
        let tokenRate = Double(tokenCount) / max(0.10, duration)
        let preferredDuration: Double
        if tokenRate >= 3.2 {
            preferredDuration = max(2.8, profile.preferredSentenceDuration * 0.82)
        } else if tokenRate <= 1.25 {
            preferredDuration = min(6.2, profile.preferredSentenceDuration * 1.15)
        } else {
            preferredDuration = profile.preferredSentenceDuration
        }
        let minimumDuration = allowsShortReply
            ? min(0.20, profile.minimumSentenceDuration)
            : profile.minimumSentenceDuration
        var score = -0.16 * abs(duration - preferredDuration)
            / max(0.5, preferredDuration)
        if duration < minimumDuration {
            let ratio = (minimumDuration - duration) / minimumDuration
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

    private func adaptiveBoundaryPolicy(
        for candidate: BoundaryCandidate,
        profile: SpeechSegmentationProfile
    ) -> AdaptiveBoundaryPolicy {
        var policy = AdaptiveBoundaryPolicy(
            semanticWeight: profile.semanticWeight,
            pauseWeight: profile.pauseWeight,
            acousticWeight: profile.acousticWeight,
            speakerWeight: profile.speakerWeight,
            splitPenalty: profile.splitPenalty
        )

        if candidate.isHardSpeakerBoundary {
            policy.speakerWeight = max(policy.speakerWeight, 1.95)
            policy.splitPenalty *= 0.45
        } else if candidate.speakerStrength > 0, candidate.speakerStrength < 0.70 {
            // Overlap/flicker remains useful context but cannot dominate a
            // clean semantic or acoustic boundary.
            policy.speakerWeight *= 0.55
        }

        if candidate.semanticStrength >= 0.65 {
            policy.semanticWeight = max(policy.semanticWeight, 1.70)
            policy.splitPenalty *= 0.78
        }
        if candidate.pauseStrength >= 0.65, candidate.acousticStrength >= 0.45 {
            policy.pauseWeight = max(policy.pauseWeight, 1.25)
            policy.acousticWeight = max(policy.acousticWeight, 1.10)
            policy.splitPenalty *= 0.72
        }

        let strongestEvidence = max(
            candidate.semanticStrength,
            candidate.pauseStrength,
            candidate.acousticStrength,
            candidate.speakerStrength
        )
        if strongestEvidence < 0.35 {
            policy.splitPenalty *= 1.30
        }
        return policy
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
        duration: Double,
        vadProbabilities: [VADProbabilityFrame]
    ) -> Double {
        let candidate = voiceSegments
            .filter { $0.startTime <= speechStart + 0.08 && abs($0.startTime - speechStart) <= profile.snapWindow }
            .min { abs($0.startTime - speechStart) < abs($1.startTime - speechStart) }
        let fallback = candidate?.startTime ?? speechStart - profile.onsetPadding
        guard let voiceStart = candidate?.startTime,
              let refined = posteriorOnset(near: voiceStart, probabilities: vadProbabilities) else {
            return min(duration, max(0, fallback))
        }
        return min(duration, max(0, refined))
    }

    private func calibratedEnd(
        speechEnd: Double,
        voiceSegments: [VoiceActivitySegment],
        profile: SpeechSegmentationProfile,
        duration: Double,
        vadProbabilities: [VADProbabilityFrame]
    ) -> Double {
        let candidate = voiceSegments
            .filter { $0.endTime >= speechEnd - 0.08 && abs($0.endTime - speechEnd) <= profile.snapWindow }
            .min { abs($0.endTime - speechEnd) < abs($1.endTime - speechEnd) }
        let fallback = candidate?.endTime ?? speechEnd + profile.offsetPadding
        guard let voiceEnd = candidate?.endTime,
              let refined = posteriorOffset(near: voiceEnd, probabilities: vadProbabilities) else {
            return min(duration, max(0, fallback))
        }
        return min(duration, max(0, refined))
    }

    private func posteriorOnset(
        near boundary: Double,
        probabilities: [VADProbabilityFrame]
    ) -> Double? {
        let local = probabilities.filter { $0.time >= boundary - 0.14 && $0.time <= boundary + 0.24 }
        guard local.count >= 2 else { return nil }
        guard let onsetIndex = local.indices.first(where: { index in
            local[index].probability >= 0.30
                && index + 1 < local.count
                && local[index + 1].probability >= 0.30
        }) else { return nil }
        var index = onsetIndex
        while index > 0, local[index - 1].probability >= 0.10 { index -= 1 }
        let frameStep = local.count > 1 ? local[1].time - local[0].time : 0.032
        return local[index].time - max(0.032, frameStep * 1.5)
    }

    private func posteriorOffset(
        near boundary: Double,
        probabilities: [VADProbabilityFrame]
    ) -> Double? {
        let local = probabilities.filter { $0.time >= boundary - 0.24 && $0.time <= boundary + 0.16 }
        guard local.count >= 2 else { return nil }
        guard let offsetIndex = local.indices.reversed().first(where: { index in
            local[index].probability >= 0.20
                && index > 0
                && local[index - 1].probability >= 0.20
        }) else { return nil }
        var index = offsetIndex
        while index + 1 < local.count, local[index + 1].probability >= 0.08 { index += 1 }
        let frameStep = local.count > 1 ? local[1].time - local[0].time : 0.032
        return local[index].time + max(0.048, frameStep * 1.75)
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
        speakerSegments: [SpeakerDiarizationSegment],
        stableSpeakerBoundariesOnly: Bool
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
                    mergeGap: profile.mergeGap,
                    stableOnly: stableSpeakerBoundariesOnly,
                    duration: duration
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
        mergeGap: Double,
        stableOnly: Bool,
        duration: Double
    ) -> [(start: Double, end: Double)] {
        guard end - start >= 0.02 else { return [] }
        var breakpoints = [start, end]
        if stableOnly {
            breakpoints.append(contentsOf: SpeakerTurnAnalysis.reliableBoundaries(
                in: speakerSegments,
                duration: duration
            ).filter { $0 > start && $0 < end })
            // Simultaneous speech remains a distinct acoustic condition even
            // when its labels are not a stable exclusive turn.
            for speaker in speakerSegments where speaker.isOverlap
                && speaker.endTime > start && speaker.startTime < end {
                breakpoints.append(min(end, max(start, speaker.startTime)))
                breakpoints.append(min(end, max(start, speaker.endTime)))
            }
        } else {
            for speaker in speakerSegments where speaker.endTime > start && speaker.startTime < end {
                breakpoints.append(min(end, max(start, speaker.startTime)))
                breakpoints.append(min(end, max(start, speaker.endTime)))
            }
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
                hasCalibratedConfidence: segment.hasCalibratedConfidence,
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
                smoothed[smoothed.count - 1].hasCalibratedConfidence =
                    last.hasCalibratedConfidence && segment.hasCalibratedConfidence
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

    private func reindexed(_ segments: [SentenceSegment]) -> [SentenceSegment] {
        segments.enumerated().map { index, segment in
            var copy = segment
            copy.index = index + 1
            return copy
        }
    }
}
