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
            let currentUnits = Array(normalized[offset..<end])
            let request = TranslationBatchRequest(
                units: currentUnits,
                sourceLanguage: sourceLanguage,
                targetLanguage: configuration.targetLanguage
            )
            let expectedIDs = Set(currentUnits.map(\.id))

            var batchResults: [TranslationResult] = []
            do {
                batchResults = try await provider.translate(
                    request: request,
                    configuration: configuration
                )
            } catch {
                // 如果整批失败且批次较大，尝试二分拆批重试，提升长批次容错能力
                if currentUnits.count > 10 {
                    let half = currentUnits.count / 2
                    let req1 = TranslationBatchRequest(
                        units: Array(currentUnits[0..<half]),
                        sourceLanguage: sourceLanguage,
                        targetLanguage: configuration.targetLanguage
                    )
                    let req2 = TranslationBatchRequest(
                        units: Array(currentUnits[half..<currentUnits.count]),
                        sourceLanguage: sourceLanguage,
                        targetLanguage: configuration.targetLanguage
                    )
                    let res1 = (try? await provider.translate(request: req1, configuration: configuration)) ?? []
                    let res2 = (try? await provider.translate(request: req2, configuration: configuration)) ?? []
                    batchResults = res1 + res2
                } else {
                    throw error
                }
            }

            var matchedResults = batchResults.filter { expectedIDs.contains($0.id) }
            let returnedIDs = Set(matchedResults.map(\.id))
            let missingUnits = currentUnits.filter { !returnedIDs.contains($0.id) }

            // 如果大模型漏掉了少量 ID，针对缺失的句子进行一次快速补全重试
            if !missingUnits.isEmpty {
                let retryRequest = TranslationBatchRequest(
                    units: missingUnits,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: configuration.targetLanguage
                )
                if let retryResults = try? await provider.translate(
                    request: retryRequest,
                    configuration: configuration
                ) {
                    let missingIDs = Set(missingUnits.map(\.id))
                    let validRetries = retryResults.filter { missingIDs.contains($0.id) }
                    matchedResults.append(contentsOf: validRetries)
                }
            }

            // 最终若仍有个别未返回，生成空译文兜底，保证条目完整且绝不中断整篇翻译
            let finalReturnedIDs = Set(matchedResults.map(\.id))
            for unit in currentUnits where !finalReturnedIDs.contains(unit.id) {
                matchedResults.append(TranslationResult(id: unit.id, translatedText: ""))
            }

            results.append(contentsOf: matchedResults)
            if let onBatchCompleted {
                await onBatchCompleted(matchedResults)
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
