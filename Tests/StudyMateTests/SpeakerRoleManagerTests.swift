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

    func testResolveRenameAndMergeMismatchedSpeakerRole() {
        let engine = PlaybackEngine()

        // 模拟用户工程中的数据：
        // 若干句子的 speakerID 是 5，但 speakerRole 被设置为 "s10"
        let seg1 = SentenceSegment(
            index: 12,
            startTime: 0,
            endTime: 2,
            text: "Sentence 12",
            speakerID: 5,
            speakerIDs: [5],
            speakerRole: "s10"
        )
        let seg2 = SentenceSegment(
            index: 13,
            startTime: 2,
            endTime: 4,
            text: "Sentence 13",
            speakerID: 5,
            speakerIDs: [5],
            speakerRole: "s10"
        )
        // 目标角色：speakerID 是 10，speakerRole 是 "Richard"
        let segTarget = SentenceSegment(
            index: 65,
            startTime: 10,
            endTime: 12,
            text: "Sentence 65",
            speakerID: 10,
            speakerIDs: [10],
            speakerRole: "Richard"
        )
        engine.segments = [seg1, seg2, segTarget]

        XCTAssertEqual(engine.segments[0].speakerRoleLabel, "s10")
        XCTAssertEqual(engine.segments[1].speakerRoleLabel, "s10")
        XCTAssertEqual(engine.segments[2].speakerRoleLabel, "Richard")

        // 用户在第 13 句（角色标签为 s10）输入 "Richard"，选择所有相同角色
        engine.renameSpeaker(fromRole: "s10", toName: "Richard", scope: .allMatching, segmentID: seg2.id)

        // 验证：所有原 s10 的句子都成功合并至 Richard (ID: 10)
        XCTAssertEqual(engine.segments[0].speakerID, 10)
        XCTAssertEqual(engine.segments[0].speakerIDs, [10])
        XCTAssertEqual(engine.segments[0].speakerRole, "Richard")
        XCTAssertEqual(engine.segments[0].speakerRoleLabel, "Richard")

        XCTAssertEqual(engine.segments[1].speakerID, 10)
        XCTAssertEqual(engine.segments[1].speakerIDs, [10])
        XCTAssertEqual(engine.segments[1].speakerRole, "Richard")
        XCTAssertEqual(engine.segments[1].speakerRoleLabel, "Richard")

        // 目标句子本身也保持为 Richard
        XCTAssertEqual(engine.segments[2].speakerID, 10)
        XCTAssertEqual(engine.segments[2].speakerRole, "Richard")
        XCTAssertEqual(engine.segments[2].speakerRoleLabel, "Richard")
    }

    func testMergeCustomNameToRoleKey() {
        let engine = PlaybackEngine()

        let segCustom = SentenceSegment(
            index: 1,
            startTime: 0,
            endTime: 2,
            text: "Sentence 1",
            speakerID: 6,
            speakerIDs: [6],
            speakerRole: "Mrs. Vann"
        )
        let segTarget = SentenceSegment(
            index: 2,
            startTime: 2,
            endTime: 4,
            text: "Sentence 2",
            speakerID: 0,
            speakerIDs: [0]
        )
        engine.segments = [segCustom, segTarget]

        XCTAssertEqual(engine.segments[0].speakerRoleLabel, "Mrs. Vann")
        XCTAssertEqual(engine.segments[1].speakerRoleLabel, "s1")

        // 将 Mrs. Vann 合并到 s1
        engine.renameSpeaker(fromRole: "Mrs. Vann", toName: "s1", scope: .allMatching)

        XCTAssertEqual(engine.segments[0].speakerID, 0)
        XCTAssertEqual(engine.segments[0].speakerIDs, [0])
        XCTAssertEqual(engine.segments[0].speakerRoleLabel, "s1")
    }

    func testResolveRenameSameNameReturnsUnchanged() {
        let manager = SpeakerRoleManager()
        let names = ["s1": "Jim", "s2": "Tom"]

        let res = manager.resolveRename(fromRoleKey: "s1", inputName: "Jim", currentSpeakerNames: names)
        XCTAssertEqual(res.action, .unchanged)

        let resExact = manager.resolveRename(fromRoleKey: "Jim", inputName: "Jim", currentSpeakerNames: names)
        XCTAssertEqual(resExact.action, .unchanged)
    }

    func testResolveRenameRevertToDefaultRole() {
        let manager = SpeakerRoleManager()
        var names = ["s1": "Alice", "s2": "Bob"]

        // 1. 将 Alice 重命名回 s1
        let res = manager.resolveRename(fromRoleKey: "Alice", inputName: "s1", currentSpeakerNames: names)
        if case .renamed(let roleKey, let newName) = res.action {
            XCTAssertEqual(roleKey, "s1")
            XCTAssertEqual(newName, "s1")
            XCTAssertNil(res.updatedNames["s1"])
            XCTAssertNil(res.updatedNames["Alice"])
        } else {
            XCTFail("Expected renamed back to s1, got \(res.action)")
        }

        // 2. 将 s1（当前名称 Alice）通过 key 重置为 "s1"
        let res2 = manager.resolveRename(fromRoleKey: "s1", inputName: "s1", currentSpeakerNames: names)
        if case .renamed(let roleKey, let newName) = res2.action {
            XCTAssertEqual(roleKey, "s1")
            XCTAssertEqual(newName, "s1")
            XCTAssertNil(res2.updatedNames["s1"])
        } else {
            XCTFail("Expected renamed back to s1, got \(res2.action)")
        }
    }

    func testResolveRenameSecondaryRenameCleansOldKey() {
        let manager = SpeakerRoleManager()
        let names = ["s1": "Alice", "s2": "Bob"]

        // 将 Alice 改为 Carol，更新的 names 应该保存 s1: Carol，且不能有 Alice: Carol
        let res = manager.resolveRename(fromRoleKey: "Alice", inputName: "Carol", currentSpeakerNames: names)
        if case .renamed(let roleKey, let newName) = res.action {
            XCTAssertEqual(roleKey, "s1")
            XCTAssertEqual(newName, "Carol")
            XCTAssertEqual(res.updatedNames["s1"], "Carol")
            XCTAssertNil(res.updatedNames["Alice"])
        } else {
            XCTFail("Expected renamed to Carol, got \(res.action)")
        }
    }

    func testResolveSingleSentenceSpeakerDoesNotPolluteExistingKeys() {
        let manager = SpeakerRoleManager()
        let names = ["s1": "Alice"]
        let allIDs: Set<Int> = [0]

        // 针对某一句单独指定新名字 "David"，不应修改 s1 的 Alice
        let res = manager.resolveSingleSentenceSpeaker(
            currentRoleLabel: "Alice",
            currentRole: "Alice",
            currentSpeakerIDs: [0],
            newName: "David",
            currentSpeakerNames: names,
            allExistingSpeakerIDs: allIDs
        )

        XCTAssertEqual(res.speakerRole, "David")
        XCTAssertEqual(res.speakerID, 1)
        XCTAssertEqual(res.speakerIDs, [1])
        XCTAssertEqual(res.updatedNames["s1"], "Alice")
        XCTAssertEqual(res.updatedNames["s2"], "David")
    }

    func testEngineAssignUnassignedSentenceToSpeaker() {
        let engine = PlaybackEngine()

        let seg1 = SentenceSegment(index: 1, startTime: 0, endTime: 2, text: "Hello", speakerID: 0, speakerIDs: [0], speakerRole: "Alice")
        let seg2 = SentenceSegment(index: 2, startTime: 2, endTime: 4, text: "Unassigned", speakerID: nil, speakerIDs: [], speakerRole: nil)
        engine.segments = [seg1, seg2]

        XCTAssertEqual(engine.segments[0].speakerRoleLabel, "Alice")
        XCTAssertEqual(engine.segments[1].speakerRoleLabel, "")

        // 为 seg2 分配 Alice (仅此句)
        engine.renameSpeaker(fromRole: "", toName: "Alice", scope: .thisSentenceOnly, segmentID: seg2.id)

        XCTAssertEqual(engine.segments[1].speakerRoleLabel, "Alice")
        XCTAssertEqual(engine.segments[1].speakerID, 0)
        XCTAssertEqual(engine.segments[1].speakerIDs, [0])
    }
}

