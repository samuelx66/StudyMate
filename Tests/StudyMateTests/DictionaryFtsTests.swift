import XCTest
@testable import StudyMateKit

final class DictionaryFtsTests: XCTestCase {
    func testSearchScopeValues() {
        XCTAssertEqual(DictionarySearchScope.headword.id, "headword")
        XCTAssertEqual(DictionarySearchScope.fullText.id, "fullText")
        XCTAssertEqual(DictionarySearchScope.allCases.count, 2)
    }

    func testFtsStatusDecoding() throws {
        let jsonReady = """
        {
            "dictionary_id": "test-dict",
            "status": "ready",
            "entry_count": 5000,
            "indexed_entries": 5000
        }
        """.data(using: .utf8)!

        let statusReady = try JSONDecoder().decode(StudyMateFtsStatus.self, from: jsonReady)
        XCTAssertEqual(statusReady.dictionaryID, "test-dict")
        XCTAssertEqual(statusReady.status, "ready")
        XCTAssertEqual(statusReady.entryCount, 5000)
        XCTAssertEqual(statusReady.indexedEntries, 5000)
        XCTAssertTrue(statusReady.isReady)
        XCTAssertFalse(statusReady.isIndexing)
        XCTAssertFalse(statusReady.isNone)

        let jsonNone = """
        {
            "dictionary_id": "test-dict-2",
            "status": "none",
            "entry_count": 1200,
            "indexed_entries": 0
        }
        """.data(using: .utf8)!

        let statusNone = try JSONDecoder().decode(StudyMateFtsStatus.self, from: jsonNone)
        XCTAssertTrue(statusNone.isNone)
        XCTAssertFalse(statusNone.isReady)
        XCTAssertFalse(statusNone.isIndexing)
    }

    func testFtsHitDecodingAndSnippetFormatting() throws {
        let json = """
        {
            "id": "dict1_42",
            "key": "take off",
            "snippet": "The plane will <b>take off</b> at six o'clock.",
            "dictionary_id": "dict1",
            "dictionary_title": "Oxford Advanced Learner's Dictionary",
            "resource_root": "studymate-resource://dict1"
        }
        """.data(using: .utf8)!

        let hit = try JSONDecoder().decode(StudyMateDictionaryFtsHit.self, from: json)
        XCTAssertEqual(hit.id, "dict1_42")
        XCTAssertEqual(hit.key, "take off")
        XCTAssertEqual(hit.dictionaryID, "dict1")
        XCTAssertEqual(hit.dictionaryTitle, "Oxford Advanced Learner's Dictionary")
        XCTAssertEqual(hit.resourceRoot, "studymate-resource://dict1")

        // Verify snippet extraction
        let attr = hit.attributedSnippet
        let plain = String(attr.characters)
        XCTAssertEqual(plain, "The plane will take off at six o'clock.")
    }
}
