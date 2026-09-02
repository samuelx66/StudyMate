import XCTest
@testable import StudyMateKit

final class DictionaryPronunciationResolverTests: XCTestCase {
    private func dictionary(_ id: String) -> StudyMateDictionarySummary {
        StudyMateDictionarySummary(
            id: id,
            title: id,
            encoding: "UTF-8",
            format: "MDX",
            entryCount: 0,
            resourceCount: 0,
            importedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func resource(path: String) -> StudyMateDictionaryResource {
        StudyMateDictionaryResource(key: "\\audio/test.mp3", path: path, size: 1)
    }

    func testFirstDictionaryHitWins() async throws {
        let first = dictionary("first")
        let second = dictionary("second")
        let firstURL = URL(fileURLWithPath: "/tmp/first.mp3")
        let queried = QueryRecorder(resources: [
            first.id: resource(path: firstURL.path),
            second.id: resource(path: "/tmp/second.mp3")
        ])

        let result = try await DictionaryPronunciationResolver.firstReadableURL(
            in: [first, second],
            word: "test",
            lookup: { dictionary, _ in try await queried.lookup(dictionary.id) },
            isReadable: { $0 == firstURL }
        )

        let queryIDs = await queried.ids()
        XCTAssertEqual(result, firstURL)
        XCTAssertEqual(queryIDs, [first.id])
    }

    func testSecondDictionaryHitIsUsedWhenFirstHasNoAudio() async throws {
        let first = dictionary("first")
        let second = dictionary("second")
        let secondURL = URL(fileURLWithPath: "/tmp/second.mp3")
        let queried = QueryRecorder(resources: [
            second.id: resource(path: secondURL.path)
        ])

        let result = try await DictionaryPronunciationResolver.firstReadableURL(
            in: [first, second],
            word: "test",
            lookup: { dictionary, _ in try await queried.lookup(dictionary.id) },
            isReadable: { $0 == secondURL }
        )

        let queryIDs = await queried.ids()
        XCTAssertEqual(result, secondURL)
        XCTAssertEqual(queryIDs, [first.id, second.id])
    }

    func testAllDictionariesWithoutAudioReturnNil() async throws {
        let dictionaries = [dictionary("first"), dictionary("second"), dictionary("third")]
        let queried = QueryRecorder(resources: [:])

        let result = try await DictionaryPronunciationResolver.firstReadableURL(
            in: dictionaries,
            word: "test",
            lookup: { dictionary, _ in try await queried.lookup(dictionary.id) },
            isReadable: { _ in true }
        )

        let queryIDs = await queried.ids()
        XCTAssertNil(result)
        XCTAssertEqual(queryIDs, dictionaries.map(\.id))
    }

    func testFailedDictionaryLookupContinuesToNextDictionary() async throws {
        let first = dictionary("first")
        let second = dictionary("second")
        let secondURL = URL(fileURLWithPath: "/tmp/second.mp3")
        let queried = QueryRecorder(
            resources: [second.id: resource(path: secondURL.path)],
            failures: [first.id]
        )

        let result = try await DictionaryPronunciationResolver.firstReadableURL(
            in: [first, second],
            word: "test",
            lookup: { dictionary, _ in try await queried.lookup(dictionary.id) },
            isReadable: { $0 == secondURL }
        )

        let queryIDs = await queried.ids()
        XCTAssertEqual(result, secondURL)
        XCTAssertEqual(queryIDs, [first.id, second.id])
    }
}

private actor QueryRecorder {
    private let resources: [String: StudyMateDictionaryResource]
    private let failures: Set<String>
    private var queriedIDs: [String] = []

    init(
        resources: [String: StudyMateDictionaryResource],
        failures: Set<String> = []
    ) {
        self.resources = resources
        self.failures = failures
    }

    func lookup(_ id: String) throws -> StudyMateDictionaryResource? {
        queriedIDs.append(id)
        if failures.contains(id) {
            throw TestLookupError.failedDictionary(id)
        }
        return resources[id]
    }

    func ids() -> [String] {
        queriedIDs
    }
}

private enum TestLookupError: Error {
    case failedDictionary(String)
}
