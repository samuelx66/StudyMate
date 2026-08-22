import XCTest
@testable import MacAbobooKit

final class TextAlignmentTests: XCTestCase {
    func testSentenceSplitting() {
        let text = "Hello Mr. Smith! How are you doing today? I am fine, thank you. This is sentence 4."
        let sentences = TextAlignmentEngine.shared.splitTextIntoSentences(text)
        
        XCTAssertEqual(sentences.count, 4)
        XCTAssertEqual(sentences[0], "Hello Mr. Smith!")
        XCTAssertEqual(sentences[1], "How are you doing today?")
        XCTAssertEqual(sentences[2], "I am fine, thank you.")
        XCTAssertEqual(sentences[3], "This is sentence 4.")
    }
    
    func testTextAlignmentWithVAD() {
        let sentences = [
            "First sentence.",
            "Second sentence."
        ]
        
        let vadSegments = [
            SentenceSegment(index: 1, startTime: 0.0, endTime: 3.5),
            SentenceSegment(index: 2, startTime: 4.0, endTime: 8.0)
        ]
        
        let aligned = TextAlignmentEngine.shared.alignSentences(sentences, with: vadSegments, totalDuration: 10.0)
        
        XCTAssertEqual(aligned.count, 2)
        XCTAssertEqual(aligned[0].text, "First sentence.")
        XCTAssertEqual(aligned[0].startTime, 0.0)
        XCTAssertEqual(aligned[0].endTime, 3.5)
        
        XCTAssertEqual(aligned[1].text, "Second sentence.")
        XCTAssertEqual(aligned[1].startTime, 4.0)
        XCTAssertEqual(aligned[1].endTime, 8.0)
    }
    
    func testTextAlignmentWhenSentencesExceedVAD() {
        let sentences = [
            "Sentence one.",
            "Sentence two.",
            "Sentence three.",
            "Sentence four.",
            "Sentence five."
        ]
        
        let vadSegments = [
            SentenceSegment(index: 1, startTime: 0.0, endTime: 4.0),
            SentenceSegment(index: 2, startTime: 5.0, endTime: 10.0)
        ]
        
        let aligned = TextAlignmentEngine.shared.alignSentences(sentences, with: vadSegments, totalDuration: 12.0)
        
        // 确保所有 5 个句子都被对齐分配
        XCTAssertEqual(aligned.count, 5)
        XCTAssertEqual(aligned.map { $0.text }, sentences)
        
        // 确保时间按顺序递增且合理落在 VAD 区间内
        for i in 0..<aligned.count {
            XCTAssertLessThan(aligned[i].startTime, aligned[i].endTime)
            if i > 0 {
                XCTAssertGreaterThanOrEqual(aligned[i].startTime, aligned[i - 1].endTime)
            }
        }
    }
}
