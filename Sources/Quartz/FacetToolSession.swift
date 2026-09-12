import Foundation

/// JSON crossing the model/page boundary remains data, never executable Swift or JavaScript.
enum FacetJSONValue: Codable, Sendable, Equatable {
    case object([String: FacetJSONValue])
    case array([FacetJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self), value.isFinite {
            self = .number(value)
        } else if let value = try? container.decode([String: FacetJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([FacetJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid JSON value.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    init(jsonString: String) throws {
        self = try JSONDecoder().decode(Self.self, from: Data(jsonString.utf8))
    }

    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

struct FacetToolDefinition: Encodable, Sendable, Equatable {
    let name: String
    let description: String
    let inputSchema: FacetJSONValue

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("function", forKey: .type)
        var function = container.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function)
        try function.encode(name, forKey: .name)
        try function.encode(description, forKey: .description)
        try function.encode(inputSchema, forKey: .parameters)
    }

    private enum CodingKeys: String, CodingKey { case type, function }
    private enum FunctionKeys: String, CodingKey { case name, description, parameters }
}

struct FacetToolCall: Codable, Sendable, Equatable {
    let id: String
    let type: String
    let function: Function

    var name: String { function.name }
    var arguments: String { function.arguments }

    init(id: String, name: String, arguments: String) {
        self.id = id
        type = "function"
        function = Function(name: name, arguments: arguments)
    }

    struct Function: Codable, Sendable, Equatable {
        let name: String
        let arguments: String
    }
}

struct FacetAssistantTurn: Sendable, Equatable {
    let content: String
    let toolCalls: [FacetToolCall]
    let reasoningDetails: FacetJSONValue?

    init(content: String, toolCalls: [FacetToolCall] = [], reasoningDetails: FacetJSONValue? = nil) {
        self.content = content
        self.toolCalls = toolCalls
        self.reasoningDetails = reasoningDetails
    }
}

enum FacetToolSessionError: LocalizedError, Sendable {
    case invalidTools
    case invalidToolCall
    case limitReached

    var errorDescription: String? {
        switch self {
        case .invalidTools:
            return "This page provided invalid or duplicate WebMCP tool definitions."
        case .invalidToolCall:
            return "Facet stopped because the model requested an unknown or invalid page tool. No further tools were run."
        case .limitReached:
            return "Facet reached the page tool limit for this request and stopped. Review the page before continuing."
        }
    }
}

/// Keeps tool history ephemeral and executes only tools from this request's page snapshot.
/// The caller owns approval, page freshness, and the browser execution boundary.
enum FacetToolSession {
    @MainActor
    static func run(
        messages initialMessages: [FacetChatMessage],
        tools: [FacetToolDefinition],
        maximumRounds: Int = 8,
        maximumToolCalls: Int = 12,
        requestTurn: @MainActor ([FacetChatMessage], [FacetToolDefinition]) async throws -> FacetAssistantTurn,
        execute: @MainActor (FacetToolCall, FacetJSONValue) async throws -> FacetJSONValue
    ) async throws -> String {
        try Task.checkCancellation()
        guard maximumRounds > 0, maximumToolCalls > 0 else { throw FacetToolSessionError.limitReached }
        var names = Set<String>()
        for tool in tools {
            guard tool.name.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil,
                  names.insert(tool.name).inserted,
                  case .object = tool.inputSchema else { throw FacetToolSessionError.invalidTools }
        }
        var messages = initialMessages
        var seenIDs = Set<String>()
        var totalCalls = 0
        // Permit one final inference after the last allowed tool round.
        for round in 0...maximumRounds {
            try Task.checkCancellation()
            let turn = try await requestTurn(messages, tools)
            try Task.checkCancellation()
            if turn.toolCalls.isEmpty {
                guard !turn.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw FacetOpenRouterError.emptyResponse
                }
                return turn.content
            }
            guard round < maximumRounds, turn.toolCalls.count <= maximumToolCalls - totalCalls else {
                throw FacetToolSessionError.limitReached
            }
            // Validate the entire batch before executing any part of it.
            let arguments = try turn.toolCalls.map { call -> FacetJSONValue in
                guard call.type == "function", names.contains(call.name),
                      !call.id.isEmpty, call.id.utf8.count <= 200,
                      call.id.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }),
                      seenIDs.insert(call.id).inserted,
                      call.arguments.utf8.count <= 65_536,
                      let value = try? FacetJSONValue(jsonString: call.arguments),
                      case .object = value else { throw FacetToolSessionError.invalidToolCall }
                return value
            }
            messages.append(FacetChatMessage(
                role: "assistant", content: turn.content, toolCalls: turn.toolCalls,
                reasoningDetails: turn.reasoningDetails
            ))
            for (call, arguments) in zip(turn.toolCalls, arguments) {
                try Task.checkCancellation()
                let result: FacetJSONValue
                do {
                    result = try await execute(call, arguments)
                } catch {
                    // Denial or page navigation must stop the session instead of inviting a retry.
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    result = .object([
                        "isError": .bool(true),
                        "error": .string(String(error.localizedDescription.prefix(2_000)))
                    ])
                }
                try Task.checkCancellation()
                let encoded = try result.jsonString()
                let content = encoded.utf8.count <= 65_536 ? encoded : try FacetJSONValue.object([
                    "isError": .bool(true),
                    "error": .string("The page tool result exceeded the size limit and was omitted.")
                ]).jsonString()
                messages.append(FacetChatMessage(role: "tool", content: content, toolCallID: call.id))
                totalCalls += 1
            }
        }
        throw FacetToolSessionError.limitReached
    }
}
