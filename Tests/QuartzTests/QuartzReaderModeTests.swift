import AppKit
import WebKit
import XCTest
@testable import Quartz

@MainActor
final class QuartzReaderModeTests: XCTestCase, WKNavigationDelegate {
    private struct ReaderResult: Decodable, Sendable {
        let ok: Bool
        let reason: String?
        let alreadyActive: Bool?
    }

    private var navigationFinished: XCTestExpectation?

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures/Reader"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func makeWebView() -> (NSWindow, WKWebView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let webView = WKWebView(frame: window.contentView!.bounds)
        window.contentView = webView
        webView.navigationDelegate = self
        return (window, webView)
    }

    private func load(_ html: String, in webView: WKWebView) async {
        let expectation = expectation(description: "Load article in WebKit")
        navigationFinished = expectation
        webView.loadHTMLString(html, baseURL: URL(string: "https://fixture.example/articles/notes"))
        await fulfillment(of: [expectation], timeout: 15)
        navigationFinished = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationFinished?.fulfill()
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

    func testArticleTextHeadingsAndBylineSurviveExtractionAndExitRestoresPage() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        await load(try fixture("article"), in: webView)
        let original: String = try await evaluate("document.body.innerHTML", in: webView)
        let result: ReaderResult = try await evaluate(QuartzReaderMode.enterScript, in: webView)
        XCTAssertEqual(result.ok, true)
        let text: String = try await evaluate("document.querySelector('#quartz-reading-mode').shadowRoot.textContent", in: webView)
        XCTAssertTrue(text.contains("The morning crossing"))
        XCTAssertTrue(text.contains("Their notes document years of repairs"))
        XCTAssertTrue(text.contains("Alex River"))
        let second: ReaderResult = try await evaluate(QuartzReaderMode.enterScript, in: webView)
        XCTAssertEqual(second.alreadyActive, true)
        let _: ReaderResult = try await evaluate(QuartzReaderMode.exitScript, in: webView)
        let restored: String = try await evaluate("document.body.innerHTML", in: webView)
        XCTAssertEqual(restored, original)
        let overflow: String = try await evaluate("document.body.style.overflow", in: webView)
        XCTAssertEqual(overflow, "auto")
        let background: String = try await evaluate("document.body.style.background", in: webView)
        XCTAssertEqual(background, "rgb(240, 240, 240)")
    }

    func testImagesCaptionsAndRelativeLinksArePreserved() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        await load(try fixture("images"), in: webView)
        let result: ReaderResult = try await evaluate(QuartzReaderMode.enterScript, in: webView)
        XCTAssertEqual(result.ok, true)
        let values: [String] = try await evaluate("""
        (() => {
            const root = document.querySelector('#quartz-reading-mode').shadowRoot;
            return [root.querySelector('img').src, root.querySelector('img').alt,
                    root.querySelector('figcaption').textContent, root.querySelector('a').href];
        })()
        """, in: webView)
        XCTAssertEqual(values, ["https://fixture.example/harbor.svg", "The harbor at dawn", "A quiet morning at the harbor", "https://fixture.example/trail"])
    }

    func testNavigationSidebarsCommentsAdsAndFormsAreRemoved() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        await load(try fixture("clutter"), in: webView)
        let result: ReaderResult = try await evaluate(QuartzReaderMode.enterScript, in: webView)
        XCTAssertEqual(result.ok, true)
        let html: String = try await evaluate("document.querySelector('#quartz-reading-mode').shadowRoot.querySelector('.content').innerHTML", in: webView)
        XCTAssertTrue(html.contains("The morning ferry crosses the bay"))
        for junk in ["NAVIGATION_JUNK", "SIDEBAR_JUNK", "COMMENTS_JUNK", "NEWSLETTER_JUNK", "ADVERT_JUNK", "FOOTER_JUNK", "<script", "<input"] {
            XCTAssertFalse(html.contains(junk), "Reader retained \(junk)")
        }
    }

    func testShortPageIsRejectedWithoutChangingIt() async throws {
        let (window, webView) = makeWebView()
        defer { window.close() }
        await load(try fixture("short"), in: webView)
        let original: String = try await evaluate("document.body.outerHTML", in: webView)
        let result: ReaderResult = try await evaluate(QuartzReaderMode.enterScript, in: webView)
        XCTAssertEqual(result.ok, false)
        XCTAssertEqual(result.reason, "tooShort")
        let after: String = try await evaluate("document.body.outerHTML", in: webView)
        XCTAssertEqual(after, original)
    }
}
