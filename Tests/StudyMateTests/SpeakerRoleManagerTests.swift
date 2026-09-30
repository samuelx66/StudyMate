import XCTest
@testable import StudyMateKit

@MainActor
final class SpeakerRoleManagerTests: XCTestCase {
    func testIsCompositeRole() {
        XCTAssertTrue(SpeakerRoleManager.isCompositeRole("s1+s2"))
        XCTAssertTrue(SpeakerRoleManager.isCompositeRole("s1->s2"))
        XCTAssertTrue(SpeakerRoleManager.isCompositeRole("s1→s2"))
        XCTAssertTrue(SpeakerRoleManager.isCompositeRole("s1/s2"))
        XCTAssertTrue(SpeakerRoleManager.isCompositeRole("  s1+s2  "))

        XCTAssertFalse(SpeakerRoleManager.isCompositeRole("s1"))
        XCTAssertFalse(SpeakerRoleManager.isCompositeRole("s2"))
        XCTAssertFalse(SpeakerRoleManager.isCompositeRole("Jim"))
        XCTAssertFalse(SpeakerRoleManager.isCompositeRole("Narrator"))
        XCTAssertFalse(SpeakerRoleManager.isCompositeRole(""))
    }

    func testExtractCandidateRoles() {
        XCTAssertEqual(SpeakerRoleManager.extractCandidateRoles(from: "s1+s2"), ["s1", "s2"])
        XCTAssertEqual(SpeakerRoleManager.extractCandidateRoles(from: "s1->s2"), ["s1", "s2"])
        XCTAssertEqual(SpeakerRoleManager.extractCandidateRoles(from: "s1→s2"), ["s1", "s2"])
        XCTAssertEqual(SpeakerRoleManager.extractCandidateRoles(from: "s1/s2"), ["s1", "s2"])
        XCTAssertEqual(SpeakerRoleManager.extractCandidateRoles(from: "s1+s2+s3"), ["s1", "s2", "s3"])
    }

    func testResolveRenameCompositeToCandidateID() {
        let manager = SpeakerRoleManager()
        let names = ["s1": "Jim", "s2": "s2"]

        // 1. 选择 s1 (已有名字 Jim)
        let res1 = manager.resolveRename(fromRoleKey: "s1+s2", inputName: "s1", currentSpeakerNames: names)
        if case .resolvedToSingle(let fromKey, let toKey, let unifiedName, let targetSpeakerID) = res1.action {
            XCTAssertEqual(fromKey, "s1+s2")
            XCTAssertEqual(toKey, "s1")
            XCTAssertEqual(unifiedName, "Jim")
            XCTAssertEqual(targetSpeakerID, 0)
        } else {
            XCTFail("Expected resolvedToSingle, got \(res1.action)")
        }

        // 2. 选择 s2 (未命名)
        let res2 = manager.resolveRename(fromRoleKey: "s1->s2", inputName: "s2", currentSpeakerNames: names)
        if case .resolvedToSingle(let fromKey, let toKey, let unifiedName, let targetSpeakerID) = res2.action {
            XCTAssertEqual(fromKey, "s1->s2")
            XCTAssertEqual(toKey, "s2")
            XCTAssertEqual(unifiedName, "s2")
            XCTAssertEqual(targetSpeakerID, 1)
        } else {
            XCTFail("Expected resolvedToSingle, got \(res2.action)")
        }
    }

    func testResolveRenameCompositeToExistingName() {
        let manager = SpeakerRoleManager()
        let names = ["s1": "Jim", "s2": "Tom"]

        // 输入已知姓名 "Tom"
        let res = manager.resolveRename(fromRoleKey: "s1+s2", inputName: "Tom", currentSpeakerNames: names)
        if case .resolvedToSingle(let fromKey, let toKey, let unifiedName, let targetSpeakerID) = res.action {
            XCTAssertEqual(fromKey, "s1+s2")
            XCTAssertEqual(toKey, "s2")
            XCTAssertEqual(unifiedName, "Tom")
            XCTAssertEqual(targetSpeakerID, 1)
        } else {
            XCTFail("Expected resolvedToSingle, got \(res.action)")
        }
    }

