import XCTest
@testable import MacAbobooKit

@MainActor
final class WhisperModelManagerTests: XCTestCase {
    func testModelLevelsAndFilenames() {
        XCTAssertEqual(WhisperModelLevel.tiny.filename, "ggml-tiny.bin")
        XCTAssertEqual(WhisperModelLevel.base.filename, "ggml-base.bin")
        XCTAssertEqual(WhisperModelLevel.small.filename, "ggml-small.bin")
        
        XCTAssertTrue(WhisperModelLevel.tiny.downloadURL.absoluteString.contains("ggml-tiny.bin"))
        XCTAssertTrue(WhisperModelLevel.base.downloadURL.absoluteString.contains("ggml-base.bin"))
        XCTAssertTrue(WhisperModelLevel.small.downloadURL.absoluteString.contains("ggml-small.bin"))
    }
    
    func testModelStatusRefresh() {
        let manager = WhisperModelManager.shared
        manager.refreshAllModelStatuses()
        
        for level in WhisperModelLevel.allCases {
            let status = manager.modelStatuses[level]
            XCTAssertNotNil(status)
        }
    }
}
