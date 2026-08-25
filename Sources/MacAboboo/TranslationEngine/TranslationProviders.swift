import Foundation

public final class TranslationHTTPClient: @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func post(
        url: URL,
        headers: [String: String],
        body: Data
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return try await perform(request)
    }

    public func get(
        url: URL,
        headers: [String: String]
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        // Gemini/Anthropic 等服务在高峰期会短暂返回 429/5xx。短暂重试只针对
        // 这类可恢复状态，避免把真正的鉴权、请求格式或模型不存在错误重复发送。
        let maximumAttempts = 3
        var attempt = 1

        while true {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TranslationProviderError.invalidResponse("网络响应不是 HTTP 响应。")
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard Self.isRetryableHTTPStatus(httpResponse.statusCode),
                      attempt < maximumAttempts else {
                    throw TranslationProviderError.httpStatus(
                        httpResponse.statusCode,
                        String(message.prefix(800))
                    )
                }

                let delay = Self.retryDelay(
                    attempt: attempt,
                    retryAfter: httpResponse.value(forHTTPHeaderField: "Retry-After")
                )
                try await Task.sleep(nanoseconds: delay)
                attempt += 1
                continue
            }
            return data
        }
    }

    private static func isRetryableHTTPStatus(_ status: Int) -> Bool {
        status == 408 || status == 425 || status == 429 || (500...504).contains(status)
    }

    private static func retryDelay(attempt: Int, retryAfter: String?) -> UInt64 {
        if let retryAfter,
           let seconds = Double(retryAfter.trimmingCharacters(in: .whitespacesAndNewlines)),
           seconds.isFinite,
           seconds >= 0 {
            return UInt64(min(seconds, 30) * 1_000_000_000)
        }

        // 0.8s、1.6s，配合少量抖动，避免多个请求同时重试造成再次拥塞。
        let base = pow(2.0, Double(max(0, attempt - 1))) * 0.8
        let jitter = Double.random(in: 0...0.25)
        return UInt64(min(base + jitter, 30) * 1_000_000_000)
    }
}

enum TranslationEndpointBuilder {
    static func baseURL(
        rawValue: String,
        defaultValue: String,
        removingSuffixes suffixes: [String]
    ) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? defaultValue : trimmed
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false else { return nil }

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in suffixes {
            let normalizedSuffix = suffix.hasPrefix("/") ? suffix : "/\(suffix)"
            if path.hasSuffix(normalizedSuffix) {
                path = String(path.dropLast(normalizedSuffix.count))
                while path.hasSuffix("/") { path.removeLast() }
                break
            }
        }
        components.path = path
        return components.url
    }

    static func resolveEndpoint(
        rawValue: String?,
        relativeTo base: URL,
        defaultPath: String
    ) -> URL? {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return appending(defaultPath, to: base)
        }
        if let absolute = baseURL(rawValue: trimmed, defaultValue: trimmed, removingSuffixes: []) {
            return absolute
        }
        guard let relative = URLComponents(string: trimmed) else { return nil }
        let path = relative.percentEncodedPath.isEmpty
            ? defaultPath
            : relative.percentEncodedPath
        return appendingPercentEncodedPath(
            path,
            query: relative.percentEncodedQuery,
            to: base
        )
    }

    static func resolveModelEndpoint(
        rawValue: String?,
        relativeTo base: URL,
        model: String,
        defaultEndpoint: () -> URL?
    ) -> URL? {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return defaultEndpoint() }
        let marker = "__MACABOBOO_MODEL__"
        let replaced = trimmed.replacingOccurrences(of: "{model}", with: marker)
        guard let endpoint = resolveEndpoint(rawValue: replaced, relativeTo: base, defaultPath: ""),
              let modelPath = encodedPathComponent(model),
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.percentEncodedPath = components.percentEncodedPath
            .replacingOccurrences(of: marker, with: modelPath)
        return components.url
    }

    static func appending(_ path: String, to base: URL) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        let suffix = path.hasPrefix("/") ? path : "/\(path)"
        components.path = basePath + suffix
        return components.url
    }

    static func appendingPercentEncodedPath(
        _ path: String,
        query: String? = nil,
        to base: URL
    ) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let relative = URLComponents(string: path) else {
            return nil
        }
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        let suffix = relative.percentEncodedPath.hasPrefix("/")
            ? relative.percentEncodedPath
            : "/\(relative.percentEncodedPath)"
        components.percentEncodedPath = basePath + suffix
        components.percentEncodedQuery = query
        return components.url
    }

    static func appendingPathSuffix(_ suffix: String, to base: URL) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.percentEncodedPath += suffix
        return components.url
    }

    static func addingQueryItem(_ name: String, value: String, to url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: name, value: value))
        components.queryItems = items
        return components.url
    }

    static func authorized(
        url: URL,
        configuration: TranslationConfiguration
    ) -> (url: URL, headers: [String: String])? {
        switch configuration.authentication {
        case .bearer:
            return (url, ["Authorization": "Bearer \(configuration.apiKey)"])
        case .apiKeyHeader:
            let header = configuration.authenticationHeader.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !header.isEmpty else { return nil }
            return (url, [header: configuration.apiKey])
        case .apiKeyQuery:
            guard let authorizedURL = addingQueryItem("key", value: configuration.apiKey, to: url) else {
                return nil
            }
            return (authorizedURL, [:])
        case .none:
            return (url, [:])
        }
    }

    static func encodedPathComponent(_ value: String) -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}

