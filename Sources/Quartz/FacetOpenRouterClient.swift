import Foundation

struct FacetConfiguration: Sendable, Equatable {
    let model: String?
    let reasoningEffort: String?

    var modelID: String {
        let value = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "openrouter/auto" : value
    }

    var reasoningEffortValue: String? {
        guard let value = reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines),
              Self.reasoningEfforts.contains(value) else { return nil }
        return value
    }

    static let reasoningEfforts = ["max", "xhigh", "high", "medium", "low", "minimal", "none"]
}

struct FacetModelOption: Sendable, Equatable {
    let slug: String
    let displayName: String
    let supportedReasoningEfforts: [String]

    init(slug: String, displayName: String, supportedReasoningEfforts: [String] = []) {
        self.slug = slug
        self.displayName = displayName
        self.supportedReasoningEfforts = supportedReasoningEfforts
    }

    var menuTitle: String { displayName == slug ? slug : "\(displayName) (\(slug))" }

    static let fallbackOptions = [FacetModelOption(slug: "openrouter/auto", displayName: "Auto Router")]
}

struct FacetChatMessage: Codable, Sendable, Equatable {
    let role: String
    let content: String
    let toolCalls: [FacetToolCall]?
    let toolCallID: String?
    let reasoningDetails: FacetJSONValue?

    init(role: String, content: String, toolCalls: [FacetToolCall]? = nil, toolCallID: String? = nil, reasoningDetails: FacetJSONValue? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.reasoningDetails = reasoningDetails
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        toolCalls = try container.decodeIfPresent([FacetToolCall].self, forKey: .toolCalls)
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        reasoningDetails = try container.decodeIfPresent(FacetJSONValue.self, forKey: .reasoningDetails)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        if role == "assistant", content.isEmpty, toolCalls?.isEmpty == false {
            try container.encodeNil(forKey: .content)
        } else {
            try container.encode(content, forKey: .content)
        }
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(reasoningDetails, forKey: .reasoningDetails)
    }

    private enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case reasoningDetails = "reasoning_details"
    }
}

enum FacetOpenRouterError: LocalizedError, Sendable {
    case missingAPIKey
    case invalidAPIKey
    case invalidResponse
    case emptyResponse
    case service(statusCode: Int?, message: String?)
    case connection(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your OpenRouter API key in Facet settings to start chatting."
        case .invalidAPIKey:
            return "The OpenRouter API key contains whitespace. Paste the key again in Facet settings."
        case .invalidResponse:
            return "OpenRouter returned an unreadable response. Please try again."
        case .emptyResponse:
            return "OpenRouter returned no reply text. Please try again or choose another model."
        case let .service(statusCode, message):
            let summary: String
            switch statusCode {
            case 401:
                summary = "OpenRouter rejected the API key. Check the key in Facet settings."
            case 402:
                summary = "OpenRouter needs more credits. Check your OpenRouter balance or choose another model."
            case 429:
                summary = "OpenRouter is rate limiting requests. Wait a moment and try again."
            case 403:
                summary = "OpenRouter denied this request. Check your key permissions or choose another model."
            case let code? where (500...599).contains(code):
                summary = "OpenRouter or the selected model is temporarily unavailable. Please try again."
            case let code?:
                summary = "OpenRouter could not complete the request (HTTP \(code))."
            case nil:
                summary = "OpenRouter could not complete the request."
            }
            return message.map { "\(summary)\n\($0)" } ?? summary
        case let .connection(message):
            return message
        }
    }
}

final class FacetOpenRouterClient: Sendable {
    private let session: URLSession
    private static let completionsURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private static let modelsURL = URL(string: "https://openrouter.ai/api/v1/models")!

    init(session: URLSession = FacetOpenRouterClient.makeSession()) {
        self.session = session
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }

    func run(messages: [FacetChatMessage], configuration: FacetConfiguration, apiKey: String) async throws -> String {
        try await requestTurn(messages: messages, configuration: configuration, apiKey: apiKey).content
    }

