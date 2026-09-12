import Foundation
import XCTest
@testable import Quartz

@MainActor
final class FacetToolSessionTests: XCTestCase {
    private let searchTool = FacetToolDefinition(
        name: "page_search", description: "Search this page",
        inputSchema: .object(["type": .string("object")])
    )

    func testJSONRoundTripsNestedValuesWithoutTypeConfusion() throws {
        let value = try FacetJSONValue(jsonString: #"{"string":"<script>\\\"","number":1.25,"boolean":true,"null":null,"array":[false,0,{},[]]}"#)
        XCTAssertEqual(try FacetJSONValue(jsonString: value.jsonString()), value)
        guard case let .object(fields) = value else { return XCTFail("Expected an object") }
        XCTAssertEqual(fields["boolean"], .bool(true))
        XCTAssertEqual(fields["number"], .number(1.25))
        XCTAssertThrowsError(try FacetJSONValue(jsonString: "NaN"))
        XCTAssertThrowsError(try FacetJSONValue.number(.infinity).jsonString())
    }

    func testToolLoopReturnsFinalTextAndCorrelatesEphemeralResults() async throws {
        let initial = [FacetChatMessage(role: "user", content: "Find Quartz")]
        let call = FacetToolCall(id: "call_1", name: "page_search", arguments: #"{"query":"Quartz"}"#)
        var requests = 0
        var executions = 0
        let answer = try await FacetToolSession.run(messages: initial, tools: [searchTool]) { messages, tools in
            requests += 1
            XCTAssertEqual(tools, [self.searchTool])
            if requests == 1 {
                XCTAssertEqual(messages, initial)
                return FacetAssistantTurn(content: "", toolCalls: [call], reasoningDetails: .array([.string("opaque")]))
            }
            XCTAssertEqual(messages.map(\.role), ["user", "assistant", "tool"])
            XCTAssertEqual(messages[1].toolCalls, [call])
            XCTAssertEqual(messages[1].reasoningDetails, .array([.string("opaque")]))
            XCTAssertEqual(messages[2].toolCallID, call.id)
            XCTAssertEqual(try FacetJSONValue(jsonString: messages[2].content), .object(["found": .bool(true)]))
            return FacetAssistantTurn(content: "Found Quartz.")
        } execute: { requestedCall, arguments in
            executions += 1
            XCTAssertEqual(requestedCall, call)
            XCTAssertEqual(arguments, .object(["query": .string("Quartz")]))
            return .object(["found": .bool(true)])
        }
        XCTAssertEqual(answer, "Found Quartz.")
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(executions, 1)
        XCTAssertEqual(initial.count, 1)
    }

    func testInvalidBatchNeverExecutesAnEarlierValidCall() async throws {
        let valid = FacetToolCall(id: "valid", name: "page_search", arguments: "{}")
        let wrongType = try JSONDecoder().decode(FacetToolCall.self, from: Data(#"{"id":"invalid","type":"server_tool","function":{"name":"page_search","arguments":"{}"}}"#.utf8))
        let invalidCalls = [
            FacetToolCall(id: "unknown", name: "hallucinated_tool", arguments: "{}"),
            FacetToolCall(id: "array", name: "page_search", arguments: "[]"),
            FacetToolCall(id: "scalar", name: "page_search", arguments: "42"),
            FacetToolCall(id: "null", name: "page_search", arguments: "null"),
            FacetToolCall(id: "malformed", name: "page_search", arguments: "{"),
            FacetToolCall(id: "", name: "page_search", arguments: "{}"),
            FacetToolCall(id: "with space", name: "page_search", arguments: "{}"),
            FacetToolCall(id: String(repeating: "a", count: 201), name: "page_search", arguments: "{}"),
            FacetToolCall(id: "valid", name: "page_search", arguments: "{}"),
            FacetToolCall(id: "oversized", name: "page_search", arguments: "{\"text\":\"" + String(repeating: "a", count: 65_537) + "\"}"),
            wrongType
        ]
        for invalid in invalidCalls {
            var executions = 0
            do {
                _ = try await FacetToolSession.run(messages: [], tools: [searchTool]) { _, _ in
                    FacetAssistantTurn(content: "", toolCalls: [valid, invalid])
                } execute: { _, _ in
                    executions += 1
                    return .null
                }
                XCTFail("Expected invalid call to stop session: \(invalid.id)")
            } catch let error as FacetToolSessionError {
                guard case .invalidToolCall = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(executions, 0)
        }
    }

    func testDuplicateCallIDAcrossRoundsIsNeverExecutedTwice() async {
        var requests = 0
        var executions = 0
        do {
            _ = try await FacetToolSession.run(messages: [], tools: [searchTool]) { _, _ in
                requests += 1
                return FacetAssistantTurn(content: "", toolCalls: [FacetToolCall(id: "repeat", name: "page_search", arguments: "{}")])
            } execute: { _, _ in
                executions += 1
                return .null
            }
            XCTFail("Expected repeated call ID to stop the loop")
        } catch let error as FacetToolSessionError {
            guard case .invalidToolCall = error else { return XCTFail("Unexpected error: \(error)") }
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(executions, 1)
    }

    func testErrorsBecomeToolResultsSoTheModelCanExplainFailure() async throws {
        var requests = 0
        let answer = try await FacetToolSession.run(messages: [], tools: [searchTool]) { messages, _ in
            requests += 1
            if requests == 1 {
                return FacetAssistantTurn(content: "", toolCalls: [FacetToolCall(id: "failed", name: "page_search", arguments: "{}")])
            }
            XCTAssertEqual(messages.last?.toolCallID, "failed")
            XCTAssertEqual(try FacetJSONValue(jsonString: XCTUnwrap(messages.last?.content)), .object([
                "isError": .bool(true), "error": .string("The page search failed.")
            ]))
            return FacetAssistantTurn(content: "The page search failed.")
        } execute: { _, _ in
            throw TestError.pageFailure
        }
        XCTAssertEqual(answer, "The page search failed.")
    }

    func testDenialOrNavigationCancellationStopsEntireBatchAndLoop() async {
        var requests = 0
        var executions = 0
        do {
            _ = try await FacetToolSession.run(messages: [], tools: [searchTool]) { _, _ in
                requests += 1
                return FacetAssistantTurn(content: "", toolCalls: [
                    FacetToolCall(id: "first", name: "page_search", arguments: "{}"),
                    FacetToolCall(id: "second", name: "page_search", arguments: "{}")
                ])
            } execute: { _, _ in
                executions += 1
                throw CancellationError()
            }
            XCTFail("A denied action must stop the whole session")
        } catch is CancellationError {
            // The caller distinguishes user denial/navigation from a tool failure.
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(executions, 1)
    }

    func testTaskCancellationBetweenModelAndExecutionPreventsTheAction() async {
        var executions = 0
        let task = Task { @MainActor in
            try await FacetToolSession.run(messages: [], tools: [searchTool]) { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return FacetAssistantTurn(content: "", toolCalls: [FacetToolCall(id: "first", name: "page_search", arguments: "{}")])
            } execute: { _, _ in
                executions += 1
                return .null
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled model turns cannot execute tools")
        } catch is CancellationError {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(executions, 0)
    }

    func testMaximumRoundsAllowsFinalAnswerButNoAdditionalExecution() async throws {
        var requests = 0
        var executions = 0
        let answer = try await FacetToolSession.run(messages: [], tools: [searchTool], maximumRounds: 1) { _, _ in
            requests += 1
            if requests == 1 {
                return FacetAssistantTurn(content: "", toolCalls: [FacetToolCall(id: "one", name: "page_search", arguments: "{}")])
            }
            return FacetAssistantTurn(content: "Done.")
        } execute: { _, _ in
            executions += 1
            return .null
        }
        XCTAssertEqual(answer, "Done.")
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(executions, 1)

        requests = 0
        executions = 0
        do {
            _ = try await FacetToolSession.run(messages: [], tools: [searchTool], maximumRounds: 1) { _, _ in
                requests += 1
                return FacetAssistantTurn(content: "", toolCalls: [FacetToolCall(id: "call_\(requests)", name: "page_search", arguments: "{}")])
            } execute: { _, _ in
                executions += 1
                return .null
            }
            XCTFail("Expected round limit")
        } catch let error as FacetToolSessionError {
            guard case .limitReached = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(executions, 1)
    }

    func testOversizedBatchFailsBeforeAnyToolRuns() async {
        var executions = 0
        do {
            _ = try await FacetToolSession.run(messages: [], tools: [searchTool], maximumToolCalls: 1) { _, _ in
                FacetAssistantTurn(content: "", toolCalls: [
                    FacetToolCall(id: "one", name: "page_search", arguments: "{}"),
                    FacetToolCall(id: "two", name: "page_search", arguments: "{}")
                ])
            } execute: { _, _ in
                executions += 1
                return .null
            }
            XCTFail("Expected call limit")
        } catch let error as FacetToolSessionError {
            guard case .limitReached = error else { return XCTFail("Unexpected error: \(error)") }
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(executions, 0)
    }

    func testOversizedResultIsReplacedWithBoundedValidJSON() async throws {
        var requests = 0
        _ = try await FacetToolSession.run(messages: [], tools: [searchTool]) { messages, _ in
            requests += 1
            if requests == 1 {
                return FacetAssistantTurn(content: "", toolCalls: [FacetToolCall(id: "large", name: "page_search", arguments: "{}")])
            }
            let content = try XCTUnwrap(messages.last?.content)
            XCTAssertLessThan(content.utf8.count, 500)
            guard case let .object(result) = try FacetJSONValue(jsonString: content) else {
                XCTFail("Expected valid JSON error result")
                return FacetAssistantTurn(content: "Failed.")
            }
            XCTAssertEqual(result["isError"], .bool(true))
            return FacetAssistantTurn(content: "The result was too large.")
        } execute: { _, _ in
            .string(String(repeating: "x", count: 65_537))
        }
    }

    func testInvalidDefinitionsFailBeforeCallingTheModel() async {
        for tools in [
            [searchTool, searchTool],
            [FacetToolDefinition(name: "bad name", description: "Invalid", inputSchema: .object([:]))],
            [FacetToolDefinition(name: "array_schema", description: "Invalid", inputSchema: .array([]))]
        ] {
            do {
                _ = try await FacetToolSession.run(messages: [], tools: tools) { _, _ in
                    XCTFail("Invalid tools must not be advertised")
                    return FacetAssistantTurn(content: "Unexpected")
                } execute: { _, _ in
                    XCTFail("Invalid tools must not execute")
                    return .null
                }
                XCTFail("Expected invalid definitions to fail")
            } catch let error as FacetToolSessionError {
                guard case .invalidTools = error else { return XCTFail("Unexpected error: \(error)") }
            } catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    private enum TestError: LocalizedError {
        case pageFailure

        var errorDescription: String? { "The page search failed." }
    }
}
