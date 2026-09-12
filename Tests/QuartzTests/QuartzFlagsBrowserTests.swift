import AppKit
import Network
import WebKit
import XCTest
@testable import Quartz

@MainActor
final class QuartzFlagsBrowserTests: XCTestCase {
    func testPageControlPersistsAcrossReloadAndSynchronizesBrowserWindows() async throws {
        let harness = try await makeBrowser()
        defer { harness.finish() }
        let browser = harness.browser
        browser.loadFromExtension(QuartzFlagsPage.url)
        let webView = try XCTUnwrap(browser.extensionWebView)
        try await waitForFlag("disabled", in: webView)
        XCTAssertEqual(browser.extensionURL, QuartzFlagsPage.url)
        XCTAssertFalse(try pageToolsCheckbox(in: browser).isEnabled)
        try await saveScreenshotsIfRequested(of: webView, in: browser)

        try await selectFlag("enabled", in: webView)
        try await waitUntil { harness.flags.isWebMCPEnabled }
        try await waitForFlag("enabled", in: webView)
        XCTAssertTrue(try pageToolsCheckbox(in: browser).isEnabled)
        XCTAssertTrue(QuartzFeatureFlags(defaults: harness.defaults).isWebMCPEnabled)
        try await reload(webView)
        try await waitForFlag("enabled", in: webView)

        let second = browser.openBrowserWindow(focused: false, initialURL: QuartzFlagsPage.url) {
            $0.loadFromExtension(QuartzFlagsPage.url)
        }
        defer { second.extensionWindow?.close() }
        let secondWebView = try XCTUnwrap(second.extensionWebView)
        try await waitForFlag("enabled", in: secondWebView)
        let secondCheckbox = try pageToolsCheckbox(in: second)
        XCTAssertTrue(secondCheckbox.isEnabled)
        secondCheckbox.state = .on

        try await selectFlag("disabled", in: webView)
        try await waitUntil { !harness.flags.isWebMCPEnabled }
        try await waitForFlag("disabled", in: webView)
        try await waitForFlag("disabled", in: secondWebView)
        XCTAssertFalse(try pageToolsCheckbox(in: browser).isEnabled)
        XCTAssertFalse(secondCheckbox.isEnabled)
        XCTAssertEqual(secondCheckbox.state, .off)
        XCTAssertFalse(QuartzFeatureFlags(defaults: harness.defaults).isWebMCPEnabled)
    }

    func testWebMCPIsAbsentByDefaultAndInjectionChangesAfterWebsiteReload() async throws {
        let harness = try await makeBrowser()
        defer { harness.finish() }
        let server = try FlagsHTTPServer()
        let websiteURL = try await server.start()
        defer { server.stop() }
        let website = harness.browser
        let websiteView = try XCTUnwrap(website.extensionWebView)
        website.loadFromExtension(websiteURL)
        try await waitUntil { websiteView.url == websiteURL && !websiteView.isLoading }
        try await assertBridge("undefined", in: websiteView)
        let checkbox = try pageToolsCheckbox(in: website)
        XCTAssertFalse(checkbox.isEnabled)
        XCTAssertEqual(checkbox.state, .off)

        let settings = website.openBrowserWindow(focused: false, initialURL: QuartzFlagsPage.url) {
            $0.loadFromExtension(QuartzFlagsPage.url)
        }
        defer { settings.extensionWindow?.close() }
        let settingsView = try XCTUnwrap(settings.extensionWebView)
        try await waitForFlag("disabled", in: settingsView)
        try await selectFlag("enabled", in: settingsView)
        try await waitUntil { checkbox.isEnabled }
        try await waitForFlag("enabled", in: settingsView)
        try await assertBridge("undefined", in: websiteView)
        try await reload(websiteView)
        try await assertBridge("object", in: websiteView)

        checkbox.state = .on
        try await selectFlag("disabled", in: settingsView)
        try await waitUntil { !checkbox.isEnabled }
        XCTAssertEqual(checkbox.state, .off)
        try await reload(websiteView)
        try await assertBridge("undefined", in: websiteView)
    }

