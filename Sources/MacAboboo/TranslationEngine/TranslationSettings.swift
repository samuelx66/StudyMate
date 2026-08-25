import Foundation
import Security
import Combine

private final class TranslationKeychainStore: @unchecked Sendable {
    static let shared = TranslationKeychainStore()

    private let service = "com.macaboboo.translation"

    func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecItemNotFound else { return }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        _ = SecItemAdd(addQuery as CFDictionary, nil)
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}

/// 翻译偏好、可管理的服务配置与密钥管理。
///
/// “启用翻译功能”只表示允许用户手动发起翻译，不会在断句、导入字幕或打开
/// 工程时自动发起网络请求。普通配置放在 UserDefaults，API Key 只进入 macOS
/// 钥匙串，不会写入工程文件、句库或日志。
@MainActor
public final class TranslationSettings: ObservableObject {
    public static let shared = TranslationSettings()

    private let defaults: UserDefaults
    private let keychain: TranslationKeychainStore
    private let enabledKey = "MacAboboo.Translation.AutomaticEnabled"
    private let servicesKey = "MacAboboo.Translation.Services"
    private let selectedServiceKey = "MacAboboo.Translation.SelectedServiceID"
    private let lastTranslationServiceKey = "MacAboboo.Translation.LastExecutionServiceID"
    private let lastTranslationTargetLanguageKey = "MacAboboo.Translation.LastExecutionTargetLanguage"

    /// 保留原有 UserDefaults 键名，避免升级后丢失用户的开关状态；语义改为
    /// “允许手动翻译”，不再代表打开设置后立即执行翻译。
    @Published public var isAutomaticTranslationEnabled: Bool {
        didSet { defaults.set(isAutomaticTranslationEnabled, forKey: enabledKey) }
    }

    /// 用户可添加、删除和拖动排序的翻译服务配置。
    @Published public private(set) var services: [TranslationServiceProfile] {
        didSet { persistServices() }
    }

    @Published public var selectedServiceID: UUID? {
        didSet {
            if let selectedServiceID {
                defaults.set(selectedServiceID.uuidString, forKey: selectedServiceKey)
            } else {
                defaults.removeObject(forKey: selectedServiceKey)
            }
        }
    }

    /// 断句列表“确认翻译”冒泡面板最近一次使用的服务。它和设置页面当前
    /// 选中的服务分开保存，避免用户在设置中浏览服务时改变翻译面板的默认选择。
    @Published public private(set) var lastTranslationServiceID: UUID?

    /// 断句列表“确认翻译”冒泡面板最近一次使用的目标语言。
    @Published public private(set) var lastTranslationTargetLanguage: TranslationTargetLanguage

    /// 每个服务配置最近一次从服务端获取到的模型列表。列表只保存在内存中，
    /// 因为模型会随服务端变化；服务地址或 API Key 变化后会被清空。
    @Published public private(set) var availableModels: [UUID: [TranslationModelDescriptor]] = [:]
    @Published public private(set) var modelFetchStates: [UUID: TranslationModelFetchState] = [:]

    private var modelFetchTasks: [UUID: Task<Void, Never>] = [:]
    private var modelFetchRequestIDs: [UUID: UUID] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.keychain = .shared
        self.isAutomaticTranslationEnabled = (defaults.object(forKey: enabledKey) as? Bool) ?? false

        let decodedServices = Self.decodeServices(from: defaults.data(forKey: servicesKey))
        let initialServices: [TranslationServiceProfile]
        if let decodedServices, !decodedServices.isEmpty {
            // 保证升级后的配置始终保留两个内置入口；用户添加的自定义 profile
            // 仍按原顺序保留，且不会因为补齐内置项而丢失。
            var migratedServices = decodedServices
            for builtIn in TranslationServiceProfile.builtInDefaults()
                where !migratedServices.contains(where: { $0.provider == builtIn.provider }) {
                migratedServices.insert(builtIn, at: min(migratedServices.count, 1))
            }
            initialServices = migratedServices
        } else {
            let legacyProvider = TranslationProviderID(
                rawValue: defaults.string(forKey: "MacAboboo.Translation.Provider") ?? ""
            ) ?? .deepSeek
            let legacyLanguage = TranslationTargetLanguage(
                rawValue: defaults.string(forKey: "MacAboboo.Translation.TargetLanguage") ?? ""
            ) ?? .simplifiedChinese
            var migratedServices = TranslationServiceProfile.builtInDefaults()
            if let index = migratedServices.firstIndex(where: { $0.provider == legacyProvider }) {
                let legacyModelKey = "MacAboboo.Translation.Model.\(legacyProvider.rawValue)"
                migratedServices[index].model = defaults.string(forKey: legacyModelKey)
                    ?? legacyProvider.defaultModel
                migratedServices[index].targetLanguage = legacyLanguage
            }
            initialServices = migratedServices
        }

