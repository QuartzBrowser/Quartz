import AppKit
@preconcurrency import WebKit

/// Quartz exposes each independent browser window as a window containing one tab.
/// Keeping this identity separate from the shared extension controller preserves
/// tab IDs when a page navigates or switches to an extension's web view.
@available(macOS 15.4, *)
@MainActor
final class QuartzWebExtensionBrowserTab: NSObject, WKWebExtensionWindow, WKWebExtensionTab {
    private(set) weak var browser: BrowserController?
    private weak var support: QuartzWebExtensionSupport?
    private var observations = [NSKeyValueObservation]()

    init(browser: BrowserController, support: QuartzWebExtensionSupport) {
        self.browser = browser
        self.support = support
        super.init()
        observeWebView()
    }

    func observeWebView() {
        observations.removeAll()
        guard let webView = browser?.extensionWebView else { return }
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.changed([.URL]) }
            },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.changed([.title]) }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.changed([.loading]) }
            }
        ]
        changed([.URL, .title, .loading])
    }

    private func changed(_ properties: WKWebExtension.TabChangedProperties) {
        support?.tabDidChange(self, properties: properties)
    }

    func didClose() {
        observations.removeAll()
        browser = nil
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        browser == nil ? [] : [self]
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        browser == nil ? nil : self
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        browser == nil ? nil : self
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        browser == nil ? NSNotFound : 0
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        browser?.extensionWebView
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        browser?.extensionURL
    }

    func pendingURL(for context: WKWebExtensionContext) -> URL? {
        browser?.extensionPendingURL
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        browser != nil
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        browser?.extensionWindow?.frame ?? .null
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        browser?.extensionWindow?.screen?.frame ?? .null
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = browser?.extensionWindow else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        if window.isMiniaturized { return .minimized }
        if window.isZoomed { return .maximized }
        return .normal
    }

    func setWindowState(_ state: WKWebExtension.WindowState, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window = browser?.extensionWindow else {
            completionHandler(QuartzBrowserWindowError.noBrowserWindow)
            return
        }
        if state == .fullscreen {
            if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        } else {
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            if state == .minimized {
                window.miniaturize(nil)
            } else {
                if window.isMiniaturized { window.deminiaturize(nil) }
                if (state == .maximized) != window.isZoomed { window.zoom(nil) }
            }
        }
        completionHandler(nil)
    }

    func applyInitialFrame(_ requestedFrame: CGRect) {
        guard let window = browser?.extensionWindow else { return }
        var frame = window.frame
        if requestedFrame.origin.x.isFinite { frame.origin.x = requestedFrame.origin.x }
        if requestedFrame.origin.y.isFinite { frame.origin.y = requestedFrame.origin.y }
        if requestedFrame.width.isFinite { frame.size.width = max(window.minSize.width, requestedFrame.width) }
        if requestedFrame.height.isFinite { frame.size.height = max(window.minSize.height, requestedFrame.height) }
        window.setFrame(frame, display: true)
    }

    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard browser?.extensionWindow != nil else {
            completionHandler(QuartzBrowserWindowError.noBrowserWindow)
            return
        }
        applyInitialFrame(frame)
        completionHandler(nil)
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window = browser?.extensionWindow else {
            completionHandler(QuartzBrowserWindowError.noBrowserWindow)
            return
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        focus(for: context, completionHandler: completionHandler)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window = browser?.extensionWindow else {
            completionHandler(QuartzBrowserWindowError.noBrowserWindow)
            return
        }
        window.close()
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let browser, let support else {
            completionHandler(QuartzBrowserWindowError.noBrowserWindow)
            return
        }
        support.openURLFromExtension(url, context: context, in: browser)
        completionHandler(nil)
    }
}

enum QuartzBrowserWindowError: LocalizedError {
    case noBrowserWindow
    case privateWindowsUnsupported
    case multipleTabsUnsupported

    var errorDescription: String? {
        switch self {
        case .noBrowserWindow:
            "The browser window is no longer open."
        case .privateWindowsUnsupported:
            "Quartz does not support private windows."
        case .multipleTabsUnsupported:
            "Quartz displays one page per window. Open each URL in a separate window. Moving existing tabs between windows is not supported."
        }
    }
}
