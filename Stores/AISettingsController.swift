import Foundation
import Observation

@MainActor
@Observable
final class AISettingsController {
    var provider: AIProviderPreset
    var model: String {
        didSet { defaults.set(model, forKey: Keys.model) }
    }
    var endpoint: String {
        didSet { defaults.set(endpoint, forKey: Keys.endpoint) }
    }
    var apiKey: String {
        didSet {
            guard apiKey != oldValue else { return }
            do {
                try saveAPIKey(apiKey)
                secretPersistenceError = nil
            } catch {
                secretPersistenceError = "API Key 无法保存到本地配置：\(error.localizedDescription)"
            }
        }
    }

    private(set) var isTestingConnection = false
    private(set) var connectionTestSucceeded = false
    var connectionTestError: String?
    private(set) var accountBalances: [AIAccountBalance] = []
    private(set) var balanceError: String?
    private(set) var isRefreshingBalance = false
    private(set) var secretPersistenceError: String?

    private let defaults: UserDefaults
    private let service: AIService
    private let saveAPIKey: (String) throws -> Void
    private var lastBalanceRefresh: Date?

    init(
        defaults: UserDefaults,
        service: AIService = .init(),
        loadAPIKey: () -> String = {
            LocalSecretStore.read(account: "openai-api-key")
        },
        saveAPIKey: @escaping (String) throws -> Void = {
            try LocalSecretStore.save($0, account: "openai-api-key")
        }
    ) {
        self.defaults = defaults
        self.service = service
        self.saveAPIKey = saveAPIKey
        provider = AIProviderPreset(
            rawValue: defaults.string(forKey: Keys.provider) ?? ""
        ) ?? Self.inferProvider(
            from: defaults.string(forKey: Keys.endpoint)
        )
        model = defaults.string(forKey: Keys.model) ?? "gpt-4.1-mini"
        endpoint = defaults.string(forKey: Keys.endpoint)
            ?? "https://api.openai.com/v1"
        apiKey = loadAPIKey()

        if let presetEndpoint = provider.endpoint {
            endpoint = presetEndpoint
            if !provider.models.contains(where: { $0.id == model }) {
                model = provider.defaultModel
            }
        }
    }

    func selectProvider(_ newProvider: AIProviderPreset) {
        provider = newProvider
        defaults.set(newProvider.rawValue, forKey: Keys.provider)
        if let presetEndpoint = newProvider.endpoint {
            endpoint = presetEndpoint
            if !newProvider.models.contains(where: { $0.id == model }) {
                model = newProvider.defaultModel
            }
        }
        accountBalances = []
        balanceError = nil
        lastBalanceRefresh = nil
        resetConnectionTest()
    }

    func selectModel(_ newModel: String) {
        model = newModel
        if let presetEndpoint = provider.endpoint {
            endpoint = presetEndpoint
        }
        resetConnectionTest()
    }

    func testConnection(apiKey: String) async {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        isTestingConnection = true
        connectionTestSucceeded = false
        connectionTestError = nil
        defer { isTestingConnection = false }

        do {
            let requestedConfiguration = try configuration()
            try await service.testConnection(configuration: requestedConfiguration)
            guard configurationMatches(requestedConfiguration) else { return }
            connectionTestSucceeded = true
            if provider == .deepSeek {
                await refreshAccountBalance(force: true)
            }
        } catch {
            connectionTestError = error.localizedDescription
        }
    }

    func resetConnectionTest() {
        connectionTestSucceeded = false
        connectionTestError = nil
    }

    func refreshAccountBalance(force: Bool = false) async {
        guard provider == .deepSeek,
              !apiKey.isEmpty,
              !isRefreshingBalance else { return }
        if !force,
           let lastBalanceRefresh,
           Date().timeIntervalSince(lastBalanceRefresh) < 60 {
            return
        }
        isRefreshingBalance = true
        balanceError = nil
        defer { isRefreshingBalance = false }
        let requestedKey = apiKey
        do {
            let balances = try await service.fetchDeepSeekBalance(
                apiKey: requestedKey
            )
            guard provider == .deepSeek, apiKey == requestedKey else { return }
            accountBalances = balances
            lastBalanceRefresh = .now
        } catch {
            guard provider == .deepSeek, apiKey == requestedKey else { return }
            balanceError = error.localizedDescription
        }
    }

    func configuration() throws -> AIConfiguration {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey.isEmpty {
            return AIConfiguration(
                apiKey: apiKey,
                endpoint: URL(fileURLWithPath: "/"),
                model: model,
                provider: provider
            )
        }
        guard let endpoint = AIEndpointResolver.chatCompletionsURL(
            from: endpoint
        ) else {
            throw NSError(
                domain: "AIConfiguration",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "基础地址无效。请输入包含 http:// 或 https:// 的完整接口地址。"
                ]
            )
        }
        return AIConfiguration(
            apiKey: apiKey,
            endpoint: endpoint,
            model: model,
            provider: provider
        )
    }

    func configurationMatches(_ configuration: AIConfiguration) -> Bool {
        guard let current = try? self.configuration() else { return false }
        return current.apiKey == configuration.apiKey
            && current.endpoint == configuration.endpoint
            && current.model == configuration.model
            && current.provider == configuration.provider
    }

    private static func inferProvider(from endpoint: String?) -> AIProviderPreset {
        guard let endpoint else { return .openAI }
        if endpoint.contains("api.deepseek.com") { return .deepSeek }
        if endpoint.contains("api.openai.com") { return .openAI }
        return .custom
    }

    private enum Keys {
        static let model = "model"
        static let endpoint = "endpoint"
        static let provider = "provider"
    }
}
