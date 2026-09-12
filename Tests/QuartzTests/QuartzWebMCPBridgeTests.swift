import AppKit
import WebKit
import XCTest
@testable import Quartz

@MainActor
final class QuartzWebMCPBridgeTests: XCTestCase, WKNavigationDelegate {
    private var loaded: XCTestExpectation?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.fulfill() }

    private func makeWebView() -> (NSWindow, WKWebView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        QuartzWebMCPBridge.install(in: config.userContentController)
        let webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        window.contentView = webView
        webView.navigationDelegate = self
        return (window, webView)
    }

    private func load(_ html: String = "<html><body>WebMCP</body></html>", in webView: WKWebView, url: String = "https://example.org/tools") async {
        loaded = expectation(description: "Load page")
        webView.loadHTMLString(html, baseURL: URL(string: url))
        await fulfillment(of: [loaded!], timeout: 15)
        loaded = nil
    }

    private func register(in webView: WKWebView) async throws {
        _ = try await webView.callAsyncJavaScript("""
        await document.modelContext.registerTool({
          name: 'echo', description: 'Echo a value',
          inputSchema: {type:'object', properties:{value:{type:'string'}}, required:['value']},
          execute: ({value}) => ({echo:value})
        });
        return true;
        """, arguments: [:], in: nil, contentWorld: .page)
    }

    func testOnlySecureWebAndLoopbackURLsAreEligible() {
        for url in ["https://example.org", "http://localhost:8000", "http://127.0.0.1:9000", "http://[::1]:8000", "http://test.localhost"] {
            XCTAssertTrue(QuartzWebMCPBridge.isEligibleURL(URL(string: url)), url)
        }
        for url in ["http://example.org", "http://localhost.evil.org", "https://user:password@example.org", "file:///tmp/page.html", "about:blank", "data:text/html,hello", "quartz://home", "webkit-extension://example/"] {
            XCTAssertFalse(QuartzWebMCPBridge.isEligibleURL(URL(string: url)), url)
        }
        XCTAssertFalse(QuartzWebMCPBridge.isEligibleURL(nil))
    }

    func testPermissionsPolicyUsesTheNativeResponseOriginAndFailsClosed() {
        let url = URL(string: "https://example.org/path")!
        for header in [nil, "camera=()", "tools=*", "tools=(self)", "tools=(\"https://example.org\")", "tools=(\"https://example.org:443\")"] as [String?] {
            XCTAssertTrue(QuartzWebMCPBridge.policyAllowsTools(header, url: url), header ?? "nil")
        }
        for header in ["tools=()", "tools=(\"https://other.org\")", "tools=(\"http://example.org\")", "tools=(\"https://example.org:444\")", "tools=garbage", "tools", "camera=(), tools=()", "tools=(), tools=(self)"] {
            XCTAssertFalse(QuartzWebMCPBridge.policyAllowsTools(header, url: url), header)
        }
    }

    func testDiscoveryExecutionAndAliasMappingInRealWebKit() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        await load(in: webView)
        try await register(in: webView)
        let bridge = QuartzWebMCPBridge()
        let discovered = try await bridge.discover(in: webView)
        let page = try XCTUnwrap(discovered)
        let tool = try XCTUnwrap(page.tool(named: "quartz_page_tool_0"))
        XCTAssertEqual(tool.name, "echo")
        XCTAssertNil(page.tool(named: "echo"))
        XCTAssertEqual(page.url, webView.url)
        let hostile = "' ; throw Error('injection') // 雪 & <script>"
        let result = try await bridge.execute(tool, input: .object(["value": .string(hostile)]), page: page, in: webView)
        XCTAssertEqual(result, .object(["echo": .string(hostile)]))
    }

    func testSchemaWithoutExplicitRootTypeRemainsAvailable() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        await load(in: webView)
        _ = try await webView.callAsyncJavaScript("""
        await document.modelContext.registerTool({name:'optional_type', description:'No explicit root type',
          inputSchema:{properties:{value:{type:'string'}}}, execute: input => input}); return true;
        """, arguments: [:], in: nil, contentWorld: .page)
        let discovered = try await QuartzWebMCPBridge().discover(in: webView)
        let page = try XCTUnwrap(discovered)
        XCTAssertEqual(page.tools.count, 1)
        guard case .object(let schema) = page.definitions[0].inputSchema else { return XCTFail("Expected object schema") }
        XCTAssertEqual(schema["type"], .string("object"))
    }

    func testNativePolicyBlocksDiscoveryAndNewDocumentRestoresDefault() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        await load(in: webView)
        try await register(in: webView)
        let bridge = QuartzWebMCPBridge()
        bridge.receiveMainDocumentResponse(HTTPURLResponse(url: webView.url!, statusCode: 200, httpVersion: nil, headerFields: ["Permissions-Policy": "tools=()"])!)
        bridge.commitMainDocument()
        let blocked = try await bridge.discover(in: webView)
        XCTAssertNil(blocked)
        bridge.invalidate()
        let afterFailedNavigation = try await bridge.discover(in: webView)
        XCTAssertNil(afterFailedNavigation, "A failed provisional navigation must preserve the committed document's restrictions")
        bridge.commitMainDocument(isHistoryNavigation: true)
        let unknownRestoration = try await bridge.discover(in: webView)
        XCTAssertNil(unknownRestoration, "A history restoration without a known native policy must fail closed")
        bridge.commitMainDocument()
        let restored = try await bridge.discover(in: webView)
        XCTAssertEqual(restored?.tools.count, 1)
    }

    func testNavigationAndRegistrationReplacementInvalidatePendingTools() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        await load(in: webView)
        try await register(in: webView)
        let bridge = QuartzWebMCPBridge()
        let discovered = try await bridge.discover(in: webView)
        let page = try XCTUnwrap(discovered)
        let tool = try XCTUnwrap(page.tools.first)
        _ = try await webView.callAsyncJavaScript("document.modelContext.unregisterTool('echo'); return true;", arguments: [:], in: nil, contentWorld: .page)
        try await register(in: webView)
        do {
            _ = try await bridge.execute(tool, input: .object(["value": .string("old")]), page: page, in: webView)
            XCTFail("A replaced tool must require new discovery and approval")
        } catch QuartzWebMCPError.pageChanged {}
        let secondSnapshot = try await bridge.discover(in: webView)
        let secondPage = try XCTUnwrap(secondSnapshot)
        bridge.invalidate()
        do {
            try await bridge.validate(secondPage, tool: secondPage.tools[0], in: webView)
            XCTFail("Even a same-URL navigation start must invalidate a pending invocation")
        } catch QuartzWebMCPError.pageChanged {}
        await load(in: webView)
        try await register(in: webView)
        do {
            try await bridge.validate(page, tool: tool, in: webView)
            XCTFail("Old documents must not execute")
        } catch QuartzWebMCPError.pageChanged {}
    }

    func testFacetSessionCanInvokeRealPageToolsAndFeedResultsBack() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        await load(in: webView)
        try await register(in: webView)
        let bridge = QuartzWebMCPBridge()
        let discovered = try await bridge.discover(in: webView)
        let page = try XCTUnwrap(discovered)
        var rounds = 0
        let reply = try await FacetToolSession.run(messages: [FacetChatMessage(role: "user", content: "Echo hello")], tools: page.definitions, requestTurn: { messages, tools in
            rounds += 1
            if rounds == 1 {
                return FacetAssistantTurn(content: "", toolCalls: [FacetToolCall(id: "call_1", name: tools[0].name, arguments: "{\"value\":\"hello\"}")])
            }
            XCTAssertEqual(messages.last?.role, "tool")
            XCTAssertEqual(try FacetJSONValue(jsonString: messages.last!.content), .object(["echo": .string("hello")]))
            return FacetAssistantTurn(content: "The page replied hello.")
        }, execute: { call, input in
            try await bridge.execute(try XCTUnwrap(page.tool(named: call.name)), input: input, page: page, in: webView)
        })
        XCTAssertEqual(reply, "The page replied hello.")
        XCTAssertEqual(rounds, 2)
    }

    func testRepositoryDemoExposesAndExecutesBothWebMCPAPIs() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let html = try String(contentsOf: root.appendingPathComponent("examples/webmcp/index.html"), encoding: .utf8)
        await load(html, in: webView, url: "http://127.0.0.1:8000/")
        let bridge = QuartzWebMCPBridge()
        let discovered = try await bridge.discover(in: webView)
        let page = try XCTUnwrap(discovered)
        XCTAssertEqual(Set(page.tools.map(\.name)), ["list_inventory", "search_inventory", "add_task"])
        let inventory = try XCTUnwrap(page.tools.first { $0.name == "list_inventory" })
        let listed = try await bridge.execute(inventory, input: .object([:]), page: page, in: webView)
        guard case .object(let list) = listed else { return XCTFail("Expected inventory object") }
        XCTAssertEqual(list["count"], .number(5))
        let search = try XCTUnwrap(page.tools.first { $0.name == "search_inventory" })
        let searched = try await bridge.execute(search, input: .object(["query": .string("paper")]), page: page, in: webView)
        guard case .object(let results) = searched else { return XCTFail("Expected search object") }
        XCTAssertEqual(results["count"], .number(2))
        let add = try XCTUnwrap(page.tools.first { $0.name == "add_task" })
        _ = try await bridge.execute(add, input: .object(["text": .string("Prepare a watercolor study")]), page: page, in: webView)
        let visible = try await webView.callAsyncJavaScript("return document.getElementById('tasks').innerText;", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertTrue((visible as? String)?.contains("Prepare a watercolor study") == true)
    }
}