    func requestTurn(
        messages: [FacetChatMessage],
        configuration: FacetConfiguration,
        apiKey: String,
        tools: [FacetToolDefinition]? = nil
    ) async throws -> FacetAssistantTurn {
        try Task.checkCancellation()
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw FacetOpenRouterError.missingAPIKey }
        guard key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw FacetOpenRouterError.invalidAPIKey
        }

        var request = URLRequest(url: Self.completionsURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Quartz Facet", forHTTPHeaderField: "X-OpenRouter-Title")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: configuration.modelID,
            messages: messages,
            reasoning: configuration.reasoningEffortValue.map { Reasoning(effort: $0) },
            tools: tools?.isEmpty == false ? tools : nil,
            parallelToolCalls: tools?.isEmpty == false ? false : nil
        ))

        let body = try await responseBody(for: request, apiKey: key)
        guard let choices = body["choices"] as? [[String: Any]], let choice = choices.first else {
            throw FacetOpenRouterError.invalidResponse
        }
        if let error = choice["error"], !(error is NSNull) {
            throw Self.serviceError(error, statusCode: nil, apiKey: key)
        }
        if choice["finish_reason"] as? String == "error" {
            throw FacetOpenRouterError.service(statusCode: nil, message: nil)
        }
        guard let message = choice["message"] as? [String: Any] else {
            throw FacetOpenRouterError.invalidResponse
        }

        let content: String
        if let text = message["content"] as? String {
            content = text
        } else if let parts = message["content"] as? [[String: Any]] {
            // Some providers normalize their response as typed text parts.
            content = try parts.compactMap { part -> String? in
                guard let type = part["type"] as? String else { throw FacetOpenRouterError.invalidResponse }
                guard type == "text" || type == "output_text" else { return nil }
                guard let text = part["text"] as? String else { throw FacetOpenRouterError.invalidResponse }
                return text
            }.joined()
        } else if message["content"] == nil || message["content"] is NSNull {
            content = ""
        } else {
            throw FacetOpenRouterError.invalidResponse
        }
        let toolCalls: [FacetToolCall]
        if let rawCalls = message["tool_calls"], !(rawCalls is NSNull) {
            guard let calls = rawCalls as? [[String: Any]], calls.count <= 128 else {
                throw FacetOpenRouterError.invalidResponse
            }
            do {
                toolCalls = try JSONDecoder().decode([FacetToolCall].self, from: JSONSerialization.data(withJSONObject: calls))
            } catch {
                throw FacetOpenRouterError.invalidResponse
            }
        } else {
            toolCalls = []
        }
        guard toolCalls.isEmpty || tools?.isEmpty == false else {
            throw FacetToolSessionError.invalidToolCall
        }
        // Never execute arguments from a completion that stopped before it finished generating.
        if !toolCalls.isEmpty, let reason = choice["finish_reason"] as? String,
           reason != "tool_calls" && reason != "stop" {
            throw FacetToolSessionError.invalidToolCall
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !toolCalls.isEmpty else {
            throw FacetOpenRouterError.emptyResponse
        }
        // Some reasoning models require their opaque reasoning details on the next tool turn.
        // These details are never surfaced as reply text or persisted in the chat transcript.
        let reasoningDetails: FacetJSONValue?
        if !toolCalls.isEmpty, let details = message["reasoning_details"], !(details is NSNull) {
            guard let data = try? JSONSerialization.data(withJSONObject: details, options: [.fragmentsAllowed]),
                  data.count <= 262_144,
                  let decoded = try? JSONDecoder().decode(FacetJSONValue.self, from: data) else {
                throw FacetOpenRouterError.invalidResponse
            }
            reasoningDetails = decoded
        } else {
            reasoningDetails = nil
        }
        try Task.checkCancellation()
        return FacetAssistantTurn(content: content, toolCalls: toolCalls, reasoningDetails: reasoningDetails)
    }

    func loadModelOptions() async throws -> [FacetModelOption] {
        var request = URLRequest(url: Self.modelsURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = try await responseBody(for: request)
        guard let models = body["data"] as? [[String: Any]] else {
            throw FacetOpenRouterError.invalidResponse
        }

        var options: [String: FacetModelOption] = [:]
        for model in models {
            guard let rawID = model["id"] as? String,
                  let architecture = model["architecture"] as? [String: Any],
                  let inputs = architecture["input_modalities"] as? [String], inputs.contains("text"),
                  let outputs = architecture["output_modalities"] as? [String], outputs == ["text"] else { continue }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            // Batch variants use the asynchronous Batch API. Facet displays synchronous text replies.
            guard !id.isEmpty, !id.split(separator: ":").dropFirst().contains("batch"), options[id] == nil else { continue }
            let name = (model["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var efforts: [String] = []
            if let reasoning = model["reasoning"] as? [String: Any] {
                if reasoning["supported_efforts"] is NSNull {
                    efforts = FacetConfiguration.reasoningEfforts
                } else if let supported = reasoning["supported_efforts"] as? [String] {
                    efforts = FacetConfiguration.reasoningEfforts.filter { supported.contains($0) }
                }
                if reasoning["mandatory"] as? Bool == true {
                    efforts.removeAll { $0 == "none" }
                }
            }
            options[id] = FacetModelOption(slug: id, displayName: name.isEmpty ? id : name, supportedReasoningEfforts: efforts)
        }
        // Keep a usable default even if the catalog temporarily omits the router.
        for fallback in FacetModelOption.fallbackOptions where options[fallback.slug] == nil {
            options[fallback.slug] = fallback
        }
        try Task.checkCancellation()
        return options.values.sorted { lhs, rhs in
            if lhs.slug == rhs.slug { return false }
            if lhs.slug == "openrouter/auto" { return true }
            if rhs.slug == "openrouter/auto" { return false }
            let left = lhs.displayName.lowercased()
            let right = rhs.displayName.lowercased()
            return left == right ? lhs.slug < rhs.slug : left < right
        }
    }

    private func responseBody(for request: URLRequest, apiKey: String? = nil) async throws -> [String: Any] {
        try Task.checkCancellation()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if (error as? URLError)?.code == .timedOut {
                throw FacetOpenRouterError.connection("OpenRouter took too long to respond. Please try again or choose another model.")
            }
            throw FacetOpenRouterError.connection("Could not connect to OpenRouter. Check your internet connection and try again.")
        }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw FacetOpenRouterError.invalidResponse }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(response.statusCode) else {
            throw Self.serviceError(body?["error"], statusCode: response.statusCode, apiKey: apiKey)
        }
        guard let body else { throw FacetOpenRouterError.invalidResponse }
        if let error = body["error"], !(error is NSNull) {
            throw Self.serviceError(error, statusCode: nil, apiKey: apiKey)
        }
        return body
    }

    private static func serviceError(_ error: Any?, statusCode: Int?, apiKey: String?) -> FacetOpenRouterError {
        let details = error as? [String: Any]
        let code = statusCode ?? (details?["code"] as? Int) ?? (details?["code"] as? String).flatMap(Int.init)
        let rawMessage = (details?["message"] as? String) ?? (error as? String)
        var message = rawMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let apiKey, !apiKey.isEmpty {
            message = message?.replacingOccurrences(of: apiKey, with: "[redacted]")
        }
        message = message?.replacingOccurrences(of: "sk-or-[A-Za-z0-9_-]+", with: "[redacted]", options: .regularExpression)
        if let value = message {
            message = value.isEmpty ? nil : String(value.prefix(500))
        }
        return .service(statusCode: code, message: message)
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [FacetChatMessage]
        let reasoning: Reasoning?
        let tools: [FacetToolDefinition]?
        let parallelToolCalls: Bool?
        let stream = false

        private enum CodingKeys: String, CodingKey {
            case model, messages, reasoning, tools, stream
            case parallelToolCalls = "parallel_tool_calls"
        }
    }

    private struct Reasoning: Encodable {
        let effort: String
    }
}
