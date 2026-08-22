import XCTest
@testable import MacAbobooKit

final class DualEngineFusionTests: XCTestCase {
    func testDualEngineFusionWithVAD() {
        // 构造波形
        var peaks = [Float]()
        peaks.append(contentsOf: Array(repeating: 0.8, count: 100))
        peaks.append(contentsOf: Array(repeating: 0.01, count: 50))
        peaks.append(contentsOf: Array(repeating: 0.8, count: 100))
        
        let waveform = WaveformData(
            peaks: peaks,
            minPeaks: peaks.map { -$0 },
            maxPeaks: peaks,
            duration: 5.0,
            sampleRate: 50.0
        )
        
        // 构造转写句子
        let s1 = SpeechAlignmentEngine.TranscribedSentence(
            text: "Hello world.",
            startTime: 0.1,
            endTime: 1.9,
            words: [
                SpeechAlignmentEngine.WordTimestamp(word: "Hello", startTime: 0.1, endTime: 0.8),
                SpeechAlignmentEngine.WordTimestamp(word: "world.", startTime: 0.9, endTime: 1.9)
            ]
        )
        let s2 = SpeechAlignmentEngine.TranscribedSentence(
            text: "Welcome to MacAboboo.",
            startTime: 3.1,
            endTime: 4.8,
            words: [
                SpeechAlignmentEngine.WordTimestamp(word: "Welcome", startTime: 3.1, endTime: 3.8),
                SpeechAlignmentEngine.WordTimestamp(word: "to", startTime: 3.9, endTime: 4.1),
                SpeechAlignmentEngine.WordTimestamp(word: "MacAboboo.", startTime: 4.2, endTime: 4.8)
            ]
        )
        
        let fused = DualEngineFusionSegmenter.shared.fuse(
            sentences: [s1, s2],
            waveform: waveform
        )
        
        XCTAssertEqual(fused.count, 2)
        XCTAssertEqual(fused[0].text, "Hello world.")
        XCTAssertEqual(fused[1].text, "Welcome to MacAboboo.")
        
        // 验证句首防吞音安全缓冲 (startTime <= 0.1)
        XCTAssertLessThanOrEqual(fused[0].startTime, 0.1)
        // 验证句尾防截断安全缓冲 (endTime >= 1.9)
        XCTAssertGreaterThanOrEqual(fused[0].endTime, 1.9)
        
        // 验证第二句同样享受前后缓冲
        XCTAssertLessThanOrEqual(fused[1].startTime, 3.1)
        XCTAssertGreaterThanOrEqual(fused[1].endTime, 4.8)
    }
}