    func testWebsiteAndSubframeActionsCannotChangeNativeFlags() async throws {
        let harness = try await makeBrowser()
        defer { harness.finish() }
        let webView = try XCTUnwrap(harness.browser.extensionWebView)
        webView.loadHTMLString("<html><title>Untrusted website</title><body></body></html>",
                               baseURL: URL(string: "https://example.org/"))
        try await waitUntil { webView.title == "Untrusted website" && !webView.isLoading }
        let recorder = FlagsActionRecorder(browser: harness.browser)
        webView.navigationDelegate = recorder
        defer { webView.navigationDelegate = harness.browser }

        _ = try await webView.callAsyncJavaScript("""
        const link = document.createElement('a');
        link.href = 'quartz-action://flags?webmcp=enabled';
        document.body.append(link);
        link.click();
        return true;
        """, in: nil, contentWorld: .page)
        try await waitUntil { recorder.actions.count == 1 }
        XCTAssertTrue(recorder.actions[0].isMainFrame)
        XCTAssertEqual(recorder.actions[0].policy, .cancel)
        XCTAssertFalse(harness.flags.isWebMCPEnabled)

        _ = try await webView.callAsyncJavaScript("""
        const frame = document.createElement('iframe');
        frame.srcdoc = `<body><a id="attack" href="quartz-action://flags?webmcp=enabled">Enable</a><script>document.getElementById('attack').click();</script>`;
        document.body.append(frame);
        return true;
        """, in: nil, contentWorld: .page)
        try await waitUntil { recorder.actions.count == 2 }
        XCTAssertFalse(recorder.actions[1].isMainFrame)
        XCTAssertEqual(recorder.actions[1].policy, .cancel)
        XCTAssertFalse(harness.flags.isWebMCPEnabled)
        XCTAssertEqual(webView.title, "Untrusted website")
    }

    func testReturningToFlagsFromHistoryShowsTheSavedSetting() async throws {
        let harness = try await makeBrowser()
        defer { harness.finish() }
        let server = try FlagsHTTPServer()
        let websiteURL = try await server.start()
        defer { server.stop() }
        let webView = try XCTUnwrap(harness.browser.extensionWebView)
        harness.browser.loadFromExtension(QuartzFlagsPage.url)
        try await waitForFlag("disabled", in: webView)
        harness.browser.loadFromExtension(websiteURL)
        try await waitUntil { webView.url == websiteURL && !webView.isLoading }

        harness.flags.setWebMCPEnabled(true)
        XCTAssertTrue(webView.canGoBack)
        webView.goBack()

        try await waitForFlag("enabled", in: webView)
        XCTAssertTrue(try pageToolsCheckbox(in: harness.browser).isEnabled)
        XCTAssertTrue(harness.flags.isWebMCPEnabled)
    }

