import Foundation

/// 翻译服务使用的协议适配器类型，而不是固定的厂商列表。
///
/// DeepSeek 和 Gemini 是内置服务；第三方模型可选择 OpenAI 或 Anthropic 协议。
/// 这里的 ID 表示请求协议适配器，服务名称和 Base URL 由用户配置。
public enum TranslationProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    /// 仅用于兼容旧版本配置；新的第三方 OpenAI 风格服务使用 `.openAICompatible`。
    case deepSeek = "deepseek"
    case gemini = "gemini"
    case openAICompatible = "openai-compatible"
    case anthropic = "anthropic"
    /// 兼容旧版本配置；新界面不再显示此协议。
    case customHTTP = "custom-http"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .deepSeek: return "DeepSeek"
        case .gemini: return "Gemini"
        case .openAICompatible: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .customHTTP: return "自定义 HTTP"
        }
    }

    public var defaultModel: String {
        switch self {
        case .deepSeek: return "deepseek-v4-flash"
        case .gemini: return "gemini-3.7-flash"
        case .openAICompatible, .anthropic, .customHTTP: return "model-name"
        }
    }

    /// 用户填写的服务器基础地址。具体接口地址可以通过 profile 覆盖。
    public var defaultServerURL: String {
        switch self {
        case .deepSeek:
            return "https://api.deepseek.com"
        case .gemini:
            return "https://generativelanguage.googleapis.com/v1beta"
        case .openAICompatible:
            return "https://api.example.com/v1"
        case .anthropic:
            return "https://api.anthropic.com"
        case .customHTTP:
            return "https://example.com"
        }
    }

    public var defaultAuthentication: TranslationAuthenticationMethod {
        switch self {
        case .gemini:
            return .apiKeyHeader
        case .anthropic:
            return .apiKeyHeader
        case .deepSeek, .openAICompatible, .customHTTP:
            return .bearer
        }
    }

    public var defaultAuthenticationHeader: String {
        switch self {
        case .gemini: return "x-goog-api-key"
        case .anthropic: return "x-api-key"
        case .customHTTP: return "X-API-Key"
        case .deepSeek, .openAICompatible: return "Authorization"
        }
    }

    public var defaultModelListJSONPath: String {
        self == .gemini ? "models" : "data"
    }

    public var defaultModelIDJSONPath: String {
        self == .gemini ? "name" : "id"
    }

    public var defaultTranslationResponseJSONPath: String {
        switch self {
        case .gemini:
            return "candidates.0.content.parts.0.text"
        case .anthropic:
            return "content.0.text"
        case .deepSeek, .openAICompatible, .customHTTP:
            return "choices.0.message.content"
        }
    }

    public var keychainAccount: String {
        "translation-api-key-\(rawValue)"
    }

    public var defaultServiceName: String {
        switch self {
        case .deepSeek: return "DeepSeek 翻译"
        case .gemini: return "Gemini 翻译"
        case .openAICompatible: return "OpenAI 翻译"
        case .anthropic: return "Anthropic 翻译"
        case .customHTTP: return "自定义翻译服务"
        }
    }

    public static var customProtocolCases: [TranslationProviderID] {
        [.openAICompatible, .anthropic]
    }

    public var isBuiltIn: Bool {
        self == .deepSeek || self == .gemini
    }
}

public enum TranslationAuthenticationMethod: String, CaseIterable, Codable, Identifiable, Sendable {
    case bearer
    case apiKeyHeader
    case apiKeyQuery
    case none

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bearer: return "Bearer Token"
        case .apiKeyHeader: return "API Key 请求头"
        case .apiKeyQuery: return "API Key 查询参数"
        case .none: return "不添加认证"
        }
    }
}

public enum TranslationTargetLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        }
    }

    public var promptName: String {
        switch self {
        case .simplifiedChinese: return "Simplified Chinese (简体中文)"
        case .traditionalChinese: return "Traditional Chinese (繁體中文)"
        case .english: return "English"
        case .japanese: return "Japanese (日本語)"
        case .korean: return "Korean (한국어)"
        }
    }
}