/// 简单、明确的点号 JSON 路径读取器，例如：`data`、`choices.0.message.content`。
public enum TranslationJSONPath {
    public static func value(in object: Any, path: String) -> Any? {
        let components = path
            .split(separator: ".")
            .map(String.init)
        guard !components.isEmpty else { return object }

        var current: Any = object
        for component in components {
            if let index = Int(component), let array = current as? [Any], array.indices.contains(index) {
                current = array[index]
            } else if let dictionary = current as? [String: Any], let value = dictionary[component] {
                current = value
            } else {
                return nil
            }
        }
        return current
    }
}

public enum TranslationPromptBuilder {
    public static func prompt(for request: TranslationBatchRequest) throws -> String {
        let sourcePayload = request.units.map { [
            "id": $0.id.uuidString,
            "source": $0.sourceText
        ] }
        let data = try JSONSerialization.data(withJSONObject: sourcePayload, options: [.sortedKeys])
        let sourceJSON = String(decoding: data, as: UTF8.self)
        let sourceName = request.sourceLanguage == "auto" || request.sourceLanguage.isEmpty
            ? "the detected source language"
            : request.sourceLanguage
        return """
        You are a professional subtitle translator. Translate every item from \(sourceName) into \(request.targetLanguage.promptName).
        Preserve the meaning, names, tone, and line breaks when useful. Do not explain your choices, do not merge or split items, and do not translate the IDs.
        Return only valid JSON in exactly this shape: {"translations":[{"id":"UUID","text":"translated text"}]}.
        The output must contain one translation object for every input item, using the same IDs.
        Input items:
        \(sourceJSON)
        """
    }
}

public enum TranslationResponseParser {
    public static func parse(text: String, expectedIDs: Set<UUID>) throws -> [TranslationResult] {
        let cleaned = cleanJSONText(text)
        guard let data = cleaned.data(using: .utf8) else {
            throw TranslationProviderError.invalidResponse("返回内容不是 UTF-8 文本。")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw TranslationProviderError.invalidResponse("返回内容不是有效 JSON。")
        }

        let rows: [[String: Any]]
        if let array = object as? [[String: Any]] {
            rows = array
        } else if let dictionary = object as? [String: Any],
                  let nested = dictionary["translations"] as? [[String: Any]]
            ?? dictionary["results"] as? [[String: Any]]
            ?? dictionary["items"] as? [[String: Any]] {
            rows = nested
        } else {
            throw TranslationProviderError.invalidResponse("JSON 中缺少 translations 数组。")
        }

        var results: [TranslationResult] = []
        var seen = Set<UUID>()
        for row in rows {
            guard let idString = row["id"] as? String,
                  let id = UUID(uuidString: idString),
                  expectedIDs.contains(id),
                  !seen.contains(id) else { continue }
            let translated = (row["text"] as? String)
                ?? (row["translation"] as? String)
                ?? (row["translated_text"] as? String)
            guard let translated else { continue }
            let normalized = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            results.append(TranslationResult(id: id, translatedText: normalized))
            seen.insert(id)
        }
        guard !results.isEmpty else { throw TranslationProviderError.emptyResponse }
        return results
    }

