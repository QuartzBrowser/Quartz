import AppKit
import WebKit
import XCTest
@testable import Quartz

@MainActor
final class FacetPersonalizationTests: XCTestCase {
    private actor Generator {
        private(set) var requests: [[FacetChatMessage]] = []

        func run(_ messages: [FacetChatMessage]) -> String {
            requests.append(messages)
            let sparks = (1...6).map {
                FacetCuriositySpark(title: "Explore telescope idea \($0)", query: "beginner telescope project \($0)", category: "ASTRONOMY")
            }
            return String(decoding: try! JSONEncoder().encode(sparks), as: UTF8.self)
        }
    }

    func testFirstCompletedChatGeneratesAndRestartReusesDailyCache() async throws {
        let suite = "FacetPersonalizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let generator = Generator()
        let service = FacetCuriositySparkService(defaults: defaults) { messages, _, _ in
            await generator.run(messages)
        }
        var keyReads = 0
        let controller = FacetPersonalizationController(defaults: defaults, sparks: service, apiKey: {
            keyReads += 1
            return "test-key"
        })
        let observer = controller.observe {}
        defer { controller.removeObserver(observer) }
        XCTAssertEqual(keyReads, 0, "A new installation without chats should not read Keychain or generate")
        XCTAssertTrue(controller.status.contains("Chat with Facet"))
        controller.appendExchange(userPrompt: "I enjoy building beginner telescopes", assistantReply: "Try a simple reflector project.")
        try await waitUntil { service.sparks.count == 6 && !service.isGenerating }
        XCTAssertTrue(controller.status.contains("today"))
        let requests = await generator.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].last!.content.contains("building beginner telescopes"))

        controller.appendExchange(userPrompt: "I also enjoy observing Mars", assistantReply: "Track it on clear evenings.")
        controller.refresh()
        await Task.yield()
        let sameDayRequests = await generator.requests
        XCTAssertEqual(sameDayRequests.count, 1, "Later chats inform tomorrow's set without repeated daily charges")
        controller.stop()

        let restoredService = FacetCuriositySparkService(defaults: defaults) { messages, _, _ in
            await generator.run(messages)
        }
        let restored = FacetPersonalizationController(defaults: defaults, sparks: restoredService, apiKey: { "test-key" })
        defer { restored.stop() }
        XCTAssertEqual(restored.history.messages.count, 4)
        XCTAssertEqual(restoredService.sparks, service.sparks)
        restored.refresh()
        await Task.yield()
        let restoredRequests = await generator.requests
        XCTAssertEqual(restoredRequests.count, 1)
    }

    func testAddingKeyStartsPendingPersonalization() async throws {
        let suite = "FacetPersonalizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let generator = Generator()
        let service = FacetCuriositySparkService(defaults: defaults) { messages, _, _ in
            await generator.run(messages)
        }
        var key: String?
        let controller = FacetPersonalizationController(defaults: defaults, sparks: service, apiKey: { key })
        defer { controller.stop() }
        controller.appendExchange(userPrompt: "Tell me about telescope mirrors", assistantReply: "They gather light.")
        await Task.yield()
        XCTAssertTrue(service.sparks.isEmpty)
        XCTAssertTrue(controller.status.contains("Add an OpenRouter key"))
        key = "test-key"
        controller.settingsChanged()
        try await waitUntil { service.sparks.count == 6 }
        let requests = await generator.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testSharedBrowserWindowsRenderDailySparksAndClearSavedChats() async throws {
        _ = NSApplication.shared
        let suite = "FacetPersonalizationWindowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let generator = Generator()
        let service = FacetCuriositySparkService(defaults: defaults) { messages, _, _ in
            await generator.run(messages)
        }
        let personalization = FacetPersonalizationController(defaults: defaults, sparks: service, apiKey: { "test-key" })
        personalization.history.appendExchange(userPrompt: "Help me build a telescope", assistantReply: "Start with the optics.")
        let browser: BrowserController
        if #available(macOS 15.4, *) {
            let initial = BrowserController(sessionDefaults: defaults)
            let support = QuartzWebExtensionSupport(browser: initial, webViewConfiguration: WKWebViewConfiguration(), defaults: defaults)
            browser = BrowserController(sharedExtensionSupport: support, restoresSavedSession: false, focusesWindow: false, sessionDefaults: defaults, facetPersonalization: personalization)
        } else {
            browser = BrowserController(restoresSavedSession: false, focusesWindow: false, sessionDefaults: defaults, facetPersonalization: personalization)
        }
        browser.start()
        defer { browser.extensionWindow?.close() }
        try await waitUntil { service.sparks.count == 6 && browser.extensionURL == QuartzStartPage.url && browser.extensionWebView?.isLoading == false }
        let firstView = try XCTUnwrap(browser.extensionWebView)
        try await waitForSpark(in: firstView, expected: "Explore telescope idea 1")

        let second = browser.openBrowserWindow(focused: false)
        defer { second.extensionWindow?.close() }
        try await waitUntil { second.extensionURL == QuartzStartPage.url && second.extensionWebView?.isLoading == false }
        let secondView = try XCTUnwrap(second.extensionWebView)
        try await waitForSpark(in: secondView, expected: "Explore telescope idea 1")
        let requests = await generator.requests
        XCTAssertEqual(requests.count, 1)
        let link = try await firstView.callAsyncJavaScript("return document.getElementById('spark-link').href;", in: nil, contentWorld: .page) as? String
        XCTAssertEqual(QuartzStartPage.action(for: try XCTUnwrap(URL(string: try XCTUnwrap(link)))), .searchSpark("beginner telescope project 1"))

        let content = try XCTUnwrap(browser.extensionWindow?.contentView)
        let panel = try XCTUnwrap(descendants(of: content).compactMap { $0 as? FacetPanelView }.first)
        panel.appendUserMessage("A saved conversation")
        let clearButton = try XCTUnwrap(descendants(of: panel).compactMap { $0 as? NSButton }.first { $0.title == "Clear saved chats" })
        clearButton.performClick(nil)
        XCTAssertTrue(personalization.history.messages.isEmpty)
        XCTAssertTrue(service.sparks.isEmpty)
        XCTAssertTrue(FacetHistoryStore(defaults: defaults).messages.isEmpty)
        XCTAssertTrue(FacetCuriositySparkService(defaults: defaults).sparks.isEmpty)
        for view in [firstView, secondView] {
            try await waitForSpark(in: view, expected: "A universe hiding in a drop of water.")
            let status = try await view.callAsyncJavaScript("return document.getElementById('spark-status').textContent;", in: nil, contentWorld: .page) as? String
            XCTAssertTrue(try XCTUnwrap(status).contains("Chat with Facet"))
        }
        let transcript = try XCTUnwrap(descendants(of: panel).compactMap { $0 as? NSTextView }.first)
        XCTAssertTrue(transcript.string.isEmpty)
    }

    func testSparkQueriesAlwaysSearchEvenWhenTheyLookLikeURLsOrCode() throws {
        for query in ["example.com", "javascript:alert(1)", "file:///tmp/private", "https://example.org", "fox+owl & 雪 #1 / 50%"] {
            let url = try XCTUnwrap(BrowserController.curiositySparkSearchURL(query))
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "duckduckgo.com")
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "q", value: query)])
        }
        XCTAssertNil(BrowserController.curiositySparkSearchURL(" \n"))
        XCTAssertNil(BrowserController.curiositySparkSearchURL(String(repeating: "x", count: 241)))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func waitForSpark(in view: WKWebView, expected: String) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let title = try await view.callAsyncJavaScript("return document.getElementById('spark-title').textContent;", in: nil, contentWorld: .page) as? String
            if title == expected { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The home page did not render the expected spark")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() {
            guard Date() < deadline else { throw NSError(domain: "FacetPersonalizationTests.Timeout", code: 1) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
