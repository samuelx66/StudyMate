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
        let timeline = try await NativeSpeechRuntime.shared.transcribe(
            pcm: pcm,
            modelURL: URL(fileURLWithPath: modelPath),
            language: "en",
            configuration: SpeechSegmentationMode.whisperSemantic.profile.vad,
            progress: { _ in }
        )

        XCTAssertFalse(timeline.tokens.isEmpty)
        XCTAssertTrue(timeline.tokens.allSatisfy { $0.startTime.isFinite && $0.endTime >= $0.startTime })
        XCTAssertEqual(timeline.detectedLanguage, "en")
        print("[SpeechRuntimeIntegrationTests] \(timeline.tokens.map(\.text).joined())")
    }
}
