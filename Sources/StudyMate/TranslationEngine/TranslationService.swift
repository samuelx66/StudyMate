import Foundation

/// 统一的批量翻译编排器。按用户指定的小批次串行请求，避免长字幕一次性超过模型上下文或服务限流；
/// provider 本身仍是独立协议适配器；服务地址、认证方式与 JSON 路径由 profile 提供，
/// 因而第三方兼容服务不需要在断句业务中增加新的分支。
public actor TranslationService {
    public static let shared = TranslationService()

    private let providers: [TranslationProviderID: any TranslationProvider]
    private let batchSize: Int

    public init(
        providers: [TranslationProviderID: any TranslationProvider] = [
            .deepSeek: OpenAICompatibleTranslationProvider(id: .deepSeek),
            .gemini: GeminiTranslationProvider(),
            .openAICompatible: OpenAICompatibleTranslationProvider(id: .openAICompatible),
            .anthropic: AnthropicTranslationProvider()
        ],
        batchSize: Int = 100
    ) {
        self.providers = providers
        self.batchSize = max(1, batchSize)
    }

    public func translate(
        units: [TranslationUnit],
        configuration: TranslationConfiguration,
        sourceLanguage: String,
        batchSize requestedBatchSize: Int? = nil,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in },
        onBatchCompleted: (@Sendable ([TranslationResult]) async -> Void)? = nil
    ) async throws -> [TranslationResult] {
        guard !configuration.apiKey.isEmpty else { throw TranslationProviderError.missingAPIKey }
        guard let provider = providers[configuration.provider] else {
            throw TranslationProviderError.invalidResponse("未注册的翻译协议适配器：\(configuration.provider.rawValue)")
        }
        let normalized = units.filter { !$0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !normalized.isEmpty else { return [] }
        let effectiveBatchSize = max(1, requestedBatchSize ?? batchSize)

        progress(0, normalized.count)
        var results: [TranslationResult] = []
        results.reserveCapacity(normalized.count)
        var offset = 0
        while offset < normalized.count {
            try Task.checkCancellation()
            let end = min(normalized.count, offset + effectiveBatchSize)
            let request = TranslationBatchRequest(
                units: Array(normalized[offset..<end]),
                sourceLanguage: sourceLanguage,
                targetLanguage: configuration.targetLanguage
            )
            let batchResults = try await provider.translate(
                request: request,
                configuration: configuration
            )
            let expectedIDs = Set(request.units.map(\.id))
            let returnedIDs = Set(batchResults.map(\.id))
            guard returnedIDs == expectedIDs else {
                throw TranslationProviderError.partialResponse
            }
            results.append(contentsOf: batchResults)
            if let onBatchCompleted {
                await onBatchCompleted(batchResults)
            }
            offset = end
            progress(offset, normalized.count)
        }
        return results
    }

    /// 读取当前服务端实际可用的生成模型。模型发现与翻译请求使用同一套
    /// provider 注册表，因此自定义基础地址也会自动沿用对应协议。
    public func listModels(
        configuration: TranslationConfiguration
    ) async throws -> [TranslationModelDescriptor] {
        guard !configuration.apiKey.isEmpty else {
            throw TranslationProviderError.missingAPIKey
        }
        guard let provider = providers[configuration.provider] else {
            throw TranslationProviderError.invalidResponse("未注册的翻译协议适配器：\(configuration.provider.rawValue)")
        }
        return try await provider.listModels(configuration: configuration)
    }
}
