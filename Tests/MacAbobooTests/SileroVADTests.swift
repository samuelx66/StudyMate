import XCTest
@testable import MacAbobooKit

final class SileroVADTests: XCTestCase {
    func testSileroVADProbabilityAndSegments() {
        // 构造合成波形：两段语音和中间静音
        // 采样率 50.0 samples/sec (每点 20ms)
        // 0.0s ~ 1.5s: 语音段 1 (75 samples)
        // 1.5s ~ 2.2s: 静音停顿 (35 samples)
        // 2.2s ~ 4.0s: 语音段 2 (90 samples)
        var peaks = [Float]()
        peaks.append(contentsOf: Array(repeating: 0.85, count: 75))
        peaks.append(contentsOf: Array(repeating: 0.02, count: 35))
        peaks.append(contentsOf: Array(repeating: 0.75, count: 90))
        
        let waveform = WaveformData(
            peaks: peaks,
            minPeaks: peaks.map { -$0 },
            maxPeaks: peaks,
            duration: 4.0,
            sampleRate: 50.0
        )
        
        let timeline = SileroVADEngine.shared.extractSpeechProbabilityTimeline(from: waveform)
        XCTAssertEqual(timeline.count, 200)
        
        // 语音区概率应高，静音区概率应低
        let speechProb1 = timeline[20].probability
        let silenceProb = timeline[90].probability
        let speechProb2 = timeline[150].probability
        
        XCTAssertGreaterThan(speechProb1, 0.6)
        XCTAssertLessThan(silenceProb, 0.4)
        XCTAssertGreaterThan(speechProb2, 0.6)
        
        let segments = SileroVADEngine.shared.detectSegments(from: waveform)
        XCTAssertGreaterThanOrEqual(segments.count, 1)
    }
}