        self.services = initialServices

        let storedID = defaults.string(forKey: selectedServiceKey).flatMap(UUID.init(uuidString:))
        let resolvedSelectedServiceID = storedID.flatMap { id in
            initialServices.contains(where: { $0.id == id }) ? id : nil
        } ?? initialServices.first?.id
        self.selectedServiceID = resolvedSelectedServiceID

        let storedExecutionServiceID = defaults
            .string(forKey: lastTranslationServiceKey)
            .flatMap(UUID.init(uuidString:))
        self.lastTranslationServiceID = storedExecutionServiceID.flatMap { id in
            initialServices.contains(where: { $0.id == id }) ? id : nil
        } ?? resolvedSelectedServiceID

        let migratedTargetLanguage = resolvedSelectedServiceID.flatMap { id in
            initialServices.first(where: { $0.id == id })?.targetLanguage
        } ?? .simplifiedChinese
        self.lastTranslationTargetLanguage = TranslationTargetLanguage(
            rawValue: defaults.string(forKey: lastTranslationTargetLanguageKey) ?? ""
        ) ?? migratedTargetLanguage

        // 第一次迁移时，把旧的“按服务商”钥匙串密钥复制到对应的服务配置；
        // 旧条目保留，以便旧版本回滚时仍然可以读取。
        if decodedServices == nil {
            for profile in services {
                let legacyKey = keychain.read(account: profile.provider.keychainAccount)
                if let legacyKey, !legacyKey.isEmpty,
                   keychain.read(account: keychainAccount(for: profile.id)) == nil {
                    keychain.write(legacyKey, account: keychainAccount(for: profile.id))
                }
            }
        }
        persistServices()
    }

    public var selectedService: TranslationServiceProfile? {
        guard let selectedServiceID else { return nil }
        return services.first(where: { $0.id == selectedServiceID })
    }

    /// 记录翻译确认面板最近一次选择的服务。选择发生时立即写入，取消翻译
    /// 也不会丢失这次偏好，下次打开面板会恢复它。
    public func rememberTranslationService(_ id: UUID?) {
        let validID = id.flatMap { candidate in
            services.contains(where: { $0.id == candidate }) ? candidate : nil
        }
        lastTranslationServiceID = validID
        if let validID {
            defaults.set(validID.uuidString, forKey: lastTranslationServiceKey)
        } else {
            defaults.removeObject(forKey: lastTranslationServiceKey)
        }
    }

    /// 记录翻译确认面板最近一次选择的目标语言。它是翻译执行偏好，
    /// 不再绑定到某一个服务 profile。
    public func rememberTranslationTargetLanguage(_ language: TranslationTargetLanguage) {
        lastTranslationTargetLanguage = language
        defaults.set(language.rawValue, forKey: lastTranslationTargetLanguageKey)
    }

    /// 兼容旧调用方的派生属性。新界面使用 `services` 和 `selectedServiceID`，
    /// 这些属性只作用于当前选中的服务配置。
    public var selectedProvider: TranslationProviderID {
        get { selectedService?.provider ?? .deepSeek }
        set { updateService(id: selectedServiceID, provider: newValue) }
    }

    public var selectedModel: String {
        get { selectedService?.model ?? "" }
        set { updateService(id: selectedServiceID, model: newValue) }
    }

    public var targetLanguage: TranslationTargetLanguage {
        get { selectedService?.targetLanguage ?? .simplifiedChinese }
        set { updateService(id: selectedServiceID, targetLanguage: newValue) }
    }

    public var hasAPIKey: Bool {
        guard let selectedServiceID else { return false }
        return hasAPIKey(for: selectedServiceID)
    }

    public func apiKey() -> String {
        guard let selectedServiceID else { return "" }
        return apiKey(for: selectedServiceID)
    }

    public func apiKey(for serviceID: UUID) -> String {
        if let value = keychain.read(account: keychainAccount(for: serviceID)), !value.isEmpty {
            return value
        }
        // 对从旧版本直接升级、但尚未走完整迁移的服务配置做一次惰性迁移。
        guard let profile = services.first(where: { $0.id == serviceID }),
              let legacyValue = keychain.read(account: profile.provider.keychainAccount) else {
            return ""
        }
        keychain.write(legacyValue, account: keychainAccount(for: serviceID))
        return legacyValue
    }

    public func hasAPIKey(for serviceID: UUID) -> Bool {
        !apiKey(for: serviceID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func setAPIKey(_ value: String) {
        guard let selectedServiceID else { return }
        setAPIKey(value, for: selectedServiceID)
    }

    public func setAPIKey(_ value: String, for serviceID: UUID) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            keychain.delete(account: keychainAccount(for: serviceID))
        } else {
            keychain.write(normalized, account: keychainAccount(for: serviceID))
        }
        invalidateModelFetch(for: serviceID)
        objectWillChange.send()
    }

    public func configuration() -> TranslationConfiguration? {
        guard let selectedServiceID else { return nil }
        return configuration(for: selectedServiceID)
    }

    public func configuration(
        for serviceID: UUID,
        targetLanguage: TranslationTargetLanguage? = nil
    ) -> TranslationConfiguration? {
        guard let profile = services.first(where: { $0.id == serviceID }) else { return nil }
        let key = apiKey(for: serviceID).trimmingCharacters(in: .whitespacesAndNewlines)
        let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !model.isEmpty else { return nil }
        return TranslationConfiguration(
            provider: profile.provider,
            model: model,
            apiKey: key,
            targetLanguage: targetLanguage ?? profile.targetLanguage,
            serverURL: profile.serverURL,
            modelsURL: profile.modelsURL,
            translationURL: profile.translationURL,
            authentication: profile.authentication,
            authenticationHeader: profile.authenticationHeader,
            modelListJSONPath: profile.modelListJSONPath,
            modelIDJSONPath: profile.modelIDJSONPath,
            translationResponseJSONPath: profile.translationResponseJSONPath
        )
    }

    public func availableModels(for serviceID: UUID) -> [TranslationModelDescriptor] {
        availableModels[serviceID] ?? []
    }

    public func modelFetchState(for serviceID: UUID) -> TranslationModelFetchState {
        modelFetchStates[serviceID] ?? .idle
    }

    /// 在后台读取服务端模型列表；同一服务的旧请求会被取消，且旧响应不会
    /// 覆盖用户随后修改过的地址、Key 或服务配置。
    public func refreshModels(for serviceID: UUID) {
        modelFetchTasks[serviceID]?.cancel()
        modelFetchTasks[serviceID] = nil
        guard let profile = services.first(where: { $0.id == serviceID }) else { return }
        let apiKey = apiKey(for: serviceID).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            availableModels[serviceID] = []
            modelFetchStates[serviceID] = .failed(TranslationProviderError.missingAPIKey.localizedDescription)
            return
        }

        let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? profile.provider.defaultModel
            : profile.model
        let configuration = TranslationConfiguration(
            provider: profile.provider,
            model: model,
            apiKey: apiKey,
            targetLanguage: profile.targetLanguage,
            serverURL: profile.serverURL,
            modelsURL: profile.modelsURL,
            translationURL: profile.translationURL,
            authentication: profile.authentication,
            authenticationHeader: profile.authenticationHeader,
            modelListJSONPath: profile.modelListJSONPath,
            modelIDJSONPath: profile.modelIDJSONPath,
            translationResponseJSONPath: profile.translationResponseJSONPath
        )
        let requestID = UUID()
        modelFetchRequestIDs[serviceID] = requestID
        modelFetchStates[serviceID] = .loading

        let task = Task { @MainActor [weak self] in
            do {
                let models = try await TranslationService.shared.listModels(configuration: configuration)
                try Task.checkCancellation()
                guard let self,
                      self.modelFetchRequestIDs[serviceID] == requestID,
                      self.matchesModelFetchProfile(
                          self.services.first(where: { $0.id == serviceID }),
                          captured: profile
                      ),
                      self.apiKey(for: serviceID) == apiKey else { return }
                self.availableModels[serviceID] = models
                self.modelFetchStates[serviceID] = .loaded(count: models.count)
                if let current = self.services.first(where: { $0.id == serviceID })?.model,
                   (current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || current == profile.provider.defaultModel),
                   let first = models.first {
                    self.updateService(id: serviceID, model: first.id)
                }
                self.modelFetchTasks[serviceID] = nil
            } catch is CancellationError {
                // 用户修改地址/Key 或主动刷新时，旧请求无需显示错误。
            } catch {
                guard let self,
                      self.modelFetchRequestIDs[serviceID] == requestID else { return }
                self.availableModels[serviceID] = []
                self.modelFetchStates[serviceID] = .failed(error.localizedDescription)
                self.modelFetchTasks[serviceID] = nil
            }
        }
        modelFetchTasks[serviceID] = task
    }

    @discardableResult
    public func addService(
        name: String,
        provider: TranslationProviderID,
        model: String? = nil,
        serverURL: String? = nil,
        modelsURL: String? = nil,
        translationURL: String? = nil,
        authentication: TranslationAuthenticationMethod? = nil,
        authenticationHeader: String? = nil,
        modelListJSONPath: String? = nil,
        modelIDJSONPath: String? = nil,
        translationResponseJSONPath: String? = nil,
        targetLanguage: TranslationTargetLanguage = .simplifiedChinese
    ) -> UUID {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let serviceName = normalizedName.isEmpty
            ? provider.defaultServiceName
            : normalizedName
        let profile = TranslationServiceProfile(
            name: serviceName,
            provider: provider,
            model: model?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? model!.trimmingCharacters(in: .whitespacesAndNewlines)
                : provider.defaultModel,
            serverURL: serverURL,
            modelsURL: modelsURL,
            translationURL: translationURL,
            authentication: authentication,
            authenticationHeader: authenticationHeader,
            modelListJSONPath: modelListJSONPath,
            modelIDJSONPath: modelIDJSONPath,
            translationResponseJSONPath: translationResponseJSONPath,
            targetLanguage: targetLanguage
        )
        services.append(profile)
        selectedServiceID = profile.id
        return profile.id
    }

    /// 添加一个用户自定义模型。API Key 仍只写入钥匙串，服务配置本身只保存
    /// 模型名称、协议和 Base URL，便于以后在模型选择器中复用上次选择。
    @discardableResult
    public func addCustomModel(
        modelName: String,
        protocolID: TranslationProviderID,
        baseURL: String,
        apiKey: String
    ) -> UUID {
        let normalizedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = addService(
            name: normalizedModel,
            provider: protocolID,
            model: normalizedModel,
            serverURL: baseURL
        )
        setAPIKey(apiKey, for: id)
        return id
    }

    public func removeService(id: UUID) {
        guard let index = services.firstIndex(where: { $0.id == id }) else { return }
        guard !services[index].isBuiltIn else { return }
        modelFetchTasks[id]?.cancel()
        modelFetchTasks[id] = nil
        modelFetchRequestIDs[id] = nil
        availableModels[id] = nil
        modelFetchStates[id] = nil
        keychain.delete(account: keychainAccount(for: id))
        services.remove(at: index)
        if selectedServiceID == id {
            selectedServiceID = services.indices.contains(index)
                ? services[index].id
                : services.last?.id
        }
        if lastTranslationServiceID == id {
            let fallbackID = services.indices.contains(index)
                ? services[index].id
                : services.last?.id
            rememberTranslationService(fallbackID)
        }
    }

    public func moveServices(from offsets: IndexSet, to destination: Int) {
        let moving = offsets.sorted().map { services[$0] }
        let remaining = services.enumerated()
            .filter { !offsets.contains($0.offset) }
            .map(\.element)
        let insertionIndex = min(max(0, destination), remaining.count)
        var reordered = Array(remaining.prefix(insertionIndex))
        reordered.append(contentsOf: moving)
        reordered.append(contentsOf: remaining.dropFirst(insertionIndex))
        services = reordered
    }

    public func updateService(
        id: UUID?,
        name: String? = nil,
        provider: TranslationProviderID? = nil,
        model: String? = nil,
        serverURL: String? = nil,
        modelsURL: String? = nil,
        translationURL: String? = nil,
        authentication: TranslationAuthenticationMethod? = nil,
        authenticationHeader: String? = nil,
        modelListJSONPath: String? = nil,
        modelIDJSONPath: String? = nil,
        translationResponseJSONPath: String? = nil,
        targetLanguage: TranslationTargetLanguage? = nil
    ) {
        guard let id, let index = services.firstIndex(where: { $0.id == id }) else { return }
        if let name {
            services[index].name = name
        }
        if let provider {
            let oldProvider = services[index].provider
            let oldModel = services[index].model
            let oldServerURL = services[index].serverURL
            services[index].provider = provider
            if model == nil,
               (oldModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || oldModel == oldProvider.defaultModel) {
                services[index].model = provider.defaultModel
            }
            if serverURL == nil, oldServerURL == oldProvider.defaultServerURL {
                services[index].serverURL = provider.defaultServerURL
            }
            if modelsURL == nil { services[index].modelsURL = nil }
            if translationURL == nil { services[index].translationURL = nil }
            if authentication == nil { services[index].authentication = provider.defaultAuthentication }
            if authenticationHeader == nil {
                services[index].authenticationHeader = provider.defaultAuthenticationHeader
            }
            if modelListJSONPath == nil {
                services[index].modelListJSONPath = provider.defaultModelListJSONPath
            }
            if modelIDJSONPath == nil {
                services[index].modelIDJSONPath = provider.defaultModelIDJSONPath
            }
            if translationResponseJSONPath == nil {
                services[index].translationResponseJSONPath = provider.defaultTranslationResponseJSONPath
            }
            invalidateModelFetch(for: id)
        }
        if let model {
            services[index].model = model
        }
        if let targetLanguage {
            services[index].targetLanguage = targetLanguage
        }
        if let serverURL {
            let normalized = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            services[index].serverURL = normalized.isEmpty
                ? services[index].provider.defaultServerURL
                : normalized
            invalidateModelFetch(for: id)
        }
        if let modelsURL {
            services[index].modelsURL = normalizedOptional(modelsURL)
            invalidateModelFetch(for: id)
        }
        if let translationURL {
            services[index].translationURL = normalizedOptional(translationURL)
        }
        if let authentication {
            services[index].authentication = authentication
            invalidateModelFetch(for: id)
        }
        if let authenticationHeader {
            let normalized = authenticationHeader.trimmingCharacters(in: .whitespacesAndNewlines)
            services[index].authenticationHeader = normalized.isEmpty
                ? services[index].provider.defaultAuthenticationHeader
                : normalized
            invalidateModelFetch(for: id)
        }
        if let modelListJSONPath {
            services[index].modelListJSONPath = normalizedRequired(
                modelListJSONPath,
                fallback: services[index].provider.defaultModelListJSONPath
            )
            invalidateModelFetch(for: id)
        }
        if let modelIDJSONPath {
            services[index].modelIDJSONPath = normalizedRequired(
                modelIDJSONPath,
                fallback: services[index].provider.defaultModelIDJSONPath
            )
            invalidateModelFetch(for: id)
        }
        if let translationResponseJSONPath {
            services[index].translationResponseJSONPath = normalizedRequired(
                translationResponseJSONPath,
                fallback: services[index].provider.defaultTranslationResponseJSONPath
            )
        }
    }

    private func invalidateModelFetch(for serviceID: UUID) {
        modelFetchTasks[serviceID]?.cancel()
        modelFetchTasks[serviceID] = nil
        modelFetchRequestIDs[serviceID] = nil
        availableModels[serviceID] = []
        modelFetchStates[serviceID] = .idle
    }

    private func keychainAccount(for serviceID: UUID) -> String {
        "translation-api-key-profile-\(serviceID.uuidString.lowercased())"
    }

    private func persistServices() {
        guard let data = try? JSONEncoder().encode(services) else { return }
        defaults.set(data, forKey: servicesKey)
    }

    private func normalizedOptional(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func normalizedRequired(_ value: String, fallback: String) -> String {
        normalizedOptional(value) ?? fallback
    }

    private func matchesModelFetchProfile(
        _ current: TranslationServiceProfile?,
        captured: TranslationServiceProfile
    ) -> Bool {
        guard let current else { return false }
        // 模型名和目标语言不参与模型列表请求；用户在请求进行中选择模型或
        // 修改目标语言时，仍应接收这次没有过期的列表结果。
        return current.provider == captured.provider
            && current.serverURL == captured.serverURL
            && current.modelsURL == captured.modelsURL
            && current.translationURL == captured.translationURL
            && current.authentication == captured.authentication
            && current.authenticationHeader == captured.authenticationHeader
            && current.modelListJSONPath == captured.modelListJSONPath
            && current.modelIDJSONPath == captured.modelIDJSONPath
    }

    private static func decodeServices(from data: Data?) -> [TranslationServiceProfile]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([TranslationServiceProfile].self, from: data)
    }
}
