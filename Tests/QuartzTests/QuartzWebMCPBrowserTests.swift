import AppKit
import WebKit
import XCTest
@testable import Quartz

@MainActor
final class QuartzWebMCPBrowserTests: XCTestCase {
    func testPageToolsDefaultOffAndAreNotSentToTheModel() async throws {
        let harness = try await makeBrowser()
        defer { harness.finish() }
        let checkbox = try pageToolsCheckbox(in: harness.panel)
        XCTAssertEqual(checkbox.state, .off)
        submit(in: harness)
        try await waitUntil { !harness.panel.isRunning }
        XCTAssertNil(harness.browser.extensionWindow?.attachedSheet)
        XCTAssertEqual(harness.transport.requests.count, 1)
        let request = try XCTUnwrap(harness.transport.requests.first)
        guard case let .object(fields) = request else { return XCTFail("Expected request object") }
        XCTAssertNil(fields["tools"])
        XCTAssertNil(fields["parallel_tool_calls"])
        try await assertExecutionCount(0, in: harness.webView)
        XCTAssertTrue(transcript(in: harness.panel).contains("Text-only reply."))
    }

    func testNativeApprovalPrecedesExecutionAndReturnsTheToolResultToFacet() async throws {
        let harness = try await makeBrowser()
        defer { harness.finish() }
        try pageToolsCheckbox(in: harness.panel).state = .on
        submit(in: harness)
        let window = try XCTUnwrap(harness.browser.extensionWindow)
        try await waitUntil { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        let content = try XCTUnwrap(sheet.contentView)
        try await assertExecutionCount(0, in: harness.webView)
        XCTAssertEqual(harness.transport.requests.count, 1)
        let reviewText = descendants(of: content).compactMap { ($0 as? NSTextView)?.string }.joined(separator: "\n")
        XCTAssertTrue(reviewText.contains("Tool: echo_action"))
        XCTAssertTrue(reviewText.contains("approved value"))
        XCTAssertTrue(reviewText.contains("Website-provided description"))
        let labels = descendants(of: content).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n")
        XCTAssertTrue(labels.contains("https://example.org"))
        XCTAssertTrue(labels.contains("OpenRouter"))
        let allow = try button(titled: "Allow once", in: content)
        XCTAssertEqual(allow.keyEquivalent, "")
        allow.performClick(nil)
        try await waitUntil { !harness.panel.isRunning && window.attachedSheet == nil }
        try await assertExecutionCount(1, in: harness.webView)
        let output = try await harness.webView.callAsyncJavaScript("return document.getElementById('output').textContent;", in: nil, contentWorld: .page)
        XCTAssertEqual(output as? String, "approved value")
        XCTAssertEqual(harness.transport.requests.count, 2)
        let followup = try XCTUnwrap(harness.transport.requests.last)
        guard case let .object(fields) = followup, case let .array(messages) = fields["messages"],
              case let .object(result) = messages.last else { return XCTFail("Expected a tool result in the follow-up") }
        XCTAssertEqual(result["role"], .string("tool"))
        XCTAssertEqual(result["tool_call_id"], .string("native_approval_call"))
        guard case let .string(resultJSON) = result["content"] else { return XCTFail("Expected serialized tool output") }
        XCTAssertEqual(try FacetJSONValue(jsonString: resultJSON), .object([
            "received": .string("approved value"), "executionCount": .number(1)
        ]))
        XCTAssertTrue(transcript(in: harness.panel).contains("The page action finished."))
        XCTAssertEqual(harness.personalization.history.messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(harness.personalization.history.messages.last?.content, "The page action finished.")
        XCTAssertTrue(harness.personalization.history.messages.allSatisfy { $0.toolCalls == nil && $0.toolCallID == nil })
    }

    func testCancelAndDefaultReturnKeyStopWithoutExecutionOrModelFollowup() async throws {
        for useReturnKey in [false, true] {
            let harness = try await makeBrowser()
            defer { harness.finish() }
            try pageToolsCheckbox(in: harness.panel).state = .on
            submit(in: harness)
            let window = try XCTUnwrap(harness.browser.extensionWindow)
            try await waitUntil { window.attachedSheet != nil }
            let sheet = try XCTUnwrap(window.attachedSheet)
            let cancel = try button(titled: "Cancel", in: XCTUnwrap(sheet.contentView))
            XCTAssertEqual(cancel.keyEquivalent, "\r")
            try await assertExecutionCount(0, in: harness.webView)
            if useReturnKey {
                let event = try XCTUnwrap(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                    isARepeat: false, keyCode: 36
                ))
                XCTAssertTrue(sheet.performKeyEquivalent(with: event), "The sheet must route Return to Cancel")
            } else {
                cancel.performClick(nil)
            }
            try await waitUntil { !harness.panel.isRunning && window.attachedSheet == nil }
            try await assertExecutionCount(0, in: harness.webView)
            XCTAssertEqual(harness.transport.requests.count, 1)
            XCTAssertTrue(transcript(in: harness.panel).contains("Page tool canceled"))
            XCTAssertTrue(harness.personalization.history.messages.isEmpty)
        }
    }

    func testNavigationDismissesApprovalAndStopsThePendingTool() async throws {
        let harness = try await makeBrowser()
        defer { harness.finish() }
        try pageToolsCheckbox(in: harness.panel).state = .on
        submit(in: harness)
        let window = try XCTUnwrap(harness.browser.extensionWindow)
        try await waitUntil { window.attachedSheet != nil }
        try await assertExecutionCount(0, in: harness.webView)
        harness.webView.loadHTMLString(
            "<html><title>New document</title><body><script>window.executionCount = 0;</script>New page</body></html>",
            baseURL: URL(string: "https://example.org/next")
        )
        try await waitUntil {
            window.attachedSheet == nil && !harness.panel.isRunning && !harness.webView.isLoading && harness.webView.title == "New document"
        }
        try await assertExecutionCount(0, in: harness.webView)
        XCTAssertEqual(harness.transport.requests.count, 1)
        XCTAssertTrue(transcript(in: harness.panel).contains("The page changed"))
        XCTAssertTrue(harness.personalization.history.messages.isEmpty)
    }

    private func makeBrowser() async throws -> Harness {
        _ = NSApplication.shared
        let suite = "QuartzWebMCPBrowserTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let transport = BrowserToolTransport()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [BrowserToolURLProtocol.self]
        sessionConfiguration.httpAdditionalHeaders = ["X-Facet-Browser-Test": transport.id]
        let session = URLSession(configuration: sessionConfiguration)
        let client = FacetOpenRouterClient(session: session)
        // Completing this test chat must never start personalization with a user's saved key.
        let personalization = FacetPersonalizationController(defaults: defaults, apiKey: { nil })
        let browser: BrowserController
        if #available(macOS 15.4, *) {
            let initial = BrowserController(sessionDefaults: defaults, facetPersonalization: personalization, facetClient: client)
            let support = QuartzWebExtensionSupport(browser: initial, webViewConfiguration: WKWebViewConfiguration(), defaults: defaults)
            browser = BrowserController(sharedExtensionSupport: support, restoresSavedSession: false, focusesWindow: false,
                                        sessionDefaults: defaults, facetPersonalization: personalization, facetClient: client)
        } else {
            browser = BrowserController(restoresSavedSession: false, focusesWindow: false, sessionDefaults: defaults,
                                        facetPersonalization: personalization, facetClient: client)
        }
        browser.start()
        do {
            try await waitUntil { browser.extensionURL == QuartzStartPage.url && browser.extensionWebView?.isLoading == false }
            let webView = try XCTUnwrap(browser.extensionWebView)
            webView.loadHTMLString("<html><title>WebMCP browser test</title><body><p id='output'>untouched</p></body></html>", baseURL: URL(string: "https://example.org/tools"))
            try await waitUntil { !webView.isLoading && webView.title == "WebMCP browser test" }
            _ = try await webView.callAsyncJavaScript("""
            window.executionCount = 0;
            await document.modelContext.registerTool({
                name: 'echo_action', description: "Set the page's visible value.",
                inputSchema: {type:'object', properties:{value:{type:'string'}}, required:['value']},
                execute: ({value}) => {
                    window.executionCount++;
                    document.getElementById('output').textContent = value;
                    return {received:value, executionCount:window.executionCount};
                }
            });
            return true;
            """, in: nil, contentWorld: .page)
            let content = try XCTUnwrap(browser.extensionWindow?.contentView)
            let panel = try XCTUnwrap(descendants(of: content).compactMap { $0 as? FacetPanelView }.first)
            return Harness(browser: browser, webView: webView, panel: panel, personalization: personalization,
                           transport: transport, session: session, defaults: defaults, suite: suite)
        } catch {
            browser.extensionWindow?.close()
            personalization.stop()
            session.invalidateAndCancel()
            transport.finish()
            defaults.removePersistentDomain(forName: suite)
            throw error
        }
    }