    public static func text(from data: Data, path: String) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let value = TranslationJSONPath.value(in: object, path: path) else {
            throw TranslationProviderError.invalidResponse("翻译响应中找不到配置的 JSON 路径：\(path)")
        }
        if let text = value as? String {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { throw TranslationProviderError.emptyResponse }
            return normalized
        }
        throw TranslationProviderError.invalidResponse("翻译响应路径不是文本：\(path)")
    }

    private static func cleanJSONText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.components(separatedBy: .newlines)
        if !lines.isEmpty { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum TranslationModelListParser {
    public static func parseOpenAICompatible(data: Data) throws -> [TranslationModelDescriptor] {
        try parseCompatible(
            data: data,
            listPath: "data",
            idPath: "id",
            displayPath: "id",
            ownedByPath: "owned_by",
            stripModelsPrefix: false
        )
    }

    public static func parseGemini(data: Data) throws -> [TranslationModelDescriptor] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let models = TranslationJSONPath.value(in: object, path: "models") as? [Any] else {
            throw TranslationProviderError.invalidResponse("Gemini 模型列表不是有效 JSON。")
        }
        let descriptors = models.compactMap { item -> TranslationModelDescriptor? in
            guard let row = item as? [String: Any],
                  let rawName = row["name"] as? String,
                  !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let methods = row["supportedGenerationMethods"] as? [String] ?? []
            guard methods.isEmpty || methods.contains("generateContent") else { return nil }
            let id = rawName.hasPrefix("models/")
                ? String(rawName.dropFirst("models/".count))
                : rawName
            return TranslationModelDescriptor(
                id: id,
                displayName: row["displayName"] as? String,
                ownedBy: row["baseModelId"] as? String
            )
        }
        guard !descriptors.isEmpty else { throw TranslationProviderError.emptyModelList }
        return descriptors
    }

    public static func parseCompatible(
        data: Data,
        listPath: String,
        idPath: String,
        displayPath: String? = nil,
        ownedByPath: String? = nil,
        stripModelsPrefix: Bool
    ) throws -> [TranslationModelDescriptor] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let values = TranslationJSONPath.value(in: object, path: listPath) as? [Any] else {
            throw TranslationProviderError.invalidResponse("模型列表找不到配置的 JSON 路径：\(listPath)")
        }
        let descriptors = values.compactMap { item -> TranslationModelDescriptor? in
            guard let idValue = TranslationJSONPath.value(in: item, path: idPath),
                  let rawID = idValue as? String else { return nil }
            let normalizedID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty else { return nil }
            let id = stripModelsPrefix && normalizedID.hasPrefix("models/")
                ? String(normalizedID.dropFirst("models/".count))
                : normalizedID
            let display = displayPath.flatMap { TranslationJSONPath.value(in: item, path: $0) as? String }
            let ownedBy = ownedByPath.flatMap { TranslationJSONPath.value(in: item, path: $0) as? String }
            return TranslationModelDescriptor(id: id, displayName: display, ownedBy: ownedBy)
        }
        guard !descriptors.isEmpty else { throw TranslationProviderError.emptyModelList }
        return descriptors
    }
}

/// OpenAI-compatible generic adapter。DeepSeek、OpenRouter、硅基流动及其它
/// 兼容服务都可以复用同一实现，差异通过 profile 的地址、认证和 JSON 路径配置。
public struct OpenAICompatibleTranslationProvider: TranslationProvider {
    public let id: TranslationProviderID
    private let httpClient: TranslationHTTPClient
    private let configuredServerURL: URL

