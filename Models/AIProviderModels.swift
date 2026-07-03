import Foundation

enum AIProviderPreset: String, CaseIterable, Identifiable, Sendable {
    case openAI
    case deepSeek
    case custom

    var id: String { rawValue }

    var name: String {
        switch self {
        case .openAI: "OpenAI"
        case .deepSeek: "DeepSeek"
        case .custom: "自定义兼容接口"
        }
    }

    var endpoint: String? {
        switch self {
        case .openAI:
            "https://api.openai.com/v1"
        case .deepSeek:
            "https://api.deepseek.com"
        case .custom:
            nil
        }
    }

    var models: [AIModelOption] {
        switch self {
        case .openAI:
            [
                AIModelOption(id: "gpt-5.4-mini", name: "GPT-5.4 mini", detail: "推荐 · 速度与能力均衡"),
                AIModelOption(id: "gpt-5.5", name: "GPT-5.5", detail: "能力最强 · 成本较高"),
                AIModelOption(id: "gpt-5.4", name: "GPT-5.4", detail: "复杂写作与推理"),
                AIModelOption(id: "gpt-4.1-mini", name: "GPT-4.1 mini", detail: "稳定 · 经济"),
            ]
        case .deepSeek:
            [
                AIModelOption(id: "deepseek-v4-flash", name: "DeepSeek V4 Flash", detail: "推荐 · 快速经济"),
                AIModelOption(id: "deepseek-v4-pro", name: "DeepSeek V4 Pro", detail: "能力更强"),
            ]
        case .custom:
            []
        }
    }

    var defaultModel: String {
        models.first?.id ?? ""
    }
}

struct AIModelOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String
}

struct AIUsage: Codable, Hashable, Sendable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let promptCacheHitTokens: Int
    let promptCacheMissTokens: Int
}

struct AIUsageCost: Codable, Hashable, Sendable {
    let amount: Double
    let currency: String

    var formatted: String {
        let symbol = currency == "CNY" ? "¥" : "$"
        if amount < 0.01 {
            return "\(symbol)\(amount.formatted(.number.precision(.fractionLength(4))))"
        }
        return "\(symbol)\(amount.formatted(.number.precision(.fractionLength(2))))"
    }
}

struct AIAccountBalance: Codable, Hashable, Sendable {
    let currency: String
    let total: Double
    let granted: Double
    let toppedUp: Double

    var formattedTotal: String {
        let symbol = currency == "CNY" ? "¥" : "$"
        return "\(symbol)\(total.formatted(.number.precision(.fractionLength(2))))"
    }
}

enum AIEndpointResolver {
    static func chatCompletionsURL(from baseURL: String) -> URL? {
        let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value),
              components.scheme != nil,
              components.host != nil
        else { return nil }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.hasSuffix("chat/completions") {
            components.path = "/" + [path, "chat/completions"]
                .filter { !$0.isEmpty }
                .joined(separator: "/")
        }
        return components.url
    }
}
