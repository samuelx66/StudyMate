import XCTest
@testable import MacAbobooKit

final class VADSegmenterTests: XCTestCase {
    func testSilenceValleyDetection() {
        // 构造合成波形数据：包含两句话和一段明显停顿
        // 采样率 10 samples/sec (每点 100ms)
        // 0.0s ~ 2.0s: 语音段 1 (振幅 ~ 0.8)
        // 2.0s ~ 2.6s: 静音停顿 (振幅 ~ 0.01)
        // 2.6s ~ 5.0s: 语音段 2 (振幅 ~ 0.7)
        var peaks = [Float]()
        
        // 句 1 (20 samples = 2.0s)
        peaks.append(contentsOf: Array(repeating: 0.8, count: 20))
        // 停顿 (6 samples = 0.6s)
        peaks.append(contentsOf: [0.02, 0.01, 0.005, 0.005, 0.01, 0.02])
        // 句 2 (24 samples = 2.4s)
        peaks.append(contentsOf: Array(repeating: 0.7, count: 24))
        
        let waveform = WaveformData(
            peaks: peaks,
            minPeaks: peaks.map { -$0 },
            maxPeaks: peaks,
            duration: 5.0,
            sampleRate: 10.0
        )
        
        let config = VADSegmenter.Config(
            minSilenceDuration: 0.3,
            minSentenceDuration: 1.0,
            maxSentenceDuration: 10.0
        )
        
        let segments = VADSegmenter.shared.detectSegments(from: waveform, config: config)
        
        // 应该切成两句话
        XCTAssertEqual(segments.count, 2)
        
        // 第一句起始为 0.0，结束点应落在静音区间 (~2.2s - 2.4s)
        XCTAssertEqual(segments[0].startTime, 0.0)
        XCTAssertGreaterThanOrEqual(segments[0].endTime, 2.0)
        XCTAssertLessThanOrEqual(segments[0].endTime, 2.6)
        
        // 第二句起始点即为第一句结束点，结束点为 5.0
        XCTAssertEqual(segments[1].startTime, segments[0].endTime)
        XCTAssertEqual(segments[1].endTime, 5.0)
    }
}
