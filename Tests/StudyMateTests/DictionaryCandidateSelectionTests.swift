import XCTest
@testable import StudyMateKit

final class DictionaryCandidateSelectionTests: XCTestCase {
    private func hit(
        _ key: String,
        dictionaryID: String,
        title: String? = nil
    ) -> StudyMateDictionarySearchHit {
        StudyMateDictionarySearchHit(
            key: key,
            dictionaryID: dictionaryID,
            dictionaryTitle: title ?? dictionaryID
        )
    }

    func testExactKeyWinsAfterCaseAndWhitespaceNormalization() {
        let candidates = [
            hit("hello world example", dictionaryID: "first"),
            hit("  Hello   World ", dictionaryID: "second")
        ]

        let selected = DictionaryCandidateSelection.resolve(
            query: " HELLO WORLD ",
            candidates: candidates,
            dictionaryID: nil
        )

        XCTAssertEqual(selected?.key, "  Hello   World ")
        XCTAssertEqual(selected?.dictionaryID, "second")
    }

    func testOriginalCaseExactKeyWinsBeforeCaseInsensitiveFallback() {
        let candidates = [
            hit("Relate", dictionaryID: "oald9"),
            hit("relate", dictionaryID: "oald9")
        ]

        let selected = DictionaryCandidateSelection.resolve(
            query: "relate",
            candidates: candidates,
            dictionaryID: nil
        )

        XCTAssertEqual(selected?.key, "relate")
    }

    func testAllModeUsesOwningDictionaryIDFromSelectedCandidate() {
        let candidates = [
            hit("word", dictionaryID: "oald9", title: "OALD9"),
            hit("word", dictionaryID: "the-little-dict", title: "TheLittleDict")
        ]

        let selected = DictionaryCandidateSelection.resolve(
            query: "word",
            candidates: candidates,
            dictionaryID: nil
        )

        XCTAssertEqual(selected?.dictionaryID, "oald9")
        XCTAssertEqual(selected?.id, "oald9:word")
    }

    func testSelectedDictionaryScopesExactMatch() {
        let candidates = [
            hit("word", dictionaryID: "first"),
            hit("word", dictionaryID: "second")
        ]

        let selected = DictionaryCandidateSelection.resolve(
            query: "WORD",
            candidates: candidates,
            dictionaryID: "second"
        )

        XCTAssertEqual(selected?.dictionaryID, "second")
    }

    @MainActor
    func testRepeatedLookupRequestsHaveDistinctLifecycleIDs() {
        let engine = DictionaryEngine(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("StudyMate-CandidateSelectionTests-\(UUID().uuidString)")
        )

        engine.requestLookup("word")
        let firstID = engine.lookupRequestID
        XCTAssertEqual(engine.consumeRequestedQuery(), "word")

        engine.requestLookup("word")
        XCTAssertGreaterThan(engine.lookupRequestID, firstID)
        XCTAssertEqual(engine.consumeRequestedQuery(), "word")
    }

}