/// 可管理的翻译服务配置。
///
/// `provider` 表示请求协议/适配器，不再表示只能使用某个固定厂商。
/// `modelsURL`、`translationURL` 和 JSON 路径都可以覆盖协议默认值，
/// 因而第三方兼容服务可以完全独立保存自己的接口配置。
public struct TranslationServiceProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var provider: TranslationProviderID
    public var model: String
    public var serverURL: String
    public var modelsURL: String?
    public var translationURL: String?
    public var authentication: TranslationAuthenticationMethod
    public var authenticationHeader: String
    public var modelListJSONPath: String
    public var modelIDJSONPath: String
    public var translationResponseJSONPath: String
    public var targetLanguage: TranslationTargetLanguage

    public var isBuiltIn: Bool { provider.isBuiltIn }

    private enum CodingKeys: String, CodingKey {
        case id, name, provider, model, serverURL, modelsURL, translationURL
        case authentication, authenticationHeader
        case modelListJSONPath, modelIDJSONPath, translationResponseJSONPath
        case targetLanguage
    }

    public init(
        id: UUID = UUID(),
        name: String,
        provider: TranslationProviderID,
        model: String,
        serverURL: String? = nil,
        modelsURL: String? = nil,
        translationURL: String? = nil,
        authentication: TranslationAuthenticationMethod? = nil,
        authenticationHeader: String? = nil,
        modelListJSONPath: String? = nil,
        modelIDJSONPath: String? = nil,
        translationResponseJSONPath: String? = nil,
        targetLanguage: TranslationTargetLanguage = .simplifiedChinese
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.model = model
        self.serverURL = Self.normalizedRequiredURL(serverURL, fallback: provider.defaultServerURL)
        self.modelsURL = Self.normalizedOptional(modelsURL)
        self.translationURL = Self.normalizedOptional(translationURL)
        self.authentication = authentication ?? provider.defaultAuthentication
        self.authenticationHeader = Self.normalizedRequired(
            authenticationHeader,
            fallback: provider.defaultAuthenticationHeader
        )
        self.modelListJSONPath = Self.normalizedRequired(
            modelListJSONPath,
            fallback: provider.defaultModelListJSONPath
        )
        self.modelIDJSONPath = Self.normalizedRequired(
            modelIDJSONPath,
            fallback: provider.defaultModelIDJSONPath
        )
        self.translationResponseJSONPath = Self.normalizedRequired(
            translationResponseJSONPath,
            fallback: provider.defaultTranslationResponseJSONPath
        )
        self.targetLanguage = targetLanguage
    }

    /// 兼容旧版本仅保存 provider/model/serverURL 的 profile。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.provider = try container.decode(TranslationProviderID.self, forKey: .provider)
        self.model = try container.decode(String.self, forKey: .model)
        let decodedServerURL = try container.decodeIfPresent(String.self, forKey: .serverURL)
        self.serverURL = Self.normalizedRequiredURL(decodedServerURL, fallback: provider.defaultServerURL)
        self.modelsURL = Self.normalizedOptional(
            try container.decodeIfPresent(String.self, forKey: .modelsURL)
        )
        self.translationURL = Self.normalizedOptional(
            try container.decodeIfPresent(String.self, forKey: .translationURL)
        )
        self.authentication = try container.decodeIfPresent(
            TranslationAuthenticationMethod.self,
            forKey: .authentication
        ) ?? provider.defaultAuthentication
        self.authenticationHeader = Self.normalizedRequired(
            try container.decodeIfPresent(String.self, forKey: .authenticationHeader),
            fallback: provider.defaultAuthenticationHeader
        )
        self.modelListJSONPath = Self.normalizedRequired(
            try container.decodeIfPresent(String.self, forKey: .modelListJSONPath),
            fallback: provider.defaultModelListJSONPath
        )
        self.modelIDJSONPath = Self.normalizedRequired(
            try container.decodeIfPresent(String.self, forKey: .modelIDJSONPath),
            fallback: provider.defaultModelIDJSONPath
        )
        self.translationResponseJSONPath = Self.normalizedRequired(
            try container.decodeIfPresent(String.self, forKey: .translationResponseJSONPath),
            fallback: provider.defaultTranslationResponseJSONPath
        )
        self.targetLanguage = try container.decodeIfPresent(
            TranslationTargetLanguage.self,
            forKey: .targetLanguage
        ) ?? .simplifiedChinese
    }

    public static func builtInDefaults() -> [TranslationServiceProfile] {
        [
            TranslationServiceProfile(
                id: UUID(uuidString: "A1F7B2C8-1D44-4F96-9A27-2B8E6C0A11D1")!,
                name: TranslationProviderID.deepSeek.defaultServiceName,
                provider: .deepSeek,
                model: TranslationProviderID.deepSeek.defaultModel
            ),
            TranslationServiceProfile(
                id: UUID(uuidString: "C4E92A17-8B53-4D10-B6F2-7E0D9C3348A2")!,
                name: TranslationProviderID.gemini.defaultServiceName,
                provider: .gemini,
                model: TranslationProviderID.gemini.defaultModel
            )
        ]
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedRequired(_ value: String?, fallback: String) -> String {
        normalizedOptional(value) ?? fallback
    }

    private static func normalizedRequiredURL(_ value: String?, fallback: String) -> String {
        normalizedRequired(value, fallback: fallback)
    }
}

