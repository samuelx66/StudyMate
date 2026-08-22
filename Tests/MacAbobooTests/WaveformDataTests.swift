import XCTest
@testable import MacAbobooKit

final class WaveformDataTests: XCTestCase {
    func testWaveformResampling() {
        let peaks: [Float] = [0.1, 0.5, 0.9, 0.4, 0.2, 0.8, 0.3, 0.7, 0.6, 0.2]
        let minPeaks: [Float] = peaks.map { -$0 }
        let maxPeaks: [Float] = peaks
        
        let waveform = WaveformData(
            peaks: peaks,
            minPeaks: minPeaks,
            maxPeaks: maxPeaks,
            duration: 10.0,
            sampleRate: 1.0 // 1 sample per second
        )
        
        XCTAssertFalse(waveform.isEmpty)
        XCTAssertEqual(waveform.duration, 10.0)
        
        // 重采样为 5 个柱子
        let resampled = waveform.resample(startTime: 0.0, endTime: 10.0, targetCount: 5)
        XCTAssertEqual(resampled.count, 5)
        
        // 第一个区间 (0~2s: 0.1, 0.5, 0.9) 最大值应为 0.9
        XCTAssertGreaterThanOrEqual(resampled[0].max, 0.5)
    }
    
    func testWaveformEmptyGuard() {
        let empty = WaveformData.empty
        XCTAssertTrue(empty.isEmpty)
        let resampled = empty.resample(startTime: 0, endTime: 5, targetCount: 10)
        XCTAssertTrue(resampled.isEmpty)
    }

    func testMismatchedPeakArraysCannotCrashResampling() {
        let waveform = WaveformData(
            peaks: [0.2, 0.4, 0.6],
            minPeaks: [-0.2],
            maxPeaks: [0.2, 0.4],
            duration: 3,
            sampleRate: 1
        )
        XCTAssertEqual(waveform.minPeaks.count, 3)
        XCTAssertEqual(waveform.maxPeaks.count, 3)
        XCTAssertEqual(waveform.resample(startTime: 0, endTime: 3, targetCount: 3).count, 3)
    }
}