    public init(
        id: TranslationProviderID = .openAICompatible,
        httpClient: TranslationHTTPClient = TranslationHTTPClient(),
        serverURL: URL? = nil,
        endpoint: URL? = nil
    ) {
        self.id = id
        self.httpClient = httpClient
        self.configuredServerURL = serverURL
            ?? endpoint
            ?? URL(string: id.defaultServerURL)!
    }

    public func translate(
        request: TranslationBatchRequest,
        configuration: TranslationConfiguration
    ) async throws -> [TranslationResult] {
        guard !configuration.apiKey.isEmpty else { throw TranslationProviderError.missingAPIKey }
        guard !request.units.isEmpty else { return [] }
        guard let base = TranslationEndpointBuilder.baseURL(
            rawValue: configuration.serverURL,
            defaultValue: configuredServerURL.absoluteString,
            removingSuffixes: ["/chat/completions", "/models"]
        ), let endpoint = TranslationEndpointBuilder.resolveEndpoint(
            rawValue: configuration.translationURL,
            relativeTo: base,
            defaultPath: "chat/completions"
        ), let authorized = TranslationEndpointBuilder.authorized(
            url: endpoint,
            configuration: configuration
        ) else {
            throw TranslationProviderError.invalidEndpoint
        }

        let prompt = try TranslationPromptBuilder.prompt(for: request)
        let body: [String: Any] = [
            "model": configuration.model,
            "messages": [
                ["role": "system", "content": "Return JSON only. Never include Markdown fences."],
                ["role": "user", "content": prompt]
            ],
            "stream": false,
            "temperature": 0.2,
            "max_tokens": max(512, request.units.count * 160),
            "response_format": ["type": "json_object"]
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        let responseData = try await httpClient.post(
            url: authorized.url,
            headers: authorized.headers,
            body: data
        )
        let content = try TranslationResponseParser.text(
            from: responseData,
            path: configuration.translationResponseJSONPath
        )
        return try TranslationResponseParser.parse(
            text: content,
            expectedIDs: Set(request.units.map(\.id))
        )
    }

    public func listModels(
        configuration: TranslationConfiguration
    ) async throws -> [TranslationModelDescriptor] {
        guard !configuration.apiKey.isEmpty else { throw TranslationProviderError.missingAPIKey }
        guard let base = TranslationEndpointBuilder.baseURL(
            rawValue: configuration.serverURL,
            defaultValue: configuredServerURL.absoluteString,
            removingSuffixes: ["/chat/completions", "/models"]
        ), let endpoint = TranslationEndpointBuilder.resolveEndpoint(
            rawValue: configuration.modelsURL,
            relativeTo: base,
            defaultPath: "models"
        ), let authorized = TranslationEndpointBuilder.authorized(
            url: endpoint,
            configuration: configuration
        ) else {
            throw TranslationProviderError.invalidEndpoint
        }
        let data = try await httpClient.get(url: authorized.url, headers: authorized.headers)
        return try TranslationModelListParser.parseCompatible(
            data: data,
            listPath: configuration.modelListJSONPath,
            idPath: configuration.modelIDJSONPath,
            displayPath: configuration.modelIDJSONPath,
            ownedByPath: "owned_by",
            stripModelsPrefix: false
        )
    }
}

/// Gemini 的 REST 适配器。第三方 Gemini-compatible 网关也可以通过覆盖
/// endpoint、认证方式和 JSON 路径加入服务列表。
public struct GeminiTranslationProvider: TranslationProvider {
    public let id: TranslationProviderID = .gemini
    private let httpClient: TranslationHTTPClient
    private let configuredServerURL: URL

    public init(
        httpClient: TranslationHTTPClient = TranslationHTTPClient(),
        baseURL: URL? = nil,
        serverURL: URL? = nil
    ) {
        self.httpClient = httpClient
        self.configuredServerURL = serverURL
            ?? baseURL
            ?? URL(string: TranslationProviderID.gemini.defaultServerURL)!
    }