    private func submit(in harness: Harness) {
        harness.browser.facetPanel(harness.panel, didSubmit: "Set the page value to approved value.", includePageContext: false,
                                   configuration: FacetConfiguration(model: "test/tool-model", reasoningEffort: nil), apiKey: "test-key")
    }

    private func pageToolsCheckbox(in panel: FacetPanelView) throws -> NSButton {
        try button(titled: "Page tools (WebMCP)", in: panel)
    }

    private func button(titled title: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSButton }.first { $0.title == title })
    }

    private func executionCount(in webView: WKWebView) async throws -> Int {
        let value = try await webView.callAsyncJavaScript("return window.executionCount;", in: nil, contentWorld: .page)
        return try XCTUnwrap(value as? Int)
    }

    private func assertExecutionCount(_ expected: Int, in webView: WKWebView) async throws {
        let actual = try await executionCount(in: webView)
        XCTAssertEqual(actual, expected)
    }

    private func transcript(in panel: FacetPanelView) -> String {
        descendants(of: panel).compactMap { ($0 as? NSTextView)?.string }.joined(separator: "\n")
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() {
            guard Date() < deadline else { throw NSError(domain: "QuartzWebMCPBrowserTests.Timeout", code: 1) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    private struct Harness {
        let browser: BrowserController
        let webView: WKWebView
        let panel: FacetPanelView
        let personalization: FacetPersonalizationController
        let transport: BrowserToolTransport
        let session: URLSession
        let defaults: UserDefaults
        let suite: String

        func finish() {
            browser.extensionWindow?.close()
            personalization.stop()
            session.invalidateAndCancel()
            transport.finish()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

private final class BrowserToolTransport: @unchecked Sendable {
    let id = UUID().uuidString
    private let lock = NSLock()
    private var capturedRequests: [FacetJSONValue] = []

    init() { BrowserToolURLProtocol.registry.add(self) }

    var requests: [FacetJSONValue] { lock.withLock { capturedRequests } }

    func finish() { BrowserToolURLProtocol.registry.remove(id) }

    func reply(to request: URLRequest) throws -> Data {
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
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
        let body = try JSONDecoder().decode(FacetJSONValue.self, from: data)
        lock.withLock { capturedRequests.append(body) }
        guard case let .object(fields) = body else { throw URLError(.cannotParseResponse) }
        let json: String
        if fields["tools"] == nil {
            json = #"{"choices":[{"message":{"content":"Text-only reply."}}]}"#
        } else if case let .array(messages) = fields["messages"], case let .object(last) = messages.last, last["role"] == .string("tool") {
            json = #"{"choices":[{"message":{"content":"The page action finished."}}]}"#
        } else {
            json = #"{"choices":[{"finish_reason":"tool_calls","message":{"content":null,"tool_calls":[{"id":"native_approval_call","type":"function","function":{"name":"quartz_page_tool_0","arguments":"{\"value\":\"approved value\"}"}}]}}]}"#
        }
        return Data(json.utf8)
    }
}

private final class BrowserToolURLProtocol: URLProtocol, @unchecked Sendable {
    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var transports: [String: BrowserToolTransport] = [:]
        func add(_ transport: BrowserToolTransport) { lock.withLock { transports[transport.id] = transport } }
        func get(_ id: String) -> BrowserToolTransport? { lock.withLock { transports[id] } }
        func remove(_ id: String) { _ = lock.withLock { transports.removeValue(forKey: id) } }
    }

    static let registry = Registry()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let id = request.value(forHTTPHeaderField: "X-Facet-Browser-Test"), let transport = Self.registry.get(id) else {
                throw URLError(.badURL)
            }
            let data = try transport.reply(to: request)
            let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
