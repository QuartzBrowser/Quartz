import AppKit
import WebKit
import XCTest
@testable import Quartz

/// Exercise the actual custom-scheme response and the script permitted by its CSP.
@MainActor
final class QuartzHomePageWebKitTests: XCTestCase, WKNavigationDelegate {
    private var navigationFinished: XCTestExpectation?
    private var actionReceived: XCTestExpectation?
    private var capturedAction: QuartzStartPageAction?

    private func makeWebView(width: CGFloat = 1_000) -> (NSWindow, WKWebView) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(QuartzStartPageSchemeHandler(), forURLScheme: QuartzStartPage.scheme)
        let webView = WKWebView(frame: window.contentView!.bounds, configuration: configuration)
        window.contentView = webView
        webView.navigationDelegate = self
        return (window, webView)
    }

    private func loadHome(in webView: WKWebView) async {
        let loaded = expectation(description: "Load quartz://home through the real scheme handler")
        navigationFinished = loaded
        webView.load(URLRequest(url: QuartzStartPage.url))
        await fulfillment(of: [loaded], timeout: 15)
        navigationFinished = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationFinished?.fulfill()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        XCTFail("Home page failed to load: \(error)")
        navigationFinished?.fulfill()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, QuartzStartPage.isActionURL(url) else {
            decisionHandler(.allow)
            return
        }
        capturedAction = QuartzStartPage.authorizedAction(
            for: url,
            sourcePageURL: navigationAction.sourceFrame.request.url,
            sourceIsMainFrame: navigationAction.sourceFrame.isMainFrame
        )
        decisionHandler(.cancel)
        actionReceived?.fulfill()
    }

    private func evaluate<T: Decodable & Sendable>(_ script: String, in webView: WKWebView, as type: T.Type = T.self) async throws -> T {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error { continuation.resume(throwing: error); return }
                do {
                    let data = try JSONSerialization.data(withJSONObject: result ?? NSNull(), options: .fragmentsAllowed)
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func nativeAction(
        from script: String,
        arguments: [String: Any] = [:],
        in webView: WKWebView
    ) async throws -> QuartzStartPageAction? {
        capturedAction = nil
        let received = expectation(description: "Receive the native home page action")
        actionReceived = received
        defer { actionReceived = nil }
        _ = try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
        await fulfillment(of: [received], timeout: 5)
        return capturedAction
    }

    @discardableResult
    private func updateSparks(
        _ sparks: [[String: String]],
        status: String,
        in webView: WKWebView
    ) async throws -> Bool {
        let result = try await webView.callAsyncJavaScript(
            QuartzStartPage.updateCuriositySparksScript,
            arguments: ["sparks": sparks, "status": status],
            in: nil,
            contentWorld: .page
        )
        return try XCTUnwrap(result as? Bool)
    }

    func testHomeLoadsWithWorkingMoodAndCuriosityControls() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        await loadHome(in: webView)
        XCTAssertEqual(webView.url, QuartzStartPage.url)
        let title: String = try await evaluate("document.title", in: webView)
        XCTAssertEqual(title, "Home — Quartz")
        let initialMood: String = try await evaluate("document.body.dataset.mood", in: webView)
        XCTAssertEqual(initialMood, "daydream")

        for mood in ["orbit", "golden", "daydream"] {
            let state: [String] = try await evaluate("""
            (() => {
                document.querySelector('.mood[data-mood="\(mood)"]').click();
                const selected = [...document.querySelectorAll('.mood[aria-pressed="true"]')];
                return [document.body.dataset.mood, ...selected.map(button => button.dataset.mood)];
            })()
            """, in: webView)
            XCTAssertEqual(state, [mood, mood], "Mood buttons must update both the theme and accessible selection")
        }

        let originalSpark: String = try await evaluate("document.querySelector('#spark-title').textContent", in: webView)
        let nextSpark: [String] = try await evaluate("""
        (() => {
            document.querySelector('#shuffle-spark').click();
            return [document.querySelector('#spark-title').textContent, document.querySelector('#spark-link').href];
        })()
        """, in: webView)
        XCTAssertFalse(nextSpark[0].isEmpty)
        XCTAssertNotEqual(nextSpark[0], originalSpark)
        let sparkURL = try XCTUnwrap(URL(string: nextSpark[1]))
        guard case .navigate(let query) = QuartzStartPage.action(for: sparkURL) else {
            return XCTFail("A curiosity spark must link to a real browser search")
        }
        XCTAssertFalse(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testSearchAndNativeShortcutsArriveFromTheAuthorizedHomeFrame() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        await loadHome(in: webView)
        let query = "fox+owl & 雪 #1 / 50%"
        let search = try await nativeAction(from: """
        document.querySelector('#search-input').value = query;
        document.querySelector('#home-search').requestSubmit();
        return true;
        """, arguments: ["query": query], in: webView)
        XCTAssertEqual(search, .navigate(query))

        let facet = try await nativeAction(from: "document.querySelector('a[href=\"quartz-action://facet\"]').click(); return true;", in: webView)
        XCTAssertEqual(facet, .showFacet)
        let extensions = try await nativeAction(from: "document.querySelector('a[href=\"quartz-action://extensions\"]').click(); return true;", in: webView)
        XCTAssertEqual(extensions, .showExtensions)
        XCTAssertEqual(webView.url, QuartzStartPage.url)
    }

    func testGeneratedSparksRenderAsTextAndUseOnlyTheSearchAction() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        await loadHome(in: webView)
        let hostileTitle = #"<img src=x onerror="document.body.dataset.sparkInjected='yes'">"#
        let hostileCategory = "</span><script>window.sparkInjected = true</script>"
        let hostileStatus = "<svg onload=alert(1)>Personalized today</svg>"
        let query = "javascript:alert('hello') & fox+owl / 雪 #1 50%"
        let updated = try await updateSparks([
            ["title": hostileTitle, "query": query, "category": hostileCategory]
        ], status: hostileStatus, in: webView)
        XCTAssertTrue(updated)
        let displayed: [String] = try await evaluate("""
        ['spark-title', 'spark-category', 'spark-status'].map(id => document.getElementById(id).textContent)
        """, in: webView)
        XCTAssertEqual(displayed, [hostileTitle, hostileCategory, hostileStatus])
        let childCounts: [Int] = try await evaluate("""
        ['spark-title', 'spark-category', 'spark-status'].map(id => document.getElementById(id).childElementCount)
        """, in: webView)
        XCTAssertEqual(childCounts, [0, 0, 0], "Generated content must never be parsed as HTML")
        let action = try await nativeAction(from: "document.getElementById('spark-link').click(); return true;", in: webView)
        XCTAssertEqual(action, .searchSpark(query), "Even a URL-like model query must be sent only to search")
        XCTAssertEqual(webView.url, QuartzStartPage.url)
        let shuffleDisabled: Bool = try await evaluate("document.getElementById('shuffle-spark').disabled", in: webView)
        XCTAssertTrue(shuffleDisabled)
    }

    func testGeneratedSparksShufflePreserveSelectionOnRefreshAndReturnToFallback() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        await loadHome(in: webView)
        let sparks = [
            ["title": "Build a pocket observatory.", "query": "DIY portable telescope", "category": "YOUR NIGHT SKY"],
            ["title": "Turn a hike into a field journal.", "query": "nature field journal techniques", "category": "YOUR NEXT WALK"],
            ["title": "Sketch with an algorithm.", "query": "creative coding generative line art", "category": "YOUR CREATIVE SIDE"]
        ]
        try await updateSparks(sparks, status: "Personalized today by Facet.", in: webView)
        let initialTitle: String = try await evaluate("document.getElementById('spark-title').textContent", in: webView)
        XCTAssertEqual(initialTitle, sparks[0]["title"])
        let shuffled: [String] = try await evaluate("""
        (() => {
            document.getElementById('shuffle-spark').click();
            return [document.getElementById('spark-title').textContent, document.getElementById('spark-link').href];
        })()
        """, in: webView)
        XCTAssertNotEqual(shuffled[0], initialTitle)
        let selected = try XCTUnwrap(sparks.first { $0["title"] == shuffled[0] })
        XCTAssertEqual(QuartzStartPage.action(for: try XCTUnwrap(URL(string: shuffled[1]))), .searchSpark(selected["query"]!))

        try await updateSparks(sparks, status: "Refreshing your daily sparks…", in: webView)
        let refreshed: [String] = try await evaluate("""
        [document.getElementById('spark-title').textContent, document.getElementById('spark-status').textContent]
        """, in: webView)
        XCTAssertEqual(refreshed, [shuffled[0], "Refreshing your daily sparks…"])

        try await updateSparks([
            ["title": "Tomorrow's new idea.", "query": "fresh curiosity", "category": "NEW DAY"]
        ], status: "Personalized today by Facet.", in: webView)
        let replacement: String = try await evaluate("document.getElementById('spark-title').textContent", in: webView)
        XCTAssertEqual(replacement, "Tomorrow's new idea.")

        try await updateSparks([], status: "Chat with Facet to personalize your daily sparks.", in: webView)
        let fallback: [String] = try await evaluate("""
        [document.getElementById('spark-title').textContent, document.getElementById('spark-link').href]
        """, in: webView)
        guard case .navigate(let query) = QuartzStartPage.action(for: try XCTUnwrap(URL(string: fallback[1]))) else {
            return XCTFail("Clearing generated sparks must restore the offline fallback")
        }
        XCTAssertFalse(query.isEmpty)
        let nextFallback: String = try await evaluate("""
        (() => {
            document.getElementById('shuffle-spark').click();
            return document.getElementById('spark-title').textContent;
        })()
        """, in: webView)
        XCTAssertNotEqual(nextFallback, fallback[0])
    }

    func testSparkUpdatesDoNotRunAfterNavigatingAwayFromHome() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        await loadHome(in: webView)
        let loaded = expectation(description: "Leave the Quartz home document")
        navigationFinished = loaded
        webView.loadHTMLString("<!doctype html><title>Other page</title><body></body>", baseURL: URL(string: "https://example.org"))
        await fulfillment(of: [loaded], timeout: 15)
        navigationFinished = nil
        XCTAssertFalse(QuartzStartPage.isStartPageURL(webView.url))
        let installed: Bool = try await evaluate("""
        (() => {
            window.quartzUpdateCuriositySparks = () => { document.body.dataset.sparkUpdated = 'yes'; };
            String.prototype.toLowerCase = () => 'quartz:';
            Array.prototype.includes = () => true;
            return true;
        })()
        """, in: webView)
        XCTAssertTrue(installed)
        let updated = try await updateSparks([
            ["title": "A private interest", "query": "a private search", "category": "FOR YOU"]
        ], status: "Personalized today.", in: webView)
        XCTAssertFalse(updated)
        let invoked: Bool = try await evaluate("document.body.dataset.sparkUpdated === 'yes'", in: webView)
        XCTAssertFalse(invoked, "A late generation result must not call into another website, even when it overrides built-ins")
    }

    func testContentSecurityPolicyRejectsUntrustedInlineScripts() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        await loadHome(in: webView)
        let executed: Bool = try await evaluate("""
        (() => {
            const script = document.createElement('script');
            script.textContent = 'document.body.dataset.untrustedScript = "executed"';
            document.body.append(script);
            return document.body.dataset.untrustedScript === 'executed';
        })()
        """, in: webView)
        XCTAssertFalse(executed, "The home page must execute only its explicitly hashed script")
    }

    func testHomeFitsANarrowWindowWithoutHorizontalScrolling() async throws {
        let (window, webView) = makeWebView(width: 420)
        defer { window.close() }
        await loadHome(in: webView)
        let widths: [Double] = try await evaluate("[document.documentElement.scrollWidth, window.innerWidth]", in: webView)
        XCTAssertLessThanOrEqual(widths[0], widths[1] + 1)
    }

}