    public func translate(
        request: TranslationBatchRequest,
        configuration: TranslationConfiguration
    ) async throws -> [TranslationResult] {
        guard !configuration.apiKey.isEmpty else { throw TranslationProviderError.missingAPIKey }
        guard !request.units.isEmpty else { return [] }
        guard let base = TranslationEndpointBuilder.baseURL(
            rawValue: configuration.serverURL,
            defaultValue: configuredServerURL.absoluteString,
            removingSuffixes: ["/models"]
        ), let endpoint = TranslationEndpointBuilder.resolveModelEndpoint(
            rawValue: configuration.translationURL,
            relativeTo: base,
            model: configuration.model,
            defaultEndpoint: {
                guard let encodedModel = TranslationEndpointBuilder.encodedPathComponent(
                    configuration.model.hasPrefix("models/")
                        ? String(configuration.model.dropFirst("models/".count))
                        : configuration.model
                ), let modelEndpoint = TranslationEndpointBuilder.appending(
                    "models/\(encodedModel)",
                    to: base
                ) else { return nil }
                return TranslationEndpointBuilder.appendingPathSuffix(
                    ":generateContent",
                    to: modelEndpoint
                )
            }
        ), let authorized = TranslationEndpointBuilder.authorized(
            url: endpoint,
            configuration: configuration
        ) else {
            throw TranslationProviderError.invalidEndpoint
        }

        let prompt = try TranslationPromptBuilder.prompt(for: request)
        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [["text": prompt]]
            ]],
            "generationConfig": [
                "temperature": 0.2,
                "maxOutputTokens": max(512, request.units.count * 160),
                "responseMimeType": "application/json"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        let responseData = try await httpClient.post(
            url: authorized.url,
            headers: authorized.headers,
            body: data
        )
        let text = try TranslationResponseParser.text(
            from: responseData,
            path: configuration.translationResponseJSONPath
        )
        return try TranslationResponseParser.parse(
            text: text,
            expectedIDs: Set(request.units.map(\.id))
        )
    }

    public func listModels(
        configuration: TranslationConfiguration
    ) async throws -> [TranslationModelDescriptor] {
        guard !configuration.apiKey.isEmpty else { throw TranslationProviderError.missingAPIKey }
        guard let base = TranslationEndpointBuilder.baseURL(
            rawValue: configuration.serverURL,
            defaultValue: configuredServerURL.absoluteString,
            removingSuffixes: ["/models"]
        ), let endpoint = TranslationEndpointBuilder.resolveEndpoint(
            rawValue: configuration.modelsURL,
            relativeTo: base,
            defaultPath: "models"
        ), let authorized = TranslationEndpointBuilder.authorized(
            url: endpoint,
            configuration: configuration
        ) else {
            throw TranslationProviderError.invalidEndpoint
        }
        let data = try await httpClient.get(url: authorized.url, headers: authorized.headers)
        if configuration.modelListJSONPath == "models",
           configuration.modelIDJSONPath == "name" {
            return try TranslationModelListParser.parseGemini(data: data)
        }
        return try TranslationModelListParser.parseCompatible(
            data: data,
            listPath: configuration.modelListJSONPath,
            idPath: configuration.modelIDJSONPath,
            displayPath: configuration.modelIDJSONPath,
            ownedByPath: "baseModelId",
            stripModelsPrefix: true
        )
    }
}

/// Anthropic Messages API 适配器。第三方 Anthropic-compatible 网关只需将
/// Base URL 指向网关地址即可复用同一配置；模型列表使用 `/v1/models`。
public struct AnthropicTranslationProvider: TranslationProvider {
    public let id: TranslationProviderID = .anthropic
    private let httpClient: TranslationHTTPClient
    private let configuredServerURL: URL

