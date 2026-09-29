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
            originalIndex: 88,
            original: "Where is the station?\nPlease.",
            translation: "车站在哪里？",
            phoneticText: "wɛər ɪz ðə ˈsteɪʃən?",
            note: "保留换行",
            isBookmarked: true,
            tags: ["口语", "旅行"],
            associatedWords: [StudyMatePackageVocabularyCard(word: "station", phonetic: "/ˈsteɪʃən/", definition: "n. 车站")],
            contextBefore: "Excuse me.",
            contextAfter: "Go straight ahead.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            audio: StudyMatePackageAudioReference(assetID: entryID, endMs: 1200),
            source: StudyMatePackageSourceReference(mediaTitle: "lesson.mp3", originalStartMs: 2400, originalEndMs: 3600),
            preview: StudyMatePackagePreviewReference(path: "Previews/\(entryID.uuidString).jpg", timestamp: 1.5),
            speaker: StudyMatePackageSpeakerReference(id: 0, name: "Jim", ids: [0], isOverlap: false),
            wordTokens: [
                StudyMatePackageWordToken(text: "Where", startTime: 0.1, endTime: 0.4),
                StudyMatePackageWordToken(text: "station", startTime: 0.5, endTime: 1.1)
            ]
        )
        let session = StudyMatePackageSessionState(
            lastPlayedEntryID: entryID,
            lastPlayedIndex: 1,
            lastUpdatedPlatform: "macOS",
            lastUpdatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let package = try StudyMateLearningPackage.make(
            collectionID: collectionID,
            title: "旅行英语",
            scope: "selected",
            entries: [entry],
            assets: [StudyMatePackageAssetInput(id: entryID, data: audio, durationMs: 1200)],
            previews: [entryID: Data([0xff, 0xd8, 0xff, 0xe0])],
            sourceLanguage: "en",
            translationLanguage: "zh-Hans",
            videoAspectRatio: "16:9",
            speakerNames: ["s1": "Jim"],
            session: session,
            producerPlatform: "macOS"
        )

        // 1. 测试单文件 ZIP 归档往返
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mablib")
        defer { try? FileManager.default.removeItem(at: zipURL) }
        try package.write(to: zipURL, asDirectory: false)
        let restoredZip = try StudyMateLearningPackage.load(from: zipURL)

        XCTAssertEqual(restoredZip.manifest.collection.id, collectionID)
        XCTAssertEqual(restoredZip.manifest.videoAspectRatio, "16:9")
        XCTAssertEqual(restoredZip.manifest.speakerNames?["s1"], "Jim")
        XCTAssertEqual(restoredZip.manifest.session?.lastPlayedIndex, 1)
        XCTAssertEqual(restoredZip.content.entries.count, 1)
        let restoredEntry = restoredZip.content.entries[0]
        XCTAssertEqual(restoredEntry.originalIndex, 88)
        XCTAssertEqual(restoredEntry.phoneticText, "wɛər ɪz ðə ˈsteɪʃən?")
        XCTAssertTrue(restoredEntry.isBookmarked)
        XCTAssertEqual(restoredEntry.tags, ["口语", "旅行"])
        XCTAssertEqual(restoredEntry.contextBefore, "Excuse me.")
        XCTAssertEqual(restoredEntry.associatedWords?.first?.word, "station")
        XCTAssertEqual(restoredEntry.wordTokens?.count, 2)
        XCTAssertEqual(restoredZip.assetData[entryID], audio)
        XCTAssertEqual(restoredZip.previewData[entryID], Data([0xff, 0xd8, 0xff, 0xe0]))

        // 2. 测试目录包 Bundle 往返
        let dirURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mablib")
        defer { try? FileManager.default.removeItem(at: dirURL) }
        try package.write(to: dirURL, asDirectory: true)
        let restoredDir = try StudyMateLearningPackage.load(from: dirURL)
        XCTAssertEqual(restoredDir.manifest.collection.id, collectionID)
        XCTAssertEqual(restoredDir.content.entries.count, 1)
        XCTAssertEqual(restoredDir.assetData[entryID], audio)
        XCTAssertEqual(restoredDir.previewData[entryID], Data([0xff, 0xd8, 0xff, 0xe0]))
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
