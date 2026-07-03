import Foundation

struct AIConfiguration: Sendable {
    let apiKey: String
    let endpoint: URL
    let model: String
    let provider: AIProviderPreset
}

struct AIResponse: Sendable {
    let text: String
    let sources: [RetrievedChunk]
    let usedGeneralKnowledge: Bool
    let usage: AIUsage?
    let cost: AIUsageCost?
}

struct AIService: Sendable {
    func fetchDeepSeekBalance(apiKey: String) async throws -> [AIAccountBalance] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw connectionError("请先填写 DeepSeek API Key。")
        }
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw connectionError("余额服务没有返回有效响应。")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw connectionError(Self.failureReason(statusCode: http.statusCode, data: data))
            }
            let decoded = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data)
            return decoded.balanceInfos.compactMap { item in
                guard let total = Double(item.totalBalance),
                      let granted = Double(item.grantedBalance),
                      let toppedUp = Double(item.toppedUpBalance)
                else { return nil }
                return AIAccountBalance(
                    currency: item.currency,
                    total: total,
                    granted: granted,
                    toppedUp: toppedUp
                )
            }
        } catch let error as URLError {
            throw connectionError(Self.networkFailureReason(error))
        }
    }

    func testConnection(configuration: AIConfiguration) async throws {
        guard !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw connectionError("请先填写 API Key。")
        }
        try validateEndpoint(configuration.endpoint)
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw connectionError("请先选择或填写模型。")
        }

        let body: [String: Any] = [
            "model": configuration.model,
            "messages": [
                ["role": "user", "content": "这是连接测试。请只回复 OK。"]
            ],
        ]
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw connectionError("服务没有返回有效的 HTTP 响应。")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw connectionError(Self.failureReason(statusCode: http.statusCode, data: data))
            }
            let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            guard decoded.choices.first?.message.content.isEmpty == false else {
                throw connectionError("连接成功，但模型没有返回内容。请检查所选模型是否支持对话。")
            }
        } catch let error as URLError {
            throw connectionError(Self.networkFailureReason(error))
        } catch let error as DecodingError {
            throw connectionError("服务已响应，但返回格式不兼容：\(error.localizedDescription)")
        }
    }

    func answer(
        question: String,
        currentText: String,
        history: [ChatMessage],
        sources: [RetrievedChunk],
        configuration: AIConfiguration
    ) async throws -> AIResponse {
        guard !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return localAnswer(question: question, sources: sources)
        }
        try validateEndpoint(configuration.endpoint)

        let sourceText = sources.enumerated().map { index, source in
            "[资料\(index + 1)] \(source.fileName) · \(source.heading ?? "第 \(source.line) 行")\n\(source.text)"
        }.joined(separator: "\n\n")
        let clippedCurrent = String(currentText.prefix(12_000))
        let system = """
        你是私人 Markdown 知识库里的写作助手。优先依据用户资料回答，引用资料时使用 [资料1] 格式。
        清楚区分：用户资料中的事实、你的推断、通用知识。资料冲突时分别陈述，不替用户决定。
        没有依据时直说。不要声称看过未提供的文件。回答使用简洁自然的中文。

        当用户要求修改当前文稿（如改标题、润色、删减、重组等），不要只给建议。直接输出修改后的完整文稿，
        用以下格式包裹：
        ```edit
        修改后的完整文稿内容
        ```
        格式必须严格：```edit 开头单独一行，``` 结尾单独一行，中间是完整的修改后文稿。
        这样我就能自动帮你应用到编辑器。如果用户只是提问而非要求修改，正常回答即可。

        当前文稿：
        \(clippedCurrent)

        检索资料：
        \(sourceText.isEmpty ? "未检索到相关资料。" : sourceText)
        """
        var messages: [[String: String]] = [["role": "system", "content": system]]
        messages += history.suffix(8).map {
            ["role": $0.role == .user ? "user" : "assistant", "content": $0.text]
        }
        messages.append(["role": "user", "content": question])

        let body: [String: Any] = [
            "model": configuration.model,
            "messages": messages
        ]
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "模型服务请求失败"
            throw NSError(domain: "AIService", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
            throw NSError(domain: "AIService", code: 2, userInfo: [NSLocalizedDescriptionKey: "模型没有返回内容"])
        }
        let usage = decoded.usage.map(Self.mapUsage)
        return AIResponse(
            text: text,
            sources: sources,
            usedGeneralKnowledge: sources.isEmpty,
            usage: usage,
            cost: usage.flatMap { Self.estimatedCost(for: $0, configuration: configuration) }
        )
    }

    func proposeEdit(
        instruction: String,
        currentText: String,
        configuration: AIConfiguration
    ) async throws -> String {
        guard !configuration.apiKey.isEmpty else {
            throw NSError(
                domain: "AIService",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "生成修改建议需要先在设置中填写 API Key"]
            )
        }
        try validateEndpoint(configuration.endpoint)
        let prompt = """
        请按要求修改下面的 Markdown。只返回修改后的完整 Markdown，不要解释，不要加代码围栏。

        修改要求：\(instruction)

        原文：
        \(currentText)
        """
        let body: [String: Any] = [
            "model": configuration.model,
            "messages": [["role": "user", "content": prompt]]
        ]
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "AIService", code: 4, userInfo: [NSLocalizedDescriptionKey: "模型服务请求失败"])
        }
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content else {
            throw NSError(domain: "AIService", code: 5, userInfo: [NSLocalizedDescriptionKey: "模型没有返回修改内容"])
        }
        return text
    }

    private func localAnswer(question: String, sources: [RetrievedChunk]) -> AIResponse {
        guard !sources.isEmpty else {
            return AIResponse(
                text: "我没有在你的知识库里找到足够可靠的相关资料。你可以换个关键词，或在设置中填写 API Key，让我结合通用知识继续回答。",
                sources: [],
                usedGeneralKnowledge: false,
                usage: nil,
                cost: nil
            )
        }
        let summary = sources.prefix(4).enumerated().map { index, source in
            "\(index + 1). **\(source.fileName)**（\(source.heading ?? "第 \(source.line) 行")）\n\(source.text)"
        }.joined(separator: "\n\n")
        return AIResponse(
            text: "在你的资料中，我找到了这些与“\(question)”相关的片段：\n\n\(summary)\n\n这是本地检索结果，尚未调用云端模型进行综合推断。",
            sources: Array(sources.prefix(4)),
            usedGeneralKnowledge: false,
            usage: nil,
            cost: nil
        )
    }

    private func validateEndpoint(_ endpoint: URL) throws {
        if endpoint.scheme?.lowercased() == "https" { return }
        let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
        if endpoint.scheme?.lowercased() == "http",
           let host = endpoint.host?.lowercased(),
           localHosts.contains(host) {
            return
        }
        throw connectionError("为保护 API Key，公网接口必须使用 HTTPS；HTTP 仅允许本机地址。")
    }

    private static func mapUsage(_ usage: ChatCompletionResponse.Usage) -> AIUsage {
        let hitTokens = usage.promptCacheHitTokens
            ?? usage.promptTokensDetails?.cachedTokens
            ?? 0
        let missTokens = usage.promptCacheMissTokens
            ?? max(0, usage.promptTokens - hitTokens)
        return AIUsage(
            promptTokens: usage.promptTokens,
            completionTokens: usage.completionTokens,
            totalTokens: usage.totalTokens,
            promptCacheHitTokens: hitTokens,
            promptCacheMissTokens: missTokens
        )
    }

    private static func estimatedCost(
        for usage: AIUsage,
        configuration: AIConfiguration
    ) -> AIUsageCost? {
        let million = 1_000_000.0
        switch configuration.provider {
        case .deepSeek:
            let rates: (hit: Double, miss: Double, output: Double)
            switch configuration.model {
            case "deepseek-v4-flash":
                rates = (0.02, 1.0, 2.0)
            case "deepseek-v4-pro":
                rates = (0.025, 3.0, 6.0)
            default:
                return nil
            }
            let amount =
                Double(usage.promptCacheHitTokens) / million * rates.hit +
                Double(usage.promptCacheMissTokens) / million * rates.miss +
                Double(usage.completionTokens) / million * rates.output
            return AIUsageCost(amount: amount, currency: "CNY")
        case .openAI:
            let rates: (input: Double, output: Double)
            switch configuration.model {
            case "gpt-5.5": rates = (5.0, 30.0)
            case "gpt-5.4": rates = (2.5, 15.0)
            case "gpt-5.4-mini": rates = (0.75, 4.5)
            case "gpt-4.1-mini": rates = (0.4, 1.6)
            default: return nil
            }
            let amount =
                Double(usage.promptTokens) / million * rates.input +
                Double(usage.completionTokens) / million * rates.output
            return AIUsageCost(amount: amount, currency: "USD")
        case .custom:
            return nil
        }
    }

    private func connectionError(_ reason: String) -> NSError {
        NSError(
            domain: "AIService.Connection",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
    }

    private static func failureReason(statusCode: Int, data: Data) -> String {
        let serviceMessage = (try? JSONDecoder().decode(ServiceErrorResponse.self, from: data))?.error.message
            ?? String(data: data, encoding: .utf8)
        let detail = serviceMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(300)
        let suffix = detail.map { "\n\n服务返回：\($0)" } ?? ""

        switch statusCode {
        case 400:
            return "请求参数不被服务接受。通常是模型名称不正确或该模型不支持当前接口。\(suffix)"
        case 401:
            return "API Key 无效、已过期，或没有访问权限。\(suffix)"
        case 403:
            return "服务拒绝访问。请检查账号权限、地区限制或余额状态。\(suffix)"
        case 404:
            return "找不到接口或模型。请确认所选服务商和模型是否匹配。\(suffix)"
        case 408:
            return "服务响应超时，请稍后重试。\(suffix)"
        case 429:
            return "请求过于频繁，或账号额度/余额不足。\(suffix)"
        case 500...599:
            return "模型服务暂时异常（HTTP \(statusCode)），请稍后重试。\(suffix)"
        default:
            return "连接失败（HTTP \(statusCode)）。\(suffix)"
        }
    }

    private static func networkFailureReason(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet:
            "当前没有网络连接。"
        case .timedOut:
            "连接超时，服务可能暂时不可用。"
        case .cannotFindHost, .dnsLookupFailed:
            "找不到接口服务器，请检查接口地址或 DNS。"
        case .cannotConnectToHost:
            "无法连接到接口服务器，请检查网络或服务状态。"
        case .secureConnectionFailed, .serverCertificateUntrusted:
            "安全连接失败，服务器证书可能有问题。"
        default:
            "网络请求失败：\(error.localizedDescription)"
        }
    }
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
    let choices: [Choice]
    let usage: Usage?

    struct Usage: Decodable {
        let promptTokens: Int
        let completionTokens: Int
        let totalTokens: Int
        let promptCacheHitTokens: Int?
        let promptCacheMissTokens: Int?
        let promptTokensDetails: PromptTokensDetails?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
            case promptCacheHitTokens = "prompt_cache_hit_tokens"
            case promptCacheMissTokens = "prompt_cache_miss_tokens"
            case promptTokensDetails = "prompt_tokens_details"
        }
    }

    struct PromptTokensDetails: Decodable {
        let cachedTokens: Int?

        enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
        }
    }
}

private struct ServiceErrorResponse: Decodable {
    struct Detail: Decodable { let message: String }
    let error: Detail
}

private struct DeepSeekBalanceResponse: Decodable {
    struct BalanceInfo: Decodable {
        let currency: String
        let totalBalance: String
        let grantedBalance: String
        let toppedUpBalance: String

        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
            case grantedBalance = "granted_balance"
            case toppedUpBalance = "topped_up_balance"
        }
    }

    let isAvailable: Bool
    let balanceInfos: [BalanceInfo]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}
