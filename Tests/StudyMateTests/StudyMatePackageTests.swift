import XCTest
@testable import StudyMatePackage

final class StudyMatePackageTests: XCTestCase {
    func testRoundTripKeepsTextIdentityAndBinaryAudio() throws {
        let collectionID = UUID()
        let entryID = UUID()
        let audio = Data([0x00, 0x01, 0x02, 0xff, 0x10])
        let entry = StudyMatePackageEntry(
            id: entryID,
            originCollectionID: collectionID,
            order: 0,
            original: "Where is the station?\nPlease.",
            translation: "车站在哪里？",
            note: "保留换行",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            audio: StudyMatePackageAudioReference(assetID: entryID, endMs: 1200),
            source: StudyMatePackageSourceReference(mediaTitle: "lesson.mp3", originalStartMs: 2400, originalEndMs: 3600)
        )
        let package = try StudyMateLearningPackage.make(
            collectionID: collectionID,
            title: "旅行英语",
            scope: "selected",
            entries: [entry],
            assets: [StudyMatePackageAssetInput(id: entryID, data: audio, durationMs: 1200)],
            sourceLanguage: "en",
            translationLanguage: "zh-Hans",
            producerPlatform: "macOS"
        )

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mabstudy")
        defer { try? FileManager.default.removeItem(at: url) }
        try package.write(to: url)
        let restored = try StudyMateLearningPackage.load(from: url)

        XCTAssertEqual(restored.manifest.collection.id, collectionID)
        XCTAssertEqual(restored.content.entries, [entry])
        XCTAssertEqual(restored.assetData[entryID], audio)
    }

    func testPackageDataCanBeBuilt() throws {
        let entryID = UUID()
        let collectionID = UUID()
        let entry = StudyMatePackageEntry(
            id: entryID,
            originCollectionID: collectionID,
            order: 0,
            original: "hello",
            translation: "你好",
            createdAt: Date(),
            audio: StudyMatePackageAudioReference(assetID: entryID, endMs: 100)
        )
        let package = try StudyMateLearningPackage.make(
            collectionID: collectionID,
            title: "安全测试",
            scope: "all",
            entries: [entry],
            assets: [StudyMatePackageAssetInput(id: entryID, data: Data([1]), durationMs: 100)],
            producerPlatform: "iOS"
        )
        XCTAssertNoThrow(try package.zipData())
    }
}
