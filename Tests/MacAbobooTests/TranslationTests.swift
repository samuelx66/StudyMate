import XCTest
@testable import MacAbobooKit

@MainActor
final class TranslationTests: XCTestCase {
    func testPromptContainsStableIDsSourceTextAndTargetLanguage() throws {
        let id = UUID()
        let request = TranslationBatchRequest(
            units: [TranslationUnit(id: id, sourceText: "Hello, world!")],
            sourceLanguage: "en",
            targetLanguage: .simplifiedChinese
        )

        let prompt = try TranslationPromptBuilder.prompt(for: request)

        XCTAssertTrue(prompt.contains(id.uuidString))
        XCTAssertTrue(prompt.contains("Hello, world!"))
        XCTAssertTrue(prompt.contains("Simplified Chinese"))
        XCTAssertTrue(prompt.contains("valid JSON"))
    }

    func testResponseParserAcceptsEnvelopeAndMarkdownFence() throws {
        let firstID = UUID()
        let secondID = UUID()
        let text = """
        ```json
        {"translations":[
          {"id":"\(firstID.uuidString)","text":"你好"},
          {"id":"\(secondID.uuidString)","translation":"世界"}
        ]}
        ```
        """

        let results = try TranslationResponseParser.parse(
            text: text,
            expectedIDs: [firstID, secondID]
        )

        XCTAssertEqual(Set(results.map(\.id)), [firstID, secondID])
        XCTAssertEqual(results.first(where: { $0.id == firstID })?.translatedText, "你好")
        XCTAssertEqual(results.first(where: { $0.id == secondID })?.translatedText, "世界")
    }

    func testResponseParserIgnoresUnknownAndEmptyRows() throws {
        let id = UUID()
        let unknownID = UUID()
        let text = """
        {"translations":[
          {"id":"\(unknownID.uuidString)","text":"不应写入"},
          {"id":"\(id.uuidString)","text":"  有效译文  "},
          {"id":"\(id.uuidString)","text":"重复结果"},
          {"id":"\(UUID().uuidString)","text":"   "}
        ]}
        """

        let results = try TranslationResponseParser.parse(text: text, expectedIDs: [id])

        XCTAssertEqual(results, [TranslationResult(id: id, translatedText: "有效译文")])
    }

    func testProviderDefaultsAreIndependent() {
        XCTAssertNotEqual(TranslationProviderID.deepSeek.defaultModel, TranslationProviderID.gemini.defaultModel)
        XCTAssertNotEqual(TranslationProviderID.deepSeek.keychainAccount, TranslationProviderID.gemini.keychainAccount)
        XCTAssertEqual(TranslationProviderID.deepSeek.defaultServerURL, "https://api.deepseek.com")
        XCTAssertEqual(TranslationProviderID.gemini.defaultServerURL, "https://generativelanguage.googleapis.com/v1beta")
        XCTAssertTrue(TranslationProviderID.allCases.contains(.openAICompatible))
        XCTAssertTrue(TranslationProviderID.allCases.contains(.anthropic))
        XCTAssertTrue(TranslationProviderID.allCases.contains(.customHTTP))
        XCTAssertEqual(TranslationProviderID.gemini.defaultAuthentication, .apiKeyHeader)
        XCTAssertEqual(TranslationProviderID.deepSeek.defaultAuthentication, .bearer)
        XCTAssertEqual(TranslationProviderID.anthropic.defaultServerURL, "https://api.anthropic.com")
        XCTAssertEqual(TranslationProviderID.anthropic.defaultAuthenticationHeader, "x-api-key")
        XCTAssertEqual(TranslationProviderID.anthropic.defaultTranslationResponseJSONPath, "content.0.text")
        XCTAssertEqual(TranslationProviderID.customProtocolCases, [.openAICompatible, .anthropic])
        XCTAssertTrue(TranslationProviderID.deepSeek.isBuiltIn)
        XCTAssertTrue(TranslationProviderID.gemini.isBuiltIn)
        XCTAssertFalse(TranslationProviderID.anthropic.isBuiltIn)
    }

