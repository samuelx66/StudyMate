import XCTest
@testable import StudyMateKit

@MainActor
final class WhisperModelManagerTests: XCTestCase {
    func testModelLevelsAndFilenames() {
        XCTAssertEqual(WhisperModelLevel.tiny.filename, "ggml-tiny.bin")
        XCTAssertEqual(WhisperModelLevel.base.filename, "ggml-base.bin")
        XCTAssertEqual(WhisperModelLevel.small.filename, "ggml-small.bin")
        XCTAssertEqual(WhisperModelLevel.mediumQ8.filename, "ggml-medium-q8_0.bin")
        XCTAssertEqual(WhisperModelLevel.mediumEnQ8.filename, "ggml-medium.en-q8_0.bin")
        XCTAssertEqual(WhisperModelLevel.largeV3TurboQ8.filename, "ggml-large-v3-turbo-q8_0.bin")
        
        XCTAssertTrue(WhisperModelLevel.tiny.downloadURL.absoluteString.contains("ggml-tiny.bin"))
        XCTAssertTrue(WhisperModelLevel.base.downloadURL.absoluteString.contains("ggml-base.bin"))
        XCTAssertTrue(WhisperModelLevel.small.downloadURL.absoluteString.contains("ggml-small.bin"))
        XCTAssertTrue(WhisperModelLevel.mediumQ8.downloadURL.absoluteString.contains("ggml-medium-q8_0.bin"))
        XCTAssertTrue(WhisperModelLevel.mediumEnQ8.downloadURL.absoluteString.contains("ggml-medium.en-q8_0.bin"))
        XCTAssertTrue(WhisperModelLevel.largeV3TurboQ8.downloadURL.absoluteString.contains("ggml-large-v3-turbo-q8_0.bin"))

        XCTAssertTrue(WhisperModelLevel.mediumEnQ8.isEnglishOnly)
        XCTAssertFalse(WhisperModelLevel.mediumQ8.isEnglishOnly)
        XCTAssertFalse(WhisperModelLevel.largeV3TurboQ8.isEnglishOnly)
        XCTAssertFalse(WhisperModelLevel.base.isEnglishOnly)
    }

    func testEnglishOnlyModelLocksSpeechRecognitionLanguage() {
        let manager = WhisperModelManager.shared
        let engine = PlaybackEngine.shared

        // 切换到普通多语言模型，语言可自由设定为中文
        manager.selectedModelLevel = .mediumQ8
        engine.speechRecognitionLanguage = "zh"
        XCTAssertEqual(engine.speechRecognitionLanguage, "zh")
        XCTAssertEqual(engine.effectiveSpeechRecognitionLanguage, "zh")

        // 切换到纯英文专版 medium.en-q8_0，识别语言自动固定为 "en"
        manager.selectedModelLevel = .mediumEnQ8
        XCTAssertEqual(engine.speechRecognitionLanguage, "en")
        XCTAssertEqual(engine.effectiveSpeechRecognitionLanguage, "en")

        // 在纯英语模型下尝试修改为其他语言会被拒绝并强制重置为 "en"
        engine.speechRecognitionLanguage = "ja"
        XCTAssertEqual(engine.speechRecognitionLanguage, "en")
        XCTAssertEqual(engine.effectiveSpeechRecognitionLanguage, "en")

        // 切换回基础模型，恢复可自由设定
        manager.selectedModelLevel = .base
        engine.speechRecognitionLanguage = "auto"
        XCTAssertEqual(engine.speechRecognitionLanguage, "auto")
        XCTAssertEqual(engine.effectiveSpeechRecognitionLanguage, "auto")
    }
    
    func testModelStatusRefresh() {
        let manager = WhisperModelManager.shared
        manager.refreshAllModelStatuses()
        
        XCTAssertEqual(WhisperModelLevel.allCases.count, 6)
        for level in WhisperModelLevel.allCases {
            let status = manager.modelStatuses[level]
            XCTAssertNotNil(status)
        }
    }

    func testEnglishOnlyModelInitFromUserDefaults() {
        let originalModel = UserDefaults.standard.string(forKey: "StudyMate.SelectedWhisperModelLevel")
        UserDefaults.standard.set(WhisperModelLevel.mediumEnQ8.rawValue, forKey: "StudyMate.SelectedWhisperModelLevel")
        defer {
            UserDefaults.standard.set(originalModel, forKey: "StudyMate.SelectedWhisperModelLevel")
        }

        let engine = makeTestPlaybackEngine()
        XCTAssertEqual(engine.speechRecognitionLanguage, "en")
        XCTAssertEqual(engine.effectiveSpeechRecognitionLanguage, "en")
    }
}