    public init(
        httpClient: TranslationHTTPClient = TranslationHTTPClient(),
        serverURL: URL? = nil
    ) {
        self.httpClient = httpClient
        self.configuredServerURL = serverURL
            ?? URL(string: TranslationProviderID.anthropic.defaultServerURL)!
    }

    public func translate(
        request: TranslationBatchRequest,
        configuration: TranslationConfiguration
    ) async throws -> [TranslationResult] {
        guard !configuration.apiKey.isEmpty else { throw TranslationProviderError.missingAPIKey }
        guard !request.units.isEmpty else { return [] }
        guard let base = TranslationEndpointBuilder.baseURL(
            rawValue: configuration.serverURL,
            defaultValue: configuredServerURL.absoluteString,
            removingSuffixes: ["/v1/messages", "/v1/models", "/v1"]
        ), let endpoint = TranslationEndpointBuilder.resolveEndpoint(
            rawValue: configuration.translationURL,
            relativeTo: base,
            defaultPath: "v1/messages"
        ), let authorized = TranslationEndpointBuilder.authorized(
            url: endpoint,
            configuration: configuration
        ) else {
            throw TranslationProviderError.invalidEndpoint
        }

        let prompt = try TranslationPromptBuilder.prompt(for: request)
        let body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": max(512, request.units.count * 160),
            "messages": [[
                "role": "user",
                "content": prompt
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        var headers = authorized.headers
        headers["anthropic-version"] = "2023-06-01"
        let responseData = try await httpClient.post(
            url: authorized.url,
            headers: headers,
            body: data
        )
        let text = try TranslationResponseParser.text(
            from: responseData,
            path: configuration.translationResponseJSONPath
        )
        return try TranslationResponseParser.parse(
            text: text,
            expectedIDs: Set(request.units.map(\.id))
        )
    }

    public func listModels(
        configuration: TranslationConfiguration
    ) async throws -> [TranslationModelDescriptor] {
        guard !configuration.apiKey.isEmpty else { throw TranslationProviderError.missingAPIKey }
        guard let base = TranslationEndpointBuilder.baseURL(
            rawValue: configuration.serverURL,
            defaultValue: configuredServerURL.absoluteString,
            removingSuffixes: ["/v1/messages", "/v1/models", "/v1"]
        ), let endpoint = TranslationEndpointBuilder.resolveEndpoint(
            rawValue: configuration.modelsURL,
            relativeTo: base,
            defaultPath: "v1/models"
        ), let authorized = TranslationEndpointBuilder.authorized(
            url: endpoint,
            configuration: configuration
        ) else {
            throw TranslationProviderError.invalidEndpoint
        }

        var headers = authorized.headers
        headers["anthropic-version"] = "2023-06-01"
        let data = try await httpClient.get(url: authorized.url, headers: headers)
        return try TranslationModelListParser.parseCompatible(
            data: data,
            listPath: configuration.modelListJSONPath,
            idPath: configuration.modelIDJSONPath,
            displayPath: "display_name",
            ownedByPath: nil,
            stripModelsPrefix: false
        )
    }
}

/// 旧名称保留为 DeepSeek 的兼容包装，避免外部调用方升级时失效。
public struct DeepSeekTranslationProvider: TranslationProvider {
    public let id: TranslationProviderID = .deepSeek
    private let implementation: OpenAICompatibleTranslationProvider

    public init(
        httpClient: TranslationHTTPClient = TranslationHTTPClient(),
        endpoint: URL? = nil,
        serverURL: URL? = nil
    ) {
        self.implementation = OpenAICompatibleTranslationProvider(
            id: .deepSeek,
            httpClient: httpClient,
            serverURL: serverURL,
            endpoint: endpoint
        )
    }

    public func translate(
        request: TranslationBatchRequest,
        configuration: TranslationConfiguration
    ) async throws -> [TranslationResult] {
        try await implementation.translate(request: request, configuration: configuration)
    }

    public func listModels(
        configuration: TranslationConfiguration
    ) async throws -> [TranslationModelDescriptor] {
        try await implementation.listModels(configuration: configuration)
    }
}
