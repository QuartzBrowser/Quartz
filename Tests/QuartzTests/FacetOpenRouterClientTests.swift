import Foundation
import XCTest
@testable import Quartz

final class FacetOpenRouterClientTests: XCTestCase, @unchecked Sendable {
    func testChatRequestUsesOpenRouterAuthenticationAndStructuredConversation() async throws {
        let messages = [
            FacetChatMessage(role: "system", content: "You are Facet."),
            FacetChatMessage(role: "user", content: "First question"),
            FacetChatMessage(role: "assistant", content: "First answer"),
            FacetChatMessage(role: "user", content: "Follow up")
        ]
        let harness = makeClient { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-api-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try Self.requestBody(request)
            XCTAssertEqual(body["model"] as? String, "example/text-model")
            XCTAssertEqual(body["stream"] as? Bool, false)
            XCTAssertNil(body["tools"])
            XCTAssertNil(body["parallel_tool_calls"])
            XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "high")
            let sentMessages = try JSONDecoder().decode([FacetChatMessage].self, from: JSONSerialization.data(withJSONObject: body["messages"]!))
            XCTAssertEqual(sentMessages, messages)
            return .json(#"{"choices":[{"message":{"role":"assistant","content":"A complete reply."}}]}"#)
        }
        defer { harness.finish() }

        let reply = try await harness.client.run(
            messages: messages,
            configuration: FacetConfiguration(model: "  example/text-model \n", reasoningEffort: " high "),
            apiKey: " test-api-key\n"
        )
        XCTAssertEqual(reply, "A complete reply.")
    }