    private func makeBrowser() async throws -> Harness {
        _ = NSApplication.shared
        let suite = "QuartzFlagsBrowserTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let personalization = FacetPersonalizationController(defaults: defaults, apiKey: { nil })
        let browser: BrowserController
        if #available(macOS 15.4, *) {
            let initial = BrowserController(sessionDefaults: defaults, facetPersonalization: personalization)
            let support = QuartzWebExtensionSupport(browser: initial, webViewConfiguration: WKWebViewConfiguration(), defaults: defaults)
            browser = BrowserController(sharedExtensionSupport: support, restoresSavedSession: false, focusesWindow: false,
                                        sessionDefaults: defaults, facetPersonalization: personalization)
        } else {
            browser = BrowserController(restoresSavedSession: false, focusesWindow: false,
                                        sessionDefaults: defaults, facetPersonalization: personalization)
        }
        let harness = Harness(browser: browser, personalization: personalization, defaults: defaults, suite: suite)
        browser.start()
        do {
            try await waitUntil { browser.extensionURL == QuartzStartPage.url && browser.extensionWebView?.isLoading == false }
            return harness
        } catch {
            harness.finish()
            throw error
        }
    }

    private func selectFlag(_ value: String, in webView: WKWebView) async throws {
        _ = try await webView.callAsyncJavaScript("""
        const control = document.getElementById('webmcp');
        control.value = value;
        control.dispatchEvent(new Event('change', {bubbles: true}));
        return true;
        """, arguments: ["value": value], in: nil, contentWorld: .page)
    }

    private func waitForFlag(_ value: String, in webView: WKWebView) async throws {
        try await waitUntil {
            guard QuartzFlagsPage.isFlagsPageURL(webView.url), !webView.isLoading else { return false }
            let actual = try? await webView.callAsyncJavaScript("""
            return document.getElementById('webmcp')?.value === value
                && document.querySelector('[role="status"]')?.textContent === status;
            """, arguments: ["value": value, "status": "Current setting: \(value == "enabled" ? "Enabled" : "Disabled")"],
                in: nil, contentWorld: .page)
            return actual as? Bool == true
        }
    }

    private func reload(_ webView: WKWebView) async throws {
        _ = try await webView.callAsyncJavaScript("window.__flagsTestBeforeReload = true; return true;", in: nil, contentWorld: .page)
        webView.reload()
        try await waitUntil {
            guard !webView.isLoading else { return false }
            let fresh = try? await webView.callAsyncJavaScript(
                "return typeof window.__flagsTestBeforeReload === 'undefined';", in: nil, contentWorld: .page)
            return fresh as? Bool == true
        }
    }

    private func assertBridge(_ expected: String, in webView: WKWebView) async throws {
        let actual = try await webView.callAsyncJavaScript("return typeof window.__quartzWebMCP;", in: nil, contentWorld: .page)
        XCTAssertEqual(actual as? String, expected)
    }

    private func pageToolsCheckbox(in browser: BrowserController) throws -> NSButton {
        let content = try XCTUnwrap(browser.extensionWindow?.contentView)
        return try XCTUnwrap(descendants(of: content).compactMap { $0 as? NSButton }.first { $0.title == "Page tools (WebMCP)" })
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !(await condition()) {
            guard Date() < deadline else { throw NSError(domain: "QuartzFlagsBrowserTests.Timeout", code: 1) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func saveScreenshotsIfRequested(of webView: WKWebView, in browser: BrowserController) async throws {
        guard let path = ProcessInfo.processInfo.environment["QUARTZ_FLAGS_SCREENSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            browser.extensionWindow?.appearance = NSAppearance(named: appearance)
            try await waitUntil {
                let dark = try? await webView.callAsyncJavaScript("return matchMedia('(prefers-color-scheme: dark)').matches;", in: nil, contentWorld: .page)
                return dark as? Bool == (name == "dark")
            }
            let snapshot = try await webView.takeSnapshot(configuration: nil)
            let bitmap = try XCTUnwrap(snapshot.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("quartz-flags-\(name).png"))
        }
        browser.extensionWindow?.appearance = nil
    }

    @MainActor
    private struct Harness {
        let browser: BrowserController
        let personalization: FacetPersonalizationController
        let defaults: UserDefaults
        let suite: String
        var flags: QuartzFeatureFlags { QuartzFeatureFlags(defaults: defaults) }

        func finish() {
            browser.extensionWindow?.close()
            personalization.stop()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

@MainActor
private final class FlagsActionRecorder: NSObject, WKNavigationDelegate {
    let browser: BrowserController
    var actions: [(isMainFrame: Bool, policy: WKNavigationActionPolicy)] = []

    init(browser: BrowserController) { self.browser = browser }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        browser.webView(webView, decidePolicyFor: navigationAction) { policy in
            if navigationAction.request.url?.scheme == "quartz-action" {
                self.actions.append((navigationAction.sourceFrame.isMainFrame, policy))
            }
            decisionHandler(policy)
        }
    }
}

/// A local HTTP page supports real reloads without reaching an external website.
private final class FlagsHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "QuartzFlagsBrowserTests.HTTP")

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: DispatchQueue.global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { _, _, _, _ in
                let body = "<html><title>Flags website fixture</title><body>WebMCP reload fixture</body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    func start() async throws -> URL {
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return URL(string: "http://127.0.0.1:\(port)/")!
    }

    func stop() { listener.cancel() }
}