    func testProviderEndpointsAreDerivedFromBaseURL() {
        let deepSeekBase = TranslationEndpointBuilder.baseURL(
            rawValue: "https://api.deepseek.com",
            defaultValue: TranslationProviderID.deepSeek.defaultServerURL,
            removingSuffixes: ["/chat/completions", "/models"]
        )!
        XCTAssertEqual(
            TranslationEndpointBuilder.appending("chat/completions", to: deepSeekBase)?.absoluteString,
            "https://api.deepseek.com/chat/completions"
        )
        XCTAssertEqual(
            TranslationEndpointBuilder.appending("models", to: deepSeekBase)?.absoluteString,
            "https://api.deepseek.com/models"
        )

        let legacyGeminiBase = TranslationEndpointBuilder.baseURL(
            rawValue: "https://generativelanguage.googleapis.com/v1beta/models/",
            defaultValue: TranslationProviderID.gemini.defaultServerURL,
            removingSuffixes: ["/models"]
        )!
        XCTAssertEqual(
            TranslationEndpointBuilder.appending("models/gemini-2.5-flash", to: legacyGeminiBase)?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash"
        )

        XCTAssertEqual(
            TranslationEndpointBuilder.resolveEndpoint(
                rawValue: "/proxy/chat/completions",
                relativeTo: deepSeekBase,
                defaultPath: "chat/completions"
            )?.absoluteString,
            "https://api.deepseek.com/proxy/chat/completions"
        )
        XCTAssertEqual(
            TranslationEndpointBuilder.resolveModelEndpoint(
                rawValue: "/models/{model}:generateContent",
                relativeTo: legacyGeminiBase,
                model: "gemini/flash test",
                defaultEndpoint: { nil }
            )?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini%2Fflash%20test:generateContent"
        )
    }

    func testModelListParsersFilterAndNormalizeOfficialResponses() throws {
        let deepSeekData = Data("""
        {"object":"list","data":[
          {"id":"deepseek-v4-flash","object":"model","owned_by":"deepseek"},
          {"id":"deepseek-v4-pro","object":"model","owned_by":"deepseek"}
        ]}
        """.utf8)
        let deepSeekModels = try TranslationModelListParser.parseOpenAICompatible(data: deepSeekData)
        XCTAssertEqual(deepSeekModels.map(\.id), ["deepseek-v4-flash", "deepseek-v4-pro"])

        let geminiData = Data("""
        {"models":[
          {"name":"models/gemini-2.5-flash","displayName":"Gemini 2.5 Flash","supportedGenerationMethods":["generateContent"]},
          {"name":"models/text-embedding-004","supportedGenerationMethods":["embedContent"]}
        ]}
        """.utf8)
        let geminiModels = try TranslationModelListParser.parseGemini(data: geminiData)
        XCTAssertEqual(geminiModels.map(\.id), ["gemini-2.5-flash"])
        XCTAssertEqual(geminiModels.first?.displayName, "Gemini 2.5 Flash")

        let anthropicData = Data("""
        {"data":[
          {"id":"claude-sonnet-4-5","display_name":"Claude Sonnet"},
          {"id":"claude-haiku-4-5","display_name":"Claude Haiku"}
        ]}
        """.utf8)
        let anthropicModels = try TranslationModelListParser.parseCompatible(
            data: anthropicData,
            listPath: "data",
            idPath: "id",
            displayPath: "display_name",
            ownedByPath: nil,
            stripModelsPrefix: false
        )
        XCTAssertEqual(anthropicModels.map(\.id), ["claude-sonnet-4-5", "claude-haiku-4-5"])
        XCTAssertEqual(anthropicModels.first?.displayName, "Claude Sonnet")
    }

