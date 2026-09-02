import XCTest
@testable import StudyMateKit

final class DictionaryResponseParserTests: XCTestCase {
    func testParserAcceptsBooleanAndNullResults() throws {
        var responses: [(id: String, data: Data?)] = []
        let parser = DictionaryResponseParser { event in
            guard case let .response(id, data, _) = event else { return }
            responses.append((id: id, data: data))
        }

        parser.append(Data((
            "{\"id\":\"delete\",\"ok\":true,\"result\":true}\n" +
            "{\"id\":\"findAudio\",\"ok\":true,\"result\":null}\n" +
            "{\"id\":\"lookup\",\"ok\":true,\"result\":[{\"key\":\"cat\"}]}\n"
        ).utf8))

        XCTAssertEqual(responses.map(\.id), ["delete", "findAudio", "lookup"])
        XCTAssertEqual(
            try JSONDecoder().decode(Bool.self, from: try XCTUnwrap(responses[0].data)),
            true
        )
        XCTAssertEqual(
            String(data: try XCTUnwrap(responses[1].data), encoding: .utf8),
            "null"
        )
        XCTAssertEqual(
            String(data: try XCTUnwrap(responses[2].data), encoding: .utf8),
            "[{\"key\":\"cat\"}]"
        )
    }

    func testResourceDataCanOmitMetadataPath() throws {
        let data = Data(
            "{\"key\":\"audio/meet.mp3\",\"size\":3,\"data_base64\":\"YWJj\",\"mime_type\":\"audio/mpeg\"}".utf8
        )
        let resource = try JSONDecoder().decode(StudyMateDictionaryResource.self, from: data)

        XCTAssertEqual(resource.path, "")
        XCTAssertEqual(resource.size, 3)
        XCTAssertEqual(resource.dataBase64, "YWJj")
        XCTAssertEqual(resource.mimeType, "audio/mpeg")
    }
}
