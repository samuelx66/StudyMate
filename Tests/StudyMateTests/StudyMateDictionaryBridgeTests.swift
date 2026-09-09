import XCTest
@testable import StudyMateKit

final class StudyMateDictionaryBridgeTests: XCTestCase {
    @MainActor
    func testMakeLookupURLWithWord() {
        let url = StudyMateDictionaryBridge.makeLookupURL(query: "phenomenon")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.scheme, "studymatedict")
        XCTAssertEqual(url?.host, "lookup")
        
        let components = URLComponents(url: url!, resolvingAgainstBaseURL: true)
        let word = components?.queryItems?.first(where: { $0.name == "word" })?.value
        XCTAssertEqual(word, "phenomenon")
    }

    @MainActor
    func testMakeLookupURLWithEmptyOrNilQuery() {
        let urlNil = StudyMateDictionaryBridge.makeLookupURL(query: nil)
        XCTAssertNotNil(urlNil)
        XCTAssertEqual(urlNil?.scheme, "studymatedict")
        XCTAssertEqual(urlNil?.host, "open")

        let urlEmpty = StudyMateDictionaryBridge.makeLookupURL(query: "   ")
        XCTAssertNotNil(urlEmpty)
        XCTAssertEqual(urlEmpty?.scheme, "studymatedict")
        XCTAssertEqual(urlEmpty?.host, "open")
    }

    @MainActor
    func testLocateDictionaryApp() {
        let appURL = StudyMateDictionaryBridge.locateDictionaryApp()
        XCTAssertNotNil(appURL, "应当能定位到 Embedded/StudyMateDictionary.app 或开发目录下的词典程序")
        if let appURL {
            XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))
            XCTAssertTrue(appURL.lastPathComponent.contains("StudyMateDictionary"))
        }
    }

    @MainActor
    func testLookupScopeDictionaryIDSettings() {
        let settings = DictionarySourceSettings.shared
        let original = settings.lookupScopeDictionaryID

        settings.setLookupScopeDictionaryID("test-dict-id")
        XCTAssertEqual(settings.lookupScopeDictionaryID, "test-dict-id")

        settings.setLookupScopeDictionaryID(nil)
        XCTAssertNil(settings.lookupScopeDictionaryID)

        settings.setLookupScopeDictionaryID(original)
    }

    @MainActor
    func testLocateEmbeddedDictionaryApp() {
        let embeddedURL = StudyMateDictionaryBridge.locateEmbeddedDictionaryApp()
        XCTAssertNotNil(embeddedURL, "应当能定位到内置或工程目录下的词典程序实体")
        if let embeddedURL {
            XCTAssertTrue(FileManager.default.fileExists(atPath: embeddedURL.path))
        }
    }

    @MainActor
    func testSymbolicLinkDetection() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetFile = tempDir.appendingPathComponent("target.txt")
        try "test".write(to: targetFile, atomically: true, encoding: .utf8)

        let linkFile = tempDir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: linkFile, withDestinationURL: targetFile)

        XCTAssertFalse(StudyMateDictionaryBridge.isSymbolicLink(at: targetFile))
        XCTAssertTrue(StudyMateDictionaryBridge.isSymbolicLink(at: linkFile))
    }

    @MainActor
    func testShortcutPathsAndConstants() {
        XCTAssertEqual(StudyMateDictionaryBridge.shortcutFileName, "StudyMateDictionary.app")
        XCTAssertEqual(StudyMateDictionaryBridge.shortcutPreferenceDomainKey, "StudyMate.CreateDictionaryShortcutInApplications")
        let shortcutURL = StudyMateDictionaryBridge.dictionaryShortcutURL()
        XCTAssertTrue(shortcutURL.path.hasSuffix("StudyMateDictionary.app"))
    }

    @MainActor
    func testSynchronizeShortcutResetsPreferenceWhenDeletedInFinder() {
        let key = StudyMateDictionaryBridge.shortcutPreferenceDomainKey
        let original = UserDefaults.standard.bool(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }

        UserDefaults.standard.set(true, forKey: key)
        if !StudyMateDictionaryBridge.isDictionaryShortcutInstalled() {
            StudyMateDictionaryBridge.synchronizeShortcutIfNeeded()
            XCTAssertFalse(UserDefaults.standard.bool(forKey: key), "当磁盘上不存在词典应用时，启动同步应当尊重用户手动删除意图，将偏好同步为 false")
        }
    }
}