    func testDefaultModelOmitsUnrecognizedReasoning() async throws {
        let harness = makeClient { request in
            let body = try Self.requestBody(request)
            XCTAssertEqual(body["model"] as? String, "openrouter/auto")
            XCTAssertNil(body["reasoning"])
            return .json(#"{"choices":[{"message":{"content":"OK"}}]}"#)
        }
        defer { harness.finish() }
        _ = try await harness.client.run(messages: [], configuration: FacetConfiguration(model: " \n", reasoningEffort: "ultra"), apiKey: "test-key")
    }

    func testStructuredToolsAndToolOnlyResponseUseOpenRouterWireFormat() async throws {
        let schema = FacetJSONValue.object([
            "type": .string("object"),
            "properties": .object(["query": .object(["type": .string("string")])]),
            "required": .array([.string("query")])
        ])
        let tool = FacetToolDefinition(name: "page_search", description: "Search this page", inputSchema: schema)
        let harness = makeClient { request in
            let body = try Self.requestBody(request)
            let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
            XCTAssertEqual(tools.count, 1)
            XCTAssertEqual(tools[0]["type"] as? String, "function")
            let function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
            XCTAssertEqual(function["name"] as? String, "page_search")
            XCTAssertEqual(function["description"] as? String, "Search this page")
            XCTAssertEqual((function["parameters"] as? [String: Any])?["required"] as? [String], ["query"])
            XCTAssertEqual(body["parallel_tool_calls"] as? Bool, false)
            return .json(#"{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"page_search","arguments":"{\"query\":\"Quartz\"}"}}],"reasoning_details":[{"type":"reasoning.encrypted","data":"opaque"}]}}]}"#)
        }
        defer { harness.finish() }
        let turn = try await harness.client.requestTurn(messages: [], configuration: defaultConfiguration, apiKey: "test-key", tools: [tool])
        XCTAssertEqual(turn.content, "")
        XCTAssertEqual(turn.toolCalls, [FacetToolCall(id: "call_1", name: "page_search", arguments: #"{"query":"Quartz"}"#)])
        XCTAssertEqual(turn.reasoningDetails, .array([.object(["type": .string("reasoning.encrypted"), "data": .string("opaque")])]))
    }

    func testTextModeRejectsUnexpectedToolRequests() async {
        let harness = makeClient { _ in
            .json(#"{"choices":[{"message":{"content":"Done","tool_calls":[{"id":"call_1","type":"function","function":{"name":"page_search","arguments":"{}"}}]}}]}"#)
        }
        defer { harness.finish() }
        do {
            _ = try await harness.client.run(messages: [], configuration: defaultConfiguration, apiKey: "test-key")
            XCTFail("Tool requests cannot masquerade as completed text in a text-only chat")
        } catch let error as FacetToolSessionError {
            guard case .invalidToolCall = error else { return XCTFail("Unexpected error: \(error)") }
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testMalformedAndTruncatedToolResponsesAreRejected() async {
        let tool = FacetToolDefinition(name: "page_search", description: "Search", inputSchema: .object([:]))
        for json in [
            #"{"choices":[{"message":{"tool_calls":"invalid"}}]}"#,
            #"{"choices":[{"message":{"tool_calls":[{"id":"a","type":"function","function":{"name":"page_search","arguments":{}}}]}}]}"#,
            #"{"choices":[{"message":{"tool_calls":[{"type":"function","function":{"name":"page_search","arguments":"{}"}}]}}]}"#,
            #"{"choices":[{"finish_reason":"length","message":{"tool_calls":[{"id":"a","type":"function","function":{"name":"page_search","arguments":"{}"}}]}}]}"#
        ] {
            let harness = makeClient { _ in .json(json) }
            defer { harness.finish() }
            do {
                _ = try await harness.client.requestTurn(messages: [], configuration: defaultConfiguration, apiKey: "test-key", tools: [tool])
                XCTFail("Malformed tool response accepted: \(json)")
            } catch { /* Invalid or incomplete tool requests must not reach an executor. */ }
        }
    }

    func testMessagesRemainCompatibleWithSavedTextAndEncodeToolHistory() throws {
        let old = try JSONDecoder().decode(FacetChatMessage.self, from: Data(#"{"role":"user","content":"Hello"}"#.utf8))
        XCTAssertEqual(old, FacetChatMessage(role: "user", content: "Hello"))
        let call = FacetToolCall(id: "call_1", name: "page_search", arguments: "{}")
        let messages = [
            FacetChatMessage(role: "assistant", content: "", toolCalls: [call], reasoningDetails: .array([.string("opaque")])),
            FacetChatMessage(role: "tool", content: #"{"found":true}"#, toolCallID: "call_1")
        ]
        let data = try JSONEncoder().encode(messages)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertTrue(wire[0]["content"] is NSNull)
        XCTAssertNotNil(wire[0]["tool_calls"])
        XCTAssertEqual(wire[0]["reasoning_details"] as? [String], ["opaque"])
        XCTAssertEqual(wire[1]["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(try JSONDecoder().decode([FacetChatMessage].self, from: data), messages)
    }

    func testOversizedToolMetadataFailsBeforeReturningAnExecutableTurn() async throws {
        let tool = FacetToolDefinition(name: "page_search", description: "Search", inputSchema: .object([:]))
        let call: [String: Any] = ["id": "a", "type": "function", "function": ["name": "page_search", "arguments": "{}"]]
        for message in [
            ["content": NSNull(), "tool_calls": Array(repeating: call, count: 129)],
            ["content": NSNull(), "tool_calls": [call], "reasoning_details": [["data": String(repeating: "x", count: 262_145)]]]
        ] as [[String: Any]] {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [["message": message]]]), as: UTF8.self)
            let harness = makeClient { _ in .json(json) }
            defer { harness.finish() }
            do {
                _ = try await harness.client.requestTurn(messages: [], configuration: defaultConfiguration, apiKey: "test-key", tools: [tool])
                XCTFail("Oversized metadata must not produce an executable turn")
            } catch let error as FacetOpenRouterError {
                guard case .invalidResponse = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testMissingAndMalformedKeysFailBeforeNetwork() async {
        let harness = makeClient { _ in
            XCTFail("An invalid key must not start a network request")
            return .json("{}")
        }
        defer { harness.finish() }

        for key in ["", " \n", "test\nkey"] {
            do {
                _ = try await harness.client.run(messages: [], configuration: defaultConfiguration, apiKey: key)
                XCTFail("Expected key validation to fail")
            } catch let error as FacetOpenRouterError {
                switch error {
                case .missingAPIKey where key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: break
                case .invalidAPIKey where key == "test\nkey": break
                default: XCTFail("Unexpected error: \(error)")
                }
            } catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testMultipartReplyExtractsTextWithoutReasoningOrMedia() async throws {
        let harness = makeClient { _ in
            .json(#"{"choices":[{"message":{"content":[{"type":"text","text":"Hello "},{"type":"reasoning","text":"private reasoning"},{"type":"image_url","image_url":{"url":"https://example.org/image"}},{"type":"output_text","text":"world."}],"reasoning":"hidden"}}]}"#)
        }
        defer { harness.finish() }
        let reply = try await harness.client.run(messages: [], configuration: defaultConfiguration, apiKey: "test-key")
        XCTAssertEqual(reply, "Hello world.")
    }

    func testHTTPFailuresExplainAuthenticationCreditsAndRateLimitsAndRedactKeys() async {
        for (status, expected) in [(401, "Check the key"), (402, "credits"), (429, "rate limiting")] {
            let harness = makeClient { _ in
                .json(#"{"error":{"message":"Provider detail for test-secret and sk-or-v1-another-secret"}}"#, status: status)
            }
            defer { harness.finish() }
            do {
                _ = try await harness.client.run(messages: [], configuration: defaultConfiguration, apiKey: "test-secret")
                XCTFail("Expected an HTTP failure")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains("Provider detail"))
                XCTAssertFalse(error.localizedDescription.contains("test-secret"))
                XCTAssertFalse(error.localizedDescription.contains("sk-or-v1-another-secret"))
            }
        }
    }

    func testSuccessfulHTTPStatusStillRejectsProviderErrors() async {
        for json in [
            #"{"error":{"code":402,"message":"No credits remain."}}"#,
            #"{"choices":[{"error":{"code":"402","message":"No credits remain."},"message":{"content":"partial reply"}}]}"#
        ] {
            let harness = makeClient { _ in .json(json) }
            defer { harness.finish() }
            do {
                _ = try await harness.client.run(messages: [], configuration: defaultConfiguration, apiKey: "test-key")
                XCTFail("Expected the error envelope to fail")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("credits"))
                XCTAssertTrue(error.localizedDescription.contains("No credits remain."))
            }
        }
    }

    func testMalformedAndEmptyResponsesFailClearly() async {
        for json in ["not JSON", "{}", #"{"choices":[]}"#, #"{"choices":[{"message":{"content":42}}]}"#,
                     #"{"choices":[{"message":{"content":[{"type":"text","text":42},{"type":"text","text":"partial reply"}]}}]}"#,
                     #"{"choices":[{"message":{"content":" \n"}}]}"#, #"{"choices":[{"message":{"content":null,"reasoning":"thoughts only"}}]}"#] {
            let harness = makeClient { _ in .json(json) }
            defer { harness.finish() }
            do {
                _ = try await harness.client.run(messages: [], configuration: defaultConfiguration, apiKey: "test-key")
                XCTFail("Expected unusable response to fail: \(json)")
            } catch let error as FacetOpenRouterError {
                switch error {
                case .invalidResponse, .emptyResponse: break
                default: XCTFail("Unexpected response error: \(error)")
                }
            } catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testFailedCompletionDoesNotReturnPartialText() async {
        let harness = makeClient { _ in
            .json(#"{"choices":[{"finish_reason":"error","message":{"content":"partial reply"}}]}"#)
        }
        defer { harness.finish() }
        do {
            _ = try await harness.client.run(messages: [], configuration: defaultConfiguration, apiKey: "test-key")
            XCTFail("A failed generation must not be presented as a completed answer")
        } catch let error as FacetOpenRouterError {
            guard case .service = error else { return XCTFail("Unexpected error: \(error)") }
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCancellingTaskStopsUnderlyingRequest() async {
        let started = expectation(description: "Request started")
        let stopped = expectation(description: "Request cancelled")
        let harness = makeClient { _ in
            .pending(onStart: { started.fulfill() }, onStop: { stopped.fulfill() })
        }
        defer { harness.finish() }
        let task = Task {
            try await harness.client.run(messages: [], configuration: defaultConfiguration, apiKey: "test-key")
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled requests must not produce a reply")
        } catch is CancellationError {
            // Cancellation reaches URLSession and is kept distinct from a service failure.
        } catch { XCTFail("Unexpected cancellation error: \(error)") }
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testModelCatalogFiltersModalitiesDeduplicatesAndRespectsReasoningMetadata() async throws {
        let harness = makeClient { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/models")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.httpMethod, "GET")
            return .json(#"""
            {"data":[
              {"id":"vendor/zeta","name":"Zeta","architecture":{"input_modalities":["text"],"output_modalities":["text"]},"reasoning":{"supported_efforts":["none","high","unknown","high"]}},
              {"id":"vendor/zeta","name":"Duplicate","architecture":{"input_modalities":["text"],"output_modalities":["text"]}},
              {"id":"vendor/alpha","name":"Alpha","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"reasoning":{"supported_efforts":null,"mandatory":true}},
              {"id":"vendor/beta","name":"Beta","architecture":{"input_modalities":["text"],"output_modalities":["text"]},"supported_parameters":["reasoning"],"reasoning":{"mandatory":false}},
              {"id":"vendor/all","name":"All efforts","architecture":{"input_modalities":["text"],"output_modalities":["text"]},"reasoning":{"supported_efforts":null}},
              {"id":"vendor/image","architecture":{"input_modalities":["text"],"output_modalities":["image"]}},
              {"id":"vendor/audio","architecture":{"input_modalities":["audio"],"output_modalities":["text"]}},
              {"id":"vendor/missing-architecture"},
              {"id":" ","architecture":{"input_modalities":["text"],"output_modalities":["text"]}}
            ]}
            """#)
        }
        defer { harness.finish() }
        let options = try await harness.client.loadModelOptions()
        XCTAssertEqual(options.map(\.slug), ["openrouter/auto", "vendor/all", "vendor/alpha", "vendor/beta", "vendor/zeta"])
        XCTAssertEqual(options.first?.supportedReasoningEfforts, [])
        XCTAssertEqual(options.first { $0.slug == "vendor/all" }?.supportedReasoningEfforts, FacetConfiguration.reasoningEfforts)
        XCTAssertEqual(options.first { $0.slug == "vendor/alpha" }?.supportedReasoningEfforts, ["max", "xhigh", "high", "medium", "low", "minimal"])
        XCTAssertEqual(options.first { $0.slug == "vendor/beta" }?.supportedReasoningEfforts, [])
        XCTAssertEqual(options.first { $0.slug == "vendor/zeta" }?.supportedReasoningEfforts, ["high", "none"])
        XCTAssertEqual(options.last?.displayName, "Zeta")
    }

    func testModelCatalogRejectsMalformedEnvelope() async {
        let harness = makeClient { _ in .json(#"{"data":"not a list"}"#) }
        defer { harness.finish() }
        do {
            _ = try await harness.client.loadModelOptions()
            XCTFail("Expected malformed catalog to fail")
        } catch let error as FacetOpenRouterError {
            guard case .invalidResponse = error else { return XCTFail("Unexpected error: \(error)") }
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testModelCatalogOnlyOffersSynchronousModelsWithTextOutput() async throws {
        let harness = makeClient { _ in
            .json(#"""
            {"data":[
              {"id":"vendor/model","architecture":{"input_modalities":["text","image","audio"],"output_modalities":["text"]}},
              {"id":"vendor/model:batch","architecture":{"input_modalities":["text"],"output_modalities":["text"]}},
              {"id":"vendor/model:batch:online","architecture":{"input_modalities":["text"],"output_modalities":["text"]}},
              {"id":"vendor/model:free","architecture":{"input_modalities":["text"],"output_modalities":["text"]}},
              {"id":"vendor/image-generator","architecture":{"input_modalities":["text"],"output_modalities":["image","text"]}},
              {"id":"vendor/music-generator","architecture":{"input_modalities":["text"],"output_modalities":["text","audio"]}},
              {"id":"vendor/empty-output","architecture":{"input_modalities":["text"],"output_modalities":[]}}
            ]}
            """#)
        }
        defer { harness.finish() }
        let options = try await harness.client.loadModelOptions()
        XCTAssertEqual(options.map(\.slug), ["openrouter/auto", "vendor/model", "vendor/model:free"])
    }

    private var defaultConfiguration: FacetConfiguration { FacetConfiguration(model: nil, reasoningEffort: nil) }

    private func makeClient(handler: @escaping @Sendable (URLRequest) throws -> FacetStubURLProtocol.Reply) -> Harness {
        let id = UUID().uuidString
        FacetStubURLProtocol.handlers.set(handler, for: id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FacetStubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Facet-Test": id]
        let session = URLSession(configuration: configuration)
        return Harness(client: FacetOpenRouterClient(session: session), session: session, id: id)
    }

    private static func requestBody(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private struct Harness: Sendable {
        let client: FacetOpenRouterClient
        let session: URLSession
        let id: String

        func finish() {
            session.invalidateAndCancel()
            FacetStubURLProtocol.handlers.remove(id)
        }
    }
}

private final class FacetStubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case json(String, status: Int = 200)
        case pending(onStart: @Sendable () -> Void, onStop: @Sendable () -> Void)
    }

    final class Handlers: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: @Sendable (URLRequest) throws -> Reply] = [:]

        func set(_ handler: @escaping @Sendable (URLRequest) throws -> Reply, for id: String) {
            lock.withLock { values[id] = handler }
        }

        func get(_ id: String) -> (@Sendable (URLRequest) throws -> Reply)? {
            lock.withLock { values[id] }
        }

        func remove(_ id: String) {
            _ = lock.withLock { values.removeValue(forKey: id) }
        }
    }

    static let handlers = Handlers()
    private let lock = NSLock()
    private var onStop: (@Sendable () -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Facet-Test"), let handler = Self.handlers.get(id) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            switch try handler(request) {
            case let .json(json, status):
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(json.utf8))
                client?.urlProtocolDidFinishLoading(self)
            case let .pending(onStart, onStop):
                lock.withLock { self.onStop = onStop }
                onStart()
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        let callback = lock.withLock {
            let callback = onStop
            onStop = nil
            return callback
        }
        callback?()
    }
}
