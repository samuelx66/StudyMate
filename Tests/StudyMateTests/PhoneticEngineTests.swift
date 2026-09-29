import XCTest
@testable import StudyMateKit

final class PhoneticEngineTests: XCTestCase {

    func testChinesePinyinGeneration() {
        let text = "你好世界"
        let pinyin = PhoneticEngine.generateChinesePinyin(for: text)
        XCTAssertFalse(pinyin.isEmpty)
        XCTAssertTrue(pinyin.contains("nǐ") || pinyin.contains("ni"))

        let segments = PhoneticEngine.buildSegments(for: text)
        XCTAssertEqual(segments.count, 4)
        XCTAssertEqual(segments[0].text, "你")
        XCTAssertEqual(segments[0].phonetic, "nǐ")
        XCTAssertEqual(segments[1].text, "好")
        XCTAssertEqual(segments[1].phonetic, "hǎo")
        XCTAssertEqual(segments[2].text, "世")
        XCTAssertEqual(segments[2].phonetic, "shì")
        XCTAssertEqual(segments[3].text, "界")
        XCTAssertEqual(segments[3].phonetic, "jiè")
    }

    func testJapaneseFuriganaGeneration() {
        let text = "日本語の勉強"
        let furigana = PhoneticEngine.generateJapaneseFurigana(for: text)
        XCTAssertFalse(furigana.isEmpty)

        let segments = PhoneticEngine.buildSegments(for: text)
        XCTAssertFalse(segments.isEmpty)
        let kanjiSegments = segments.filter { PhoneticEngine.containsKanji($0.text) }
        XCTAssertFalse(kanjiSegments.isEmpty)
        for seg in kanjiSegments {
            XCTAssertNotNil(seg.phonetic, "Kanji segment \(seg.text) should have furigana")
        }
    }

    func testEnglishIPALookupAndSegmentation() {
        let words = ["apple", "world", "study", "language"]
        for word in words {
            let ipa = PhoneticEngine.lookupEnglishIPA(for: word)
            XCTAssertNotNil(ipa, "English word '\(word)' should return IPA phonetic symbol")
            if let ipa {
                XCTAssertTrue(ipa.hasPrefix("/"), "IPA should start with /")
                XCTAssertTrue(ipa.hasSuffix("/"), "IPA should end with /")
            }
        }

        let sentence = "Hello world, I love learning English."
        let segments = PhoneticEngine.buildSegments(for: sentence)
        XCTAssertFalse(segments.isEmpty)

        // Verify that original text can be reconstructed faithfully
        let reconstructed = segments.map { $0.text }.joined()
        XCTAssertEqual(reconstructed, sentence)

        // Verify that English words have IPA phonetics
        let helloSegment = segments.first { $0.text == "Hello" }
        XCTAssertNotNil(helloSegment?.phonetic)
    }

    func testPhoneticEngineManagerToggleAndPersistence() {
        let manager = PhoneticEngineManager.shared
        let initial = manager.showPhonetics
        manager.togglePhonetics()
        XCTAssertEqual(manager.showPhonetics, !initial)

        let persisted = UserDefaults.standard.bool(forKey: "StudyMate.ShowPhonetics")
        XCTAssertEqual(persisted, manager.showPhonetics)

        // Restore initial state
        manager.togglePhonetics()
        XCTAssertEqual(manager.showPhonetics, initial)
    }
}