public struct TranslationConfiguration: Sendable, Equatable {
    public let provider: TranslationProviderID
    public let model: String
    public let apiKey: String
    public let serverURL: String
    public let modelsURL: String?
    public let translationURL: String?
    public let authentication: TranslationAuthenticationMethod
    public let authenticationHeader: String
    public let modelListJSONPath: String
    public let modelIDJSONPath: String
    public let translationResponseJSONPath: String
    public let targetLanguage: TranslationTargetLanguage

    public init(
        provider: TranslationProviderID,
        model: String,
        apiKey: String,
        targetLanguage: TranslationTargetLanguage,
        serverURL: String? = nil,
        modelsURL: String? = nil,
        translationURL: String? = nil,
        authentication: TranslationAuthenticationMethod? = nil,
        authenticationHeader: String? = nil,
        modelListJSONPath: String? = nil,
        modelIDJSONPath: String? = nil,
        translationResponseJSONPath: String? = nil
    ) {
        self.provider = provider
        self.model = model
        self.apiKey = apiKey
        self.serverURL = serverURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? serverURL!.trimmingCharacters(in: .whitespacesAndNewlines)
            : provider.defaultServerURL
        self.modelsURL = Self.normalizedOptional(modelsURL)
        self.translationURL = Self.normalizedOptional(translationURL)
        self.authentication = authentication ?? provider.defaultAuthentication
        self.authenticationHeader = Self.normalizedRequired(
            authenticationHeader,
            fallback: provider.defaultAuthenticationHeader
        )
        self.modelListJSONPath = Self.normalizedRequired(
            modelListJSONPath,
            fallback: provider.defaultModelListJSONPath
        )
        self.modelIDJSONPath = Self.normalizedRequired(
            modelIDJSONPath,
            fallback: provider.defaultModelIDJSONPath
        )
        self.translationResponseJSONPath = Self.normalizedRequired(
            translationResponseJSONPath,
            fallback: provider.defaultTranslationResponseJSONPath
        )
        self.targetLanguage = targetLanguage
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedRequired(_ value: String?, fallback: String) -> String {
        normalizedOptional(value) ?? fallback
    }
}

public struct TranslationModelDescriptor: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let ownedBy: String?

    public init(id: String, displayName: String? = nil, ownedBy: String? = nil) {
        self.id = id
        let normalizedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = normalizedDisplayName?.isEmpty == false ? normalizedDisplayName! : id
        self.ownedBy = ownedBy
    }
}

public enum TranslationModelFetchState: Equatable, Sendable {
    case idle
    case loading
    case loaded(count: Int)
    case failed(String)
}

public struct TranslationUnit: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sourceText: String

    public init(id: UUID, sourceText: String) {
        self.id = id
        self.sourceText = sourceText
    }
}

public struct TranslationResult: Sendable, Equatable {
    public let id: UUID
    public let translatedText: String

    public init(id: UUID, translatedText: String) {
        self.id = id
        self.translatedText = translatedText
    }
}

public struct TranslationBatchRequest: Sendable, Equatable {
    public let units: [TranslationUnit]
    public let sourceLanguage: String
    public let targetLanguage: TranslationTargetLanguage

    public init(
        units: [TranslationUnit],
        sourceLanguage: String,
        targetLanguage: TranslationTargetLanguage
    ) {
        self.units = units
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }
}

public enum TranslationProviderError: LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case invalidEndpoint
    case httpStatus(Int, String)
    case invalidResponse(String)
    case emptyResponse
    case emptyModelList
    case partialResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "请先在设置中填写翻译服务 API Key。"
        case .invalidEndpoint:
            return "翻译服务地址无效。"
        case let .httpStatus(status, message):
            return message.isEmpty ? "翻译服务请求失败（HTTP \(status)）。" : "翻译服务请求失败（HTTP \(status)）：\(message)"
        case let .invalidResponse(message):
            return message.isEmpty ? "翻译服务返回的数据无法解析。" : "翻译服务返回的数据无法解析：\(message)"
        case .emptyResponse:
            return "翻译服务没有返回有效译文。"
        case .emptyModelList:
            return "翻译服务没有返回可用的生成模型。"
        case .partialResponse:
            return "翻译服务只返回了部分句子的译文。"
        }
    }
}

public protocol TranslationProvider: Sendable {
    var id: TranslationProviderID { get }

    func translate(
        request: TranslationBatchRequest,
        configuration: TranslationConfiguration
    ) async throws -> [TranslationResult]

    func listModels(
        configuration: TranslationConfiguration
    ) async throws -> [TranslationModelDescriptor]
}
