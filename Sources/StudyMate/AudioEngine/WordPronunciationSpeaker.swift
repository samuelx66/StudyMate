import Foundation
import AVFoundation

/// 生词发音/朗读服务，利用 macOS 原生 AVSpeechSynthesizer 提供高保真离线语音合成
@MainActor
public final class WordPronunciationSpeaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    public static let shared = WordPronunciationSpeaker()

    @Published public private(set) var speakingWordID: UUID?
    private let synthesizer = AVSpeechSynthesizer()

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    public func speak(word: String, entryID: UUID? = nil) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        speakingWordID = entryID
        let utterance = AVSpeechUtterance(string: trimmed)
        let isChinese = trimmed.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
        utterance.voice = AVSpeechSynthesisVoice(language: isChinese ? "zh-CN" : "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        synthesizer.speak(utterance)
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speakingWordID = nil
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speakingWordID = nil
        }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speakingWordID = nil
        }
    }
}
