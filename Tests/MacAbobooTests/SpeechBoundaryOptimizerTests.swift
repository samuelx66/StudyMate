import XCTest
@testable import MacAbobooKit

final class SpeechBoundaryOptimizerTests: XCTestCase {
    func testSemanticPunctuationAndPauseCreateGlobalBoundary() {
        let timeline = SpeechRecognitionTimeline(
            tokens: [
                SpeechToken(text: " Hello", startTime: 0.20, endTime: 0.50),
                SpeechToken(text: " there.", startTime: 0.55, endTime: 1.00),
                SpeechToken(text: " How", startTime: 1.60, endTime: 1.90),
                SpeechToken(text: " are", startTime: 1.95, endTime: 2.20),
                SpeechToken(text: " you?", startTime: 2.25, endTime: 2.70)
            ],
            voiceSegments: [
                VoiceActivitySegment(startTime: 0.10, endTime: 1.10),
                VoiceActivitySegment(startTime: 1.50, endTime: 2.80)
            ],
            detectedLanguage: "en"
        )

        let result = SpeechBoundaryOptimizer.shared.optimize(
            mode: .intelligent,
            timeline: timeline,
            voiceSegments: timeline.voiceSegments,
            waveform: .empty,
            duration: 3,
            includeRecognizedText: true
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].text, "Hello there.")
        XCTAssertEqual(result[1].text, "How are you?")
        XCTAssertLessThanOrEqual(result[0].endTime, result[1].startTime)
    }

    func testSubtitleOutputToggleDoesNotChangeAIBoundaries() {
        let tokens = [
            SpeechToken(text: " First.", startTime: 0.1, endTime: 0.9),
            SpeechToken(text: " Second.", startTime: 1.4, endTime: 2.2)
        ]
        let voice = [
            VoiceActivitySegment(startTime: 0.05, endTime: 1.0),
            VoiceActivitySegment(startTime: 1.3, endTime: 2.3)
        ]
        let timeline = SpeechRecognitionTimeline(tokens: tokens, voiceSegments: voice, detectedLanguage: "en")

        let withText = SpeechBoundaryOptimizer.shared.optimize(
            mode: .intelligent,
            timeline: timeline,
            voiceSegments: voice,
            waveform: .empty,
            duration: 2.5,
            includeRecognizedText: true
        )
        let withoutText = SpeechBoundaryOptimizer.shared.optimize(
            mode: .intelligent,
            timeline: timeline,
            voiceSegments: voice,
            waveform: .empty,
            duration: 2.5,
            includeRecognizedText: false
        )

        XCTAssertEqual(withText.map(\.startTime), withoutText.map(\.startTime))
        XCTAssertEqual(withText.map(\.endTime), withoutText.map(\.endTime))
        XCTAssertTrue(withoutText.allSatisfy { $0.text.isEmpty })
    }

    func testSemanticModeUsesExternalVoiceBoundariesInsteadOfWhisperWindows() {
        let externalVoice = [
            VoiceActivitySegment(startTime: 0.10, endTime: 0.90),
            VoiceActivitySegment(startTime: 1.20, endTime: 2.00)
        ]
        let timeline = SpeechRecognitionTimeline(
            tokens: [
                SpeechToken(text: " First.", startTime: 0.20, endTime: 0.84),
                SpeechToken(text: " Second.", startTime: 1.30, endTime: 1.94)
            ],
            // Deliberately provide competing one-second Whisper windows. They
            // must not become the public sentence boundaries.
            voiceSegments: [
                VoiceActivitySegment(startTime: 0.00, endTime: 1.00),
                VoiceActivitySegment(startTime: 1.00, endTime: 2.00)
            ],
            detectedLanguage: "en"
        )

        let result = SpeechBoundaryOptimizer.shared.optimize(
            mode: .intelligent,
            timeline: timeline,
            voiceSegments: externalVoice,
            waveform: .empty,
            duration: 2.1,
            includeRecognizedText: true
        )

        XCTAssertEqual(result.map(\.text), ["First.", "Second."])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].startTime, 0.10, accuracy: 0.001)
        XCTAssertEqual(result[1].startTime, 1.20, accuracy: 0.001)
        XCTAssertEqual(result[0].endTime, 0.90, accuracy: 0.001)
        XCTAssertEqual(result[1].endTime, 2.00, accuracy: 0.001)
    }

    func testHighConfidenceWhisperPunctuationRefinesLongAcousticRange() {
        let timeline = SpeechRecognitionTimeline(
            tokens: [
                SpeechToken(text: " Hello.", startTime: 0.10, endTime: 0.55, confidence: 0.95),
                SpeechToken(text: " This", startTime: 0.72, endTime: 0.98, confidence: 0.92),
                SpeechToken(text: " works.", startTime: 1.10, endTime: 1.55, confidence: 0.94)
            ],
            // Deliberately keep one long acoustic region. Semantic punctuation
            // must still be allowed to refine its internal sentence boundary.
            voiceSegments: [VoiceActivitySegment(startTime: 0.05, endTime: 2.40)],
            detectedLanguage: "en"
        )

        let result = SpeechBoundaryOptimizer.shared.optimize(
            mode: .intelligent,
            timeline: timeline,
            voiceSegments: timeline.voiceSegments,
            waveform: .empty,
            duration: 2.5,
            includeRecognizedText: true
        )

        XCTAssertEqual(result.map(\.text), ["Hello.", "This works."])
        XCTAssertLessThan(result[0].endTime, 1.0)
        XCTAssertGreaterThan(result[1].startTime, result[0].startTime)
    }

    func testLowConfidenceWhisperPunctuationDoesNotForceLocalSplit() {
        let timeline = SpeechRecognitionTimeline(
            tokens: [
                SpeechToken(text: " hello.", startTime: 0.10, endTime: 0.40, confidence: 0.05),
                SpeechToken(text: " there", startTime: 0.48, endTime: 0.78, confidence: 0.82),
                SpeechToken(text: " friend", startTime: 0.86, endTime: 1.20, confidence: 0.80)
            ],
            voiceSegments: [VoiceActivitySegment(startTime: 0.05, endTime: 2.40)],
            detectedLanguage: "en"
        )

        let result = SpeechBoundaryOptimizer.shared.optimize(
            mode: .intelligent,
            timeline: timeline,
            voiceSegments: timeline.voiceSegments,
            waveform: .empty,
            duration: 2.5,
            includeRecognizedText: true
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "hello. there friend")
    }

    func testSemanticOptimizerDoesNotExposeUnpunctuatedSubMinimumTokenBurst() {
        let timeline = SpeechRecognitionTimeline(
            tokens: [
                SpeechToken(text: " hello", startTime: 0.10, endTime: 0.38),
                SpeechToken(text: " uh", startTime: 0.40, endTime: 0.52),
                SpeechToken(text: " there", startTime: 0.54, endTime: 0.84)
            ],
            voiceSegments: [VoiceActivitySegment(startTime: 0.05, endTime: 1.00)],
            detectedLanguage: "en"
        )

        let result = SpeechBoundaryOptimizer.shared.optimize(
            mode: .intelligent,
            timeline: timeline,
            voiceSegments: timeline.voiceSegments,
            waveform: .empty,
            duration: 1.1,
            includeRecognizedText: true
        )

        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.allSatisfy {
            $0.duration >= SpeechSegmentationMode.intelligent.profile.minimumSentenceDuration - 0.001
        })
    }

    func testSpeakerTurnCanSplitUnpunctuatedDialogue() {
        let timeline = SpeechRecognitionTimeline(
            tokens: [
                SpeechToken(text: " I", startTime: 0.1, endTime: 0.5),
                SpeechToken(text: " know", startTime: 0.55, endTime: 1.0, speakerTurnAfter: true),
                SpeechToken(text: " you", startTime: 1.05, endTime: 1.45),
                SpeechToken(text: " do", startTime: 1.50, endTime: 1.90)
            ],
            voiceSegments: [VoiceActivitySegment(startTime: 0.05, endTime: 2.0)],
            detectedLanguage: "en"
        )
        let result = SpeechBoundaryOptimizer.shared.optimize(
            mode: .intelligent,
            timeline: timeline,
            voiceSegments: timeline.voiceSegments,
            waveform: .empty,
            duration: 2.1,
            includeRecognizedText: true
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.text), ["I know", "you do"])
    }

    func testSpeakerKitBoundarySplitsUnpunctuatedTokens() {
        let speakers = [
            SpeakerDiarizationSegment(startTime: 0.05, endTime: 0.82, speakerIDs: [0]),
            SpeakerDiarizationSegment(startTime: 0.82, endTime: 1.65, speakerIDs: [1])
        ]
        let voice = [VoiceActivitySegment(startTime: 0.05, endTime: 1.7)]
        let timeline = SpeechRecognitionTimeline(
            tokens: [
                SpeechToken(text: " I", startTime: 0.10, endTime: 0.38),
                SpeechToken(text: " agree", startTime: 0.42, endTime: 0.78),
                SpeechToken(text: " yes", startTime: 0.86, endTime: 1.12),
                SpeechToken(text: " exactly", startTime: 1.18, endTime: 1.58)
            ],
            voiceSegments: voice,
            detectedLanguage: "en",
            speakerSegments: speakers
        )

        let result = SpeechBoundaryOptimizer.shared.optimize(
            mode: .intelligent,
            timeline: timeline,
            voiceSegments: voice,
            waveform: .empty,
            duration: 1.8,
            includeRecognizedText: true
        )

        XCTAssertEqual(result.map(\.text), ["I agree", "yes exactly"])
        XCTAssertEqual(result.map(\.speakerID), [0, 1])
    }

    func testSpeakerKitKeepsShortTurnAndOverlapMetadata() {
        let speakers = [
            SpeakerDiarizationSegment(startTime: 0, endTime: 0.8, speakerIDs: [0]),
            SpeakerDiarizationSegment(startTime: 0.8, endTime: 1.0, speakerIDs: [1]),
            SpeakerDiarizationSegment(startTime: 1.0, endTime: 2.4, speakerIDs: [0]),
            SpeakerDiarizationSegment(startTime: 1.15, endTime: 1.45, speakerIDs: [1])
        ]
        let result = SpeechBoundaryOptimizer.shared.optimize(
            mode: .fast,
            timeline: nil,
            voiceSegments: [VoiceActivitySegment(startTime: 0, endTime: 2.4)],
            waveform: .empty,
            duration: 2.4,
            includeRecognizedText: false,
            speakerSegments: speakers
        )

        XCTAssertEqual(result.map(\.speakerIDs), [[0], [1], [0], [0, 1], [0]])
        XCTAssertTrue(result[3].isSpeakerOverlap)
        XCTAssertGreaterThanOrEqual(result[1].duration, 0.19)
    }

    func testSequentialSpeakerLabelsDoNotImplyOverlap() {
        let segment = SentenceSegment(
            index: 1,
            startTime: 0,
            endTime: 1,
            speakerIDs: [0, 1],
            isSpeakerOverlap: false
        )

        XCTAssertEqual(segment.speakerIDs, [0, 1])
        XCTAssertFalse(segment.isSpeakerOverlap)
    }

    func testSemanticPaddingCannotBreakMaximumDuration() {
        let timeline = SpeechRecognitionTimeline(
            tokens: [
                SpeechToken(text: " A very long token", startTime: 0.10, endTime: 8.90)
            ],
            voiceSegments: [
                VoiceActivitySegment(startTime: 0, endTime: 9.30)
            ],
            detectedLanguage: "en"
        )

        let result = SpeechBoundaryOptimizer.shared.optimize(
            mode: .intelligent,
            timeline: timeline,
            voiceSegments: timeline.voiceSegments,
            waveform: .empty,
            duration: 10,
            includeRecognizedText: true
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertLessThanOrEqual(
            result[0].duration,
            SpeechSegmentationMode.intelligent.profile.maximumSentenceDuration + 0.001
        )
    }

    func testSpeakerKitCoverageRecoversWhenSileroMissesSpeech() {
        let result = SpeechBoundaryOptimizer.shared.optimize(
            mode: .fast,
            timeline: nil,
            voiceSegments: [],
            waveform: .empty,
            duration: 1.6,
            includeRecognizedText: false,
            speakerSegments: [
                SpeakerDiarizationSegment(startTime: 0.1, endTime: 0.75, speakerIDs: [0]),
                SpeakerDiarizationSegment(startTime: 0.75, endTime: 1.55, speakerIDs: [1])
            ]
        )

        XCTAssertEqual(result.map(\.speakerID), [0, 1])
        XCTAssertEqual(result.count, 2)
    }

    func testLongVADSegmentRemainsSplitBelowHardMaximum() {
        var peaks = [Float](repeating: 0.8, count: 2_500)
        for second in stride(from: 4, through: 24, by: 4) {
            let center = second * 100
            for index in max(0, center - 8)...min(peaks.count - 1, center + 8) {
                peaks[index] = 0.01
            }
        }
        let waveform = WaveformData(peaks: peaks, duration: 25, sampleRate: 100)
        let result = SpeechBoundaryOptimizer.shared.optimize(
            mode: .fast,
            timeline: nil,
            voiceSegments: [VoiceActivitySegment(startTime: 0, endTime: 25)],
            waveform: waveform,
            duration: 25,
            includeRecognizedText: false
        )

        XCTAssertGreaterThan(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.duration <= SpeechSegmentationMode.fast.profile.maximumSentenceDuration + 0.001 })
        for index in 0..<(result.count - 1) {
            XCTAssertLessThanOrEqual(result[index].endTime, result[index + 1].startTime)
        }
    }

    func testSilenceDoesNotProducePlaceholderSentence() {
        let result = SpeechBoundaryOptimizer.shared.optimize(
            mode: .fast,
            timeline: nil,
            voiceSegments: [],
            waveform: WaveformData(peaks: [Float](repeating: 0, count: 100), duration: 1, sampleRate: 100),
            duration: 1,
            includeRecognizedText: false
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testBundledSileroModelLoadsAndRejectsSilence() async throws {
        let pcm = AudioPCMData(samples: [Float](repeating: 0, count: 16_000))
        let analysis = try await NativeSpeechRuntime.shared.detectVoiceActivityAnalysis(
            pcm: pcm,
            configuration: SpeechSegmentationMode.fast.profile.vad
        )
        XCTAssertTrue(analysis.segments.isEmpty)
        XCTAssertGreaterThan(analysis.probabilities.count, 20)
        XCTAssertTrue(analysis.probabilities.allSatisfy { $0.probability < 0.10 })
        XCTAssertEqual(analysis.frameDuration, 1.0 / Double(analysis.probabilities.count), accuracy: 0.0001)
    }

    func testBundledSpeakerKitModelsLoadAndRejectSilence() async throws {
        let pcm = AudioPCMData(samples: [Float](repeating: 0, count: 16_000))
        let timeline = try await SpeakerDiarizationEngine.shared.diarize(pcm: pcm)
        XCTAssertTrue(timeline.isEmpty)
    }

    func testFastAndIntelligentModesHaveDistinctProfiles() {
        XCTAssertEqual(SpeechSegmentationMode.allCases.count, 2)
        let signatures = Set(SpeechSegmentationMode.allCases.map { mode in
            let profile = mode.profile
            return "\(profile.vad.threshold)-\(profile.vad.minSilenceDuration)-\(profile.semanticWeight)-\(profile.maximumSentenceDuration)"
        })
        XCTAssertEqual(signatures.count, 2)
        XCTAssertFalse(SpeechSegmentationMode.fast.requiresTranscription)
        XCTAssertTrue(SpeechSegmentationMode.intelligent.requiresTranscription)
    }

    func testFastModeCapsFinalSentenceAtTwelveSeconds() {
        let profile = SpeechSegmentationMode.fast.profile
        XCTAssertEqual(profile.vad.maxSpeechDuration, 12, accuracy: 0.001)
        XCTAssertEqual(profile.maximumSentenceDuration, 12, accuracy: 0.001)

        var peaks = [Float](repeating: 0.8, count: 1_700)
        for index in 790...810 { peaks[index] = 0.01 }
        let result = SpeechBoundaryOptimizer.shared.optimize(
            mode: .fast,
            timeline: nil,
            voiceSegments: [VoiceActivitySegment(startTime: 0, endTime: 17)],
            waveform: WaveformData(peaks: peaks, duration: 17, sampleRate: 100),
            duration: 17,
            includeRecognizedText: false
        )

        XCTAssertGreaterThan(result.count, 1)
        XCTAssertTrue(result.allSatisfy { $0.duration <= 12.001 })
    }

    func testSingleSpeakerAIProfileStrengthensSemanticAndPauseEvidence() {
        let speakers = [
            SpeakerDiarizationSegment(startTime: 0, endTime: 8, speakerIDs: [0], confidence: 0.9)
        ]
        let profile = SpeechBoundaryOptimizer.shared.effectiveProfile(
            mode: .intelligent,
            speakerSegments: speakers,
            duration: 8
        )

        XCTAssertEqual(profile.semanticWeight, 1.55, accuracy: 0.001)
        XCTAssertEqual(profile.pauseWeight, 1.15, accuracy: 0.001)
    }

    func testFrequentReliableTurnsAdaptIntelligentModeForDialogue() {
        let speakers = [
            SpeakerDiarizationSegment(startTime: 0, endTime: 1, speakerIDs: [0], confidence: 0.9),
            SpeakerDiarizationSegment(startTime: 1, endTime: 2, speakerIDs: [1], confidence: 0.9)
        ]
        let profile = SpeechBoundaryOptimizer.shared.effectiveProfile(
            mode: .intelligent,
            speakerSegments: speakers,
            duration: 2
        )

        XCTAssertEqual(profile.minimumSentenceDuration, 0.30, accuracy: 0.001)
        XCTAssertEqual(profile.preferredSentenceDuration, 3.8, accuracy: 0.001)
        XCTAssertEqual(profile.speakerWeight, 1.80, accuracy: 0.001)
        XCTAssertLessThan(profile.splitPenalty, SpeechSegmentationMode.intelligent.profile.splitPenalty)
    }

    func testLowConfidenceRecognitionShiftsIntelligentModeTowardAcousticEvidence() {
        let tokens = [
            SpeechToken(text: " uncertain", startTime: 0, endTime: 0.5, confidence: 0.2),
            SpeechToken(text: " words", startTime: 0.6, endTime: 1.0, confidence: 0.3)
        ]
        let profile = SpeechBoundaryOptimizer.shared.effectiveProfile(
            mode: .intelligent,
            speakerSegments: [],
            tokens: tokens,
            voiceSegments: [VoiceActivitySegment(startTime: 0, endTime: 1)],
            duration: 1
        )

        XCTAssertLessThan(profile.semanticWeight, SpeechSegmentationMode.intelligent.profile.semanticWeight)
        XCTAssertGreaterThanOrEqual(profile.acousticWeight, 1.15)
        XCTAssertGreaterThanOrEqual(profile.pauseWeight, 1.20)
    }

    func testTranscriptionPlanPreservesReliableSpeakerTurnInsideContinuousVoice() {
        let plan = SpeechSegmentationPipeline.transcriptionWindowPlan(
            voiceSegments: [VoiceActivitySegment(startTime: 0, endTime: 2)],
            speakerSegments: [
                SpeakerDiarizationSegment(startTime: 0, endTime: 1, speakerIDs: [0], confidence: 0.9),
                SpeakerDiarizationSegment(startTime: 1, endTime: 2, speakerIDs: [1], confidence: 0.9)
            ],
            duration: 2
        )

        XCTAssertEqual(plan.hardBoundaries.count, 1)
        XCTAssertEqual(plan.hardBoundaries[0], 1, accuracy: 0.001)
        XCTAssertEqual(plan.windows.count, 2)
        XCTAssertEqual(plan.windows[0].endTime, 1, accuracy: 0.001)
        XCTAssertEqual(plan.windows[1].startTime, 1, accuracy: 0.001)
    }

    func testSpeakerKitUnknownConfidenceStillPreservesStableTurn() {
        let plan = SpeechSegmentationPipeline.transcriptionWindowPlan(
            voiceSegments: [VoiceActivitySegment(startTime: 0, endTime: 2)],
            speakerSegments: [
                SpeakerDiarizationSegment(
                    startTime: 0,
                    endTime: 1,
                    speakerIDs: [0],
                    confidence: 0,
                    hasCalibratedConfidence: false
                ),
                SpeakerDiarizationSegment(
                    startTime: 1,
                    endTime: 2,
                    speakerIDs: [1],
                    confidence: 0,
                    hasCalibratedConfidence: false
                )
            ],
            duration: 2
        )

        XCTAssertEqual(plan.hardBoundaries, [1])
        XCTAssertEqual(plan.windows.count, 2)
    }

    func testCalibratedLowConfidenceSpeakerTurnRemainsSoftEvidence() {
        let boundaries = SpeakerTurnAnalysis.reliableBoundaries(
            in: [
                SpeakerDiarizationSegment(startTime: 0, endTime: 1, speakerIDs: [0], confidence: 0.2),
                SpeakerDiarizationSegment(startTime: 1, endTime: 2, speakerIDs: [1], confidence: 0.2)
            ],
            duration: 2
        )

        XCTAssertTrue(boundaries.isEmpty)
    }

    func testUnknownConfidenceShortSpeakerReturnIsNotAHardBoundary() {
        let boundaries = SpeakerTurnAnalysis.reliableBoundaries(
            in: [
                SpeakerDiarizationSegment(startTime: 0, endTime: 1.4, speakerIDs: [0], confidence: 0, hasCalibratedConfidence: false),
                SpeakerDiarizationSegment(startTime: 1.4, endTime: 2.0, speakerIDs: [1], confidence: 0, hasCalibratedConfidence: false),
                SpeakerDiarizationSegment(startTime: 2.0, endTime: 3.2, speakerIDs: [0], confidence: 0, hasCalibratedConfidence: false)
            ],
            duration: 3.2
        )

        XCTAssertTrue(boundaries.isEmpty)
    }

    func testWhisperWindowDeduplicationAlignsPunctuationAndTokenization() {
        let tokens = [
            SpeechToken(text: " New", startTime: 1.00, endTime: 1.18, confidence: 0.8),
            SpeechToken(text: " York,", startTime: 1.18, endTime: 1.48, confidence: 0.8),
            SpeechToken(
                text: " New York",
                startTime: 1.02,
                endTime: 1.50,
                confidence: 0.9,
                recognitionSegmentIndex: 1_000_000
            ),
            SpeechToken(
                text: " today",
                startTime: 1.50,
                endTime: 1.80,
                confidence: 0.9,
                recognitionSegmentIndex: 1_000_001
            )
        ]

        let result = NativeSpeechRuntime.deduplicateWindowTokens(tokens)

        XCTAssertEqual(result.map(\.text), [" New", " York,", " today"])
    }

    func testWhisperWindowDeduplicationKeepsIntentionalRepeatedWords() {
        let tokens = [
            SpeechToken(text: " no", startTime: 1.0, endTime: 1.2),
            SpeechToken(
                text: " no",
                startTime: 1.35,
                endTime: 1.55,
                recognitionSegmentIndex: 1_000_000
            )
        ]

        XCTAssertEqual(NativeSpeechRuntime.deduplicateWindowTokens(tokens).count, 2)
    }

    func testWhisperRangeBuilderDoesNotReMergeAcrossSpeakerTurn() {
        let ranges = NativeSpeechRuntime.transcriptionRanges(
            [
                VoiceActivitySegment(startTime: 0, endTime: 1),
                VoiceActivitySegment(startTime: 1, endTime: 2)
            ],
            duration: 2,
            sampleCount: 32_000,
            hardBoundaries: [1]
        )

        XCTAssertEqual(ranges.count, 2)
        XCTAssertLessThanOrEqual(ranges[0].end, 17_280)
        XCTAssertGreaterThanOrEqual(ranges[1].start, 14_720)
    }

    func testIsolatedWhisperWindowsReadOnlyExactSentenceSamples() {
        let ranges = NativeSpeechRuntime.transcriptionRanges(
            [
                VoiceActivitySegment(startTime: 1, endTime: 2),
                VoiceActivitySegment(startTime: 2, endTime: 3)
            ],
            duration: 4,
            sampleCount: 64_000,
            hardBoundaries: [1, 2, 3],
            contextPadding: 0
        )

        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].start, 16_000)
        XCTAssertEqual(ranges[0].end, 32_000)
        XCTAssertEqual(ranges[1].start, 32_000)
        XCTAssertEqual(ranges[1].end, 48_000)
    }

    func testIsolatedWhisperWindowsNeverDeduplicateAgainstPreviousSentence() {
        let tokens = [
            SpeechToken(
                text: " again",
                startTime: 1,
                endTime: 1.3,
                recognitionSegmentIndex: 0
            ),
            SpeechToken(
                text: " again",
                startTime: 1,
                endTime: 1.3,
                recognitionSegmentIndex: 1_000_000
            )
        ]

        let isolated = NativeSpeechRuntime.finalizedWindowTokens(
            tokens,
            isolatedSpeechWindows: true
        )

        XCTAssertEqual(isolated.count, 2)
    }

    func testWhisperContextResetsAtReliableSpeakerTurnButNotOrdinaryOverlap() {
        let previous = NativeSpeechRuntime.SampleRange(start: 0, end: 17_280)
        let current = NativeSpeechRuntime.SampleRange(start: 14_720, end: 32_000)

        XCTAssertTrue(NativeSpeechRuntime.shouldResetWhisperContext(
            windowIndex: 1,
            range: current,
            previousRange: previous,
            hardBoundaries: [1.0]
        ))
        XCTAssertFalse(NativeSpeechRuntime.shouldResetWhisperContext(
            windowIndex: 1,
            range: current,
            previousRange: previous,
            hardBoundaries: []
        ))
    }

    func testWhisperContextResetsAfterLongRealSilence() {
        XCTAssertTrue(NativeSpeechRuntime.shouldResetWhisperContext(
            windowIndex: 1,
            range: .init(start: 32_000, end: 48_000),
            previousRange: .init(start: 0, end: 16_000),
            hardBoundaries: []
        ))
    }

}