    func testResolveRenameCompositeToNewName() {
        let manager = SpeakerRoleManager()
        let names = ["s1": "Jim"]

        // 输入新名字 "Alice"，候选 s2 还未命名，应分配给 s2
        let res = manager.resolveRename(fromRoleKey: "s1+s2", inputName: "Alice", currentSpeakerNames: names)
        if case .resolvedToSingle(let fromKey, let toKey, let unifiedName, let targetSpeakerID) = res.action {
            XCTAssertEqual(fromKey, "s1+s2")
            XCTAssertEqual(toKey, "s2")
            XCTAssertEqual(unifiedName, "Alice")
            XCTAssertEqual(targetSpeakerID, 1)
            XCTAssertEqual(res.updatedNames["s2"], "Alice")
        } else {
            XCTFail("Expected resolvedToSingle, got \(res.action)")
        }
    }

    func testPlaybackEngineRenameCompositeSpeakerForSpecificSegment() {
        let engine = PlaybackEngine()

        let seg1 = SentenceSegment(
            index: 1,
            startTime: 0,
            endTime: 2,
            text: "Hello",
            speakerIDs: [0, 1],
            isSpeakerOverlap: true
        )
        let seg2 = SentenceSegment(
            index: 2,
            startTime: 2,
            endTime: 4,
            text: "World",
            speakerIDs: [0, 1],
            isSpeakerOverlap: true
        )
        engine.segments = [seg1, seg2]

        XCTAssertEqual(engine.segments[0].speakerRoleLabel, "s1+s2")
        XCTAssertEqual(engine.segments[1].speakerRoleLabel, "s1+s2")

        // 精准将 seg1 的复合角色修改为 s1
        engine.renameSpeaker(fromRole: "s1+s2", toName: "s1", scope: .thisSentenceOnly, segmentID: seg1.id)

        // seg1 变为单人 s1，不再是 overlap
        XCTAssertEqual(engine.segments[0].speakerID, 0)
        XCTAssertEqual(engine.segments[0].speakerIDs, [0])
        XCTAssertFalse(engine.segments[0].isSpeakerOverlap)
        XCTAssertEqual(engine.segments[0].speakerRoleLabel, "s1")

        // seg2 依然保持原始复合状态
        XCTAssertEqual(engine.segments[1].speakerIDs, [0, 1])
        XCTAssertTrue(engine.segments[1].isSpeakerOverlap)
        XCTAssertEqual(engine.segments[1].speakerRoleLabel, "s1+s2")

        // 精准将 seg2 的复合角色修改为 Jim
        engine.renameSpeaker(fromRole: "s1+s2", toName: "Jim", scope: .thisSentenceOnly, segmentID: seg2.id)
        XCTAssertEqual(engine.segments[1].speakerRole, "Jim")
        XCTAssertFalse(engine.segments[1].isSpeakerOverlap)
        XCTAssertEqual(engine.segments[1].speakerRoleLabel, "Jim")
    }

    func testPlaybackEngineRenameCompositeSpeakerGlobalFallback() {
        let engine = PlaybackEngine()

        let seg1 = SentenceSegment(
            index: 1,
            startTime: 0,
            endTime: 2,
            text: "Hello",
            speakerIDs: [0, 1],
            isSpeakerOverlap: true
        )
        let seg2 = SentenceSegment(
            index: 2,
            startTime: 2,
            endTime: 4,
            text: "World",
            speakerIDs: [0, 1],
            isSpeakerOverlap: true
        )
        engine.segments = [seg1, seg2]

        // 未传 segmentID 时，全局修改所有匹配该角色的断句
        engine.renameSpeaker(fromRole: "s1+s2", toName: "s2")

        XCTAssertEqual(engine.segments[0].speakerID, 1)
        XCTAssertEqual(engine.segments[0].speakerIDs, [1])
        XCTAssertFalse(engine.segments[0].isSpeakerOverlap)
        XCTAssertEqual(engine.segments[0].speakerRoleLabel, "s2")

        XCTAssertEqual(engine.segments[1].speakerID, 1)
        XCTAssertEqual(engine.segments[1].speakerIDs, [1])
        XCTAssertFalse(engine.segments[1].isSpeakerOverlap)
        XCTAssertEqual(engine.segments[1].speakerRoleLabel, "s2")
    }

