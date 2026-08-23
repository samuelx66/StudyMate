import XCTest
@testable import MacAbobooKit

final class SileroWhisperCascadeTests: XCTestCase {
    func testSileroWhisperCascadeSegmentation() {
        // 合成波形：5.0秒
        var peaks = [Float]()
        peaks.append(contentsOf: Array(repeating: Float(0.8), count: 20)) // 0.0 ~ 2.0s
        peaks.append(contentsOf: [0.01, 0.005, 0.005, 0.01, 0.02, 0.02])  // 2.0 ~ 2.6s
        peaks.append(contentsOf: Array(repeating: Float(0.7), count: 24)) // 2.6 ~ 5.0s
        
        let waveform = WaveformData(
            peaks: peaks,
            minPeaks: peaks.map { -$0 },
            maxPeaks: peaks,
            duration: 5.0,
            sampleRate: 10.0
        )
        
        // 模拟 Whisper 识别出的两句话
        let sentences = [
            SpeechAlignmentEngine.TranscribedSentence(
                text: "Hello world and welcome to MacAboboo.",
                startTime: 0.1,
                endTime: 1.9,
                words: [
                    SpeechAlignmentEngine.WordTimestamp(word: "Hello", startTime: 0.1, endTime: 0.4),
                    SpeechAlignmentEngine.WordTimestamp(word: "MacAboboo.", startTime: 1.5, endTime: 1.9)
                ]
            ),
            SpeechAlignmentEngine.TranscribedSentence(
                text: "This is high precision listening software.",
                startTime: 2.7,
                endTime: 4.8,
                words: [
                    SpeechAlignmentEngine.WordTimestamp(word: "This", startTime: 2.7, endTime: 3.0),
                    SpeechAlignmentEngine.WordTimestamp(word: "software.", startTime: 4.3, endTime: 4.8)
                ]
            )
        ]
        
        let result = SileroWhisperCascadeSegmenter.shared.segment(
            sentences: sentences,
            waveform: waveform,
            vadConfig: .standard
        )
        
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].text, "Hello world and welcome to MacAboboo.")
        XCTAssertEqual(result[1].text, "This is high precision listening software.")
        
        // 验证防吞音与边界合理性
        XCTAssertEqual(result[0].startTime, 0.0)
        XCTAssertGreaterThan(result[0].endTime, 1.8)
        XCTAssertLessThanOrEqual(result[0].endTime, 2.6)
        
        XCTAssertGreaterThanOrEqual(result[1].startTime, result[0].endTime)
        XCTAssertGreaterThan(result[1].endTime, 4.8)
    }

    func testVerifyingSegmentationModesAreDistinct() {
        // 创建一段包含短停顿 (0.25s) 与长停顿 (0.6s) 的复杂波形
        var peaks = [Float]()
        peaks.append(contentsOf: Array(repeating: Float(0.9), count: 20)) // 0.0 ~ 2.0s 人声
        peaks.append(contentsOf: [0.01, 0.01, 0.01])                     // 2.0 ~ 2.3s (0.3s 短停顿)
        peaks.append(contentsOf: Array(repeating: Float(0.8), count: 20)) // 2.3 ~ 4.3s 人声
        peaks.append(contentsOf: [0.01, 0.01, 0.01, 0.01, 0.01, 0.01])   // 4.3 ~ 4.9s (0.6s 长停顿)
        peaks.append(contentsOf: Array(repeating: Float(0.85), count: 20))// 4.9 ~ 6.9s 人声
        
        let waveform = WaveformData(
            peaks: peaks,
            minPeaks: peaks.map { -$0 },
            maxPeaks: peaks,
            duration: 6.9,
            sampleRate: 10.0
        )
        
        // 模式 2 (声学回退/极速抗噪): minSilence = 0.18s
        let modeNoiseSegments = SileroVADEngine.shared.legacyDetectSegments(from: waveform, config: .noiseResistant)
        
        // 模式 3: Silero VAD 标准 (minSilence = 0.32s) -> 0.3s 停顿不会切，0.6s 停顿会切 -> 2 句
        let mode3Segments = SileroVADEngine.shared.legacyDetectSegments(from: waveform, config: .standard)
        
        // 模式 4: Silero VAD 敏捷 (minSilence = 0.22s) -> 0.3s 停顿也会切，0.6s 也切 -> 3 句
        let mode4Segments = SileroVADEngine.shared.legacyDetectSegments(from: waveform, config: .sensitive)
        
        // 模式 5: Silero VAD 宽松 (minSilence = 0.50s) -> 0.3s 不切，0.6s 切 -> 2 句 (边界更宽松)
        let mode5Segments = SileroVADEngine.shared.legacyDetectSegments(from: waveform, config: .relaxed)
        
        XCTAssertGreaterThan(mode4Segments.count, mode3Segments.count)
        XCTAssertGreaterThanOrEqual(modeNoiseSegments.count, mode4Segments.count)
        
        // 模式 2: DualEngine 语义从句识别
        let grammarSentences = [
            SpeechAlignmentEngine.TranscribedSentence(
                text: "Sentence one.",
                startTime: 0.1,
                endTime: 1.9,
                words: [SpeechAlignmentEngine.WordTimestamp(word: "Sentence", startTime: 0.1, endTime: 0.8),
                        SpeechAlignmentEngine.WordTimestamp(word: "one.", startTime: 1.0, endTime: 1.9)]
            )
        ]
        let mode2Segments = DualEngineFusionSegmenter.shared.fuse(sentences: grammarSentences, waveform: waveform)
        
        // 模式 1: Silero+Whisper Cascade 两阶段
        let mode1Segments = SileroWhisperCascadeSegmenter.shared.segment(sentences: grammarSentences, waveform: waveform, vadConfig: .cascade)
        
        // 模式 6: 纯 Whisper 独立切分
        let mode6Segments = WhisperPureSegmenter.shared.segment(sentences: grammarSentences, duration: waveform.duration, autoGenerateSubtitles: true)
        
        XCTAssertFalse(mode1Segments.isEmpty)
        XCTAssertFalse(mode2Segments.isEmpty)
        XCTAssertFalse(mode3Segments.isEmpty)
        XCTAssertFalse(mode4Segments.isEmpty)
        XCTAssertFalse(mode5Segments.isEmpty)
        XCTAssertFalse(mode6Segments.isEmpty)
        XCTAssertEqual(mode6Segments.count, 1)
        XCTAssertEqual(mode6Segments[0].text, "Sentence one.")
    }

    func testPureWhisperWordLevelOverlapResolution() {
        let sentences = [
            SpeechAlignmentEngine.TranscribedSentence(
                text: "Where are you going?",
                startTime: 0.2,
                endTime: 1.8,
                words: [
                    SpeechAlignmentEngine.WordTimestamp(word: "Where", startTime: 0.2, endTime: 0.5),
                    SpeechAlignmentEngine.WordTimestamp(word: "going?", startTime: 1.4, endTime: 1.8)
                ]
            ),
            SpeechAlignmentEngine.TranscribedSentence(
                text: "I don't know yet.",
                startTime: 1.85,
                endTime: 3.5,
                words: [
                    SpeechAlignmentEngine.WordTimestamp(word: "I", startTime: 1.85, endTime: 2.1),
                    SpeechAlignmentEngine.WordTimestamp(word: "yet.", startTime: 3.1, endTime: 3.5)
                ]
            )
        ]
        
        let result = WhisperPureSegmenter.shared.segment(sentences: sentences, duration: 5.0, autoGenerateSubtitles: true)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].text, "Where are you going?")
        XCTAssertEqual(result[1].text, "I don't know yet.")
        XCTAssertLessThanOrEqual(result[0].endTime, result[1].startTime)
    }
}
