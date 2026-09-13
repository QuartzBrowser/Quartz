import AppKit
import WebKit

/// An isolated packaged-engine check with an optional loopback HTTP fixture.
/// Neither mode restores a saved browser session or uses a persistent data store.
@MainActor
final class QuartzWebKitSmokeTest: NSObject, WKNavigationDelegate {
    private let fixtureURL: URL?
    private var window: NSWindow!
    private var webView: WKWebView!
    private var timeout: Timer?

    private init(fixtureURL: URL?) {
        self.fixtureURL = fixtureURL
        super.init()
    }

    static func run() -> Never {
        let arguments = CommandLine.arguments
        let urlArguments = arguments.indices.filter { arguments[$0].hasPrefix("--quartz-webkit-smoke-url") }
        var fixtureURL: URL?
        if let index = urlArguments.first {
            guard urlArguments.count == 1, arguments[index] == "--quartz-webkit-smoke-url",
                  arguments.indices.contains(index + 1),
                  let components = URLComponents(string: arguments[index + 1]),
                  components.scheme == "http", components.host == "127.0.0.1",
                  let port = components.port, (1...65535).contains(port),
                  components.user == nil, components.password == nil, components.fragment == nil,
                  let url = components.url else {
                finish("--quartz-webkit-smoke-url requires one http://127.0.0.1:<port>/ fixture URL")
            }
            fixtureURL = url
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let probe = QuartzWebKitSmokeTest(fixtureURL: fixtureURL)
        probe.start()
        withExtendedLifetime(probe) { application.run() }
        exit(EXIT_FAILURE)
    }

    private func start() {
        let configuration = WKWebViewConfiguration()
        QuartzWebKitRuntime.configureWritingTools(for: configuration)
        configuration.websiteDataStore = .nonPersistent()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                          styleMask: .borderless, backing: .buffered, defer: false)
        webView = WKWebView(frame: window.contentView!.bounds, configuration: configuration)
        webView.navigationDelegate = self
        window.contentView?.addSubview(webView)
        timeout = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { _ in
            MainActor.assumeIsolated { () -> Void in
                Self.finish("Timed out waiting for the bundled WebKit content process")
            }
        }
        if let fixtureURL {
            FileHandle.standardOutput.write(Data("Loading loopback HTTP fixture: \(fixtureURL.absoluteString)\n".utf8))
            webView.load(URLRequest(url: fixtureURL, cachePolicy: .reloadIgnoringLocalCacheData))
        } else {
            webView.loadHTMLString("<html><body><h1 id='probe'>Quartz engine</h1></body></html>", baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if let fixtureURL, navigationAction.request.url != fixtureURL {
            decisionHandler(.cancel)
            Self.finish("The network smoke attempted to leave its loopback fixture")
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if let fixtureURL {
            guard navigationResponse.response.url == fixtureURL,
                  (navigationResponse.response as? HTTPURLResponse)?.statusCode == 200 else {
                decisionHandler(.cancel)
                Self.finish("The loopback HTTP fixture did not return HTTP 200 at the requested URL")
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if fixtureURL != nil {
            webView.stopLoading()
            Self.finish("The loopback HTTP fixture unexpectedly redirected")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("""
        (() => {
            const heading = document.getElementById('probe');
            return heading !== null && heading.textContent === 'Quartz engine'
                && heading.getBoundingClientRect().width > 0
                && heading.getBoundingClientRect().height > 0
                && Array.from({length: 6}, (_, i) => i + 1).reduce((a, b) => a + b, 0) === 21;
        })()
        """) { value, error in
            MainActor.assumeIsolated { () -> Void in
                if let error { Self.finish(error.localizedDescription) }
                Self.finish((value as? Bool) == true ? nil : "HTML layout or JavaScript check failed")
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Self.finish(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Self.finish(error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Self.finish("WebKit content process terminated")
    }

    private static func finish(_ error: String?) -> Never {
        var failure = error
        if failure == nil {
            let engine = QuartzWebKitRuntime.currentReport()
            if !engine.valid {
                failure = engine.error ?? "Unexpected engine images after rendering"
            } else {
                let images = engine.loadedEngineImages.joined(separator: "\n")
                FileHandle.standardOutput.write(Data("Loaded engine images:\n\(images)\n".utf8))
            }
        }
        let output = failure.map { "WebKit smoke test failed: \($0)\n" }
            ?? "WebKit smoke test passed: content process, HTML layout and JavaScript.\n"
        (failure == nil ? FileHandle.standardOutput : FileHandle.standardError).write(Data(output.utf8))
        exit(failure == nil ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}