    func testResolveSingleSentenceSpeaker() {
        let manager = SpeakerRoleManager()
        let names = ["s1": "Jim", "s2": "Tom"]

        let segS1 = SentenceSegment(index: 1, startTime: 0, endTime: 2, speakerIDs: [0])

        // 1. 单句将 s1 改为 s2
        let res1 = manager.resolveSingleSentenceSpeaker(currentSegment: segS1, inputName: "s2", currentSpeakerNames: names)
        XCTAssertEqual(res1.speakerID, 1)
        XCTAssertEqual(res1.speakerIDs, [1])
        XCTAssertFalse(res1.isOverlap)
        XCTAssertEqual(res1.speakerRole, "Tom")
        XCTAssertEqual(res1.displayName, "Tom")

        // 2. 单句将 s1 改为已有姓名 "Tom"
        let res2 = manager.resolveSingleSentenceSpeaker(currentSegment: segS1, inputName: "Tom", currentSpeakerNames: names)
        XCTAssertEqual(res2.speakerID, 1)
        XCTAssertEqual(res2.speakerIDs, [1])
        XCTAssertFalse(res2.isOverlap)
        XCTAssertEqual(res2.speakerRole, "Tom")

        // 3. 单句将 s1 改为全新姓名 "Alice"（由于 s1 已经叫 Jim，应分配新 ID s3）
        let res3 = manager.resolveSingleSentenceSpeaker(currentSegment: segS1, inputName: "Alice", currentSpeakerNames: names)
        XCTAssertEqual(res3.speakerID, 2)
        XCTAssertEqual(res3.speakerIDs, [2])
        XCTAssertEqual(res3.speakerRole, "Alice")
        XCTAssertEqual(res3.updatedNames["s3"], "Alice")
    }

    func testPlaybackEngineRenameSingleSentenceScopeVsAllMatchingScope() {
        let engine = PlaybackEngine()

        let seg1 = SentenceSegment(
            index: 1,
            startTime: 0,
            endTime: 2,
            text: "Sentence 1",
            speakerIDs: [0]
        )
        let seg2 = SentenceSegment(
            index: 2,
            startTime: 2,
            endTime: 4,
            text: "Sentence 2",
            speakerIDs: [0]
        )
        engine.segments = [seg1, seg2]

        // 场景 1：仅修改第 1 句的角色为 s2
        engine.renameSpeaker(fromRole: "s1", toName: "s2", scope: .thisSentenceOnly, segmentID: seg1.id)

        // 验证：第 1 句变为 s2，第 2 句依然是 s1
        XCTAssertEqual(engine.segments[0].speakerID, 1)
        XCTAssertEqual(engine.segments[0].speakerRoleLabel, "s2")
        XCTAssertEqual(engine.segments[1].speakerID, 0)
        XCTAssertEqual(engine.segments[1].speakerRoleLabel, "s1")

        // 场景 2：修改所有相同角色（将剩下的所有 s1 改名为 Jim）
        engine.renameSpeaker(fromRole: "s1", toName: "Jim", scope: .allMatching, segmentID: seg2.id)

        // 验证：第 1 句依然是 s2 未被污染；第 2 句变为 Jim
        XCTAssertEqual(engine.segments[0].speakerID, 1)
        XCTAssertEqual(engine.segments[0].speakerRoleLabel, "s2")
        XCTAssertEqual(engine.segments[1].speakerID, 0)
        XCTAssertEqual(engine.segments[1].speakerRole, "Jim")
        XCTAssertEqual(engine.segments[1].speakerRoleLabel, "Jim")
    }
}