    func testLegacyServiceProfileDefaultsToProviderServerURL() throws {
        let id = UUID()
        let legacyJSON = Data("""
        {"id":"\(id.uuidString)","name":"旧服务","provider":"deepseek","model":"deepseek-v4-flash","targetLanguage":"zh-Hans"}
        """.utf8)
        let profile = try JSONDecoder().decode(TranslationServiceProfile.self, from: legacyJSON)
        XCTAssertEqual(profile.serverURL, TranslationProviderID.deepSeek.defaultServerURL)

        let custom = TranslationServiceProfile(
            id: id,
            name: "自定义代理",
            provider: .deepSeek,
            model: "custom-model",
            serverURL: "https://example.test/v1"
        )
        let configuration = TranslationConfiguration(
            provider: custom.provider,
            model: custom.model,
            apiKey: "key",
            targetLanguage: custom.targetLanguage,
            serverURL: custom.serverURL
        )
        XCTAssertEqual(configuration.serverURL, "https://example.test/v1")
    }

    func testCustomServiceProfilePersistsProtocolEndpointsAndJSONPaths() throws {
        let profile = TranslationServiceProfile(
            name: "第三方网关",
            provider: .openAICompatible,
            model: "qwen-max",
            serverURL: "https://gateway.example/v1",
            modelsURL: "/models",
            translationURL: "/chat/completions",
            authentication: .apiKeyHeader,
            authenticationHeader: "X-Token",
            modelListJSONPath: "result.models",
            modelIDJSONPath: "name",
            translationResponseJSONPath: "output.0.text",
            targetLanguage: .english
        )

        let data = try JSONEncoder().encode(profile)
        let restored = try JSONDecoder().decode(TranslationServiceProfile.self, from: data)
        XCTAssertEqual(restored, profile)
        XCTAssertEqual(restored.modelsURL, "/models")
        XCTAssertEqual(restored.authenticationHeader, "X-Token")
        XCTAssertEqual(restored.translationResponseJSONPath, "output.0.text")
    }

    func testJSONPathSupportsNestedDictionariesAndArrays() {
        let object: [String: Any] = [
            "result": [
                "items": [["name": "first"], ["name": "second"]]
            ]
        ]
        XCTAssertEqual(
            TranslationJSONPath.value(in: object, path: "result.items.1.name") as? String,
            "second"
        )
    }

    func testTranslationServiceProfilesCanBeAddedReorderedAndRemoved() {
        let suiteName = "MacAboboo.TranslationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = TranslationSettings(defaults: defaults)
        XCTAssertEqual(settings.services.count, 2)

        let addedID = settings.addCustomModel(
            modelName: "第三方 OpenAI 模型",
            protocolID: .openAICompatible,
            baseURL: "https://gateway.example/v1",
            apiKey: "test-key"
        )
        XCTAssertEqual(settings.selectedServiceID, addedID)
        XCTAssertEqual(settings.selectedService?.model, "第三方 OpenAI 模型")
        XCTAssertEqual(settings.selectedService?.provider, .openAICompatible)
        XCTAssertEqual(settings.selectedService?.serverURL, "https://gateway.example/v1")

        settings.moveServices(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(settings.services.first?.id, addedID)

        let restored = TranslationSettings(defaults: defaults)
        XCTAssertEqual(restored.services.first?.id, addedID)
        XCTAssertEqual(restored.services.first?.name, "第三方 OpenAI 模型")

        settings.rememberTranslationService(addedID)
        settings.rememberTranslationTargetLanguage(.english)
        let restoredExecutionPreferences = TranslationSettings(defaults: defaults)
        XCTAssertEqual(restoredExecutionPreferences.lastTranslationServiceID, addedID)
        XCTAssertEqual(restoredExecutionPreferences.lastTranslationTargetLanguage, .english)

        settings.removeService(id: addedID)
        XCTAssertFalse(settings.services.contains(where: { $0.id == addedID }))

        let builtInID = TranslationServiceProfile.builtInDefaults()[0].id
        settings.removeService(id: builtInID)
        XCTAssertTrue(settings.services.contains(where: { $0.id == builtInID }))
    }
}
