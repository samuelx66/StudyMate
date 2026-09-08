import XCTest
@testable import StudyMateKit

final class MainStatusCenterTests: XCTestCase {
    @MainActor
    override func setUp() {
        super.setUp()
        MainStatusCenter.shared.clearAllIssues()
        MainStatusCenter.shared.clearSuccess()
    }

    @MainActor
    func testRecordIssueAndDeduplication() {
        let center = MainStatusCenter.shared

        XCTAssertTrue(center.issues.isEmpty)

        let id1 = center.recordIssue(message: "行 24 字幕解析失败", level: .warning)
        XCTAssertEqual(center.issues.count, 1)
        XCTAssertEqual(center.issues.first?.id, id1)
        XCTAssertEqual(center.issues.first?.message, "行 24 字幕解析失败")
        XCTAssertEqual(center.issues.first?.level, .warning)

        // 添加不同问题
        let id2 = center.recordIssue(message: "AI 断句连接超时", level: .error)
        XCTAssertEqual(center.issues.count, 2)
        XCTAssertEqual(center.issues.first?.id, id2)

        // 重复记录相同问题，应该置顶且不增加总数
        let id1Duplicate = center.recordIssue(message: "行 24 字幕解析失败", level: .error)
        XCTAssertEqual(id1Duplicate, id1)
        XCTAssertEqual(center.issues.count, 2)
        XCTAssertEqual(center.issues.first?.id, id1)
        XCTAssertEqual(center.issues.first?.level, .error)
    }

    @MainActor
    func testDismissIssueAndClearAll() {
        let center = MainStatusCenter.shared

        let id1 = center.recordIssue(message: "问题 1")
        let id2 = center.recordIssue(message: "问题 2")
        XCTAssertEqual(center.issues.count, 2)

        center.dismissIssue(id: id1)
        XCTAssertEqual(center.issues.count, 1)
        XCTAssertEqual(center.issues.first?.id, id2)

        center.clearAllIssues()
        XCTAssertTrue(center.issues.isEmpty)
        XCTAssertNil(center.errorMessage)
    }

    @MainActor
    func testShowErrorRecordsIssue() {
        let center = MainStatusCenter.shared

        center.showError("无法载入音频文件")
        XCTAssertEqual(center.errorMessage, "无法载入音频文件")
        XCTAssertEqual(center.issues.count, 1)
        XCTAssertEqual(center.issues.first?.message, "无法载入音频文件")
        XCTAssertEqual(center.issues.first?.level, .error)

        center.clearError()
        XCTAssertNil(center.errorMessage)
        XCTAssertTrue(center.issues.isEmpty)
    }

    @MainActor
    func testSuccessMessageDisplayAndClear() {
        let center = MainStatusCenter.shared

        center.showSuccess("已添加到生词本")
        XCTAssertEqual(center.successMessage, "已添加到生词本")

        center.clearSuccess()
        XCTAssertNil(center.successMessage)
    }
}
