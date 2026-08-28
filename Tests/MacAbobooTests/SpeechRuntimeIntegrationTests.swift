import XCTest
@testable import MacAbobooKit

final class SpeechRuntimeIntegrationTests: XCTestCase {
    func testRealWhisperInferenceWhenFixturesAreProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["MACABOBOO_WHISPER_TEST_MODEL"],
              let audioPath = environment["MACABOBOO_WHISPER_TEST_AUDIO"] else {
            throw XCTSkip("Set MACABOBOO_WHISPER_TEST_MODEL and MACABOBOO_WHISPER_TEST_AUDIO to run the real-model integration test.")
        }

        let pcm = try await AudioPCMExtractor.shared.extract(from: URL(fileURLWithPath: audioPath))
        XCTAssertFalse(pcm.isEmpty)
        print("[SpeechRuntimeIntegrationTests] decoded \(pcm.samples.count) samples")
        let analysis = try await NativeSpeechRuntime.shared.detectVoiceActivityAnalysis(
            pcm: pcm,
            configuration: SpeechSegmentationMode.intelligent.profile.vad
        )
        let timeline = try await NativeSpeechRuntime.shared.transcribe(
            pcm: pcm,
            modelURL: URL(fileURLWithPath: modelPath),
            language: "en",
            configuration: SpeechSegmentationMode.intelligent.profile.vad,
            speechWindows: analysis.segments,
            progress: { _ in }
        )

        XCTAssertFalse(timeline.tokens.isEmpty)
        XCTAssertTrue(timeline.tokens.allSatisfy { $0.startTime.isFinite && $0.endTime >= $0.startTime })
        XCTAssertEqual(timeline.detectedLanguage, "en")
        print("[SpeechRuntimeIntegrationTests] \(timeline.tokens.map(\.text).joined())")
    }

    func testRealMediaSegmentationWhenFixtureIsProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["MACABOBOO_WHISPER_TEST_MODEL"] else {
            throw XCTSkip("Set the real media and Whisper model fixtures to run segmentation quality validation.")
        }
        let output: SpeechSegmentationOutput
        if let pcmPath = environment["MACABOBOO_SEGMENTATION_TEST_PCM"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: pcmPath), options: .mappedIfSafe)
            XCTAssertEqual(data.count % MemoryLayout<Float>.size, 0)
            var samples = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
            _ = samples.withUnsafeMutableBytes { destination in data.copyBytes(to: destination) }
            let pcm = AudioPCMData(uncheckedSamples: samples)
            let profile = SpeechSegmentationMode.intelligent.profile
            let analysis = try await NativeSpeechRuntime.shared.detectVoiceActivityAnalysis(
                pcm: pcm,
                configuration: profile.vad
            )
            let speakers = try await SpeakerDiarizationEngine.shared.diarize(pcm: pcm)
            let plan = SpeechSegmentationPipeline.transcriptionWindowPlan(
                voiceSegments: analysis.segments,
                speakerSegments: speakers.segments,
                duration: pcm.duration
            )
            print("[SpeechRuntimeIntegrationTests] vad=\(analysis.segments.count) speakers=\(speakers.segments.count) speakerCount=\(speakers.speakerCount) hardTurns=\(plan.hardBoundaries.count) windows=\(plan.windows.count)")
            var timeline = try await NativeSpeechRuntime.shared.transcribe(
                pcm: pcm,
                modelURL: URL(fileURLWithPath: modelPath),
                language: "en",
                configuration: profile.vad,
                speechWindows: plan.windows,
                hardWindowBoundaries: plan.hardBoundaries,
                progress: { _ in }
            )
            timeline.speakerSegments = speakers.segments
            let segments = SpeechBoundaryOptimizer.shared.optimize(
                mode: .intelligent,
                timeline: timeline,
                voiceSegments: analysis.segments,
                waveform: pcm.waveform(),
                duration: pcm.duration,
                includeRecognizedText: true,
                speakerSegments: speakers.segments,
                vadProbabilities: analysis.probabilities
            )
            output = SpeechSegmentationOutput(
                segments: segments,
                detectedLanguage: timeline.detectedLanguage
            )
        } else if let mediaPath = environment["MACABOBOO_SEGMENTATION_TEST_MEDIA"] {
            output = try await SpeechSegmentationPipeline.shared.run(
                request: SpeechSegmentationRequest(
                    mediaURL: URL(fileURLWithPath: mediaPath),
                    mode: .intelligent,
                    whisperModelURL: URL(fileURLWithPath: modelPath),
                    recognitionLanguage: "en",
                    includeRecognizedText: true,
                    enableSpeakerDiarization: true
                ),
                stageChanged: { _ in },
                preview: { _ in }
            )
        } else {
            throw XCTSkip("Set a media or decoded PCM fixture to run segmentation quality validation.")
        }

        XCTAssertFalse(output.segments.isEmpty)
        XCTAssertTrue(output.segments.allSatisfy {
            $0.startTime >= 0
                && $0.endTime > $0.startTime
                && $0.duration <= 12.001
        })
        XCTAssertTrue(zip(output.segments, output.segments.dropFirst()).allSatisfy { pair in
            pair.0.endTime <= pair.1.startTime + 0.001
        })
        print("[SpeechRuntimeIntegrationTests] language=\(output.detectedLanguage) warnings=\(output.warnings)")
        for segment in output.segments {
            print(String(format: "#%d %.3f --> %.3f %@", segment.index, segment.startTime, segment.endTime, segment.text))
        }
    }
}
