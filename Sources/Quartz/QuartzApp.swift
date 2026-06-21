import AppKit
import WebKit

@main
struct QuartzApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = BrowserController()

        app.delegate = delegate
        app.setActivationPolicy(.regular)
        delegate.start()
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

@MainActor
final class BrowserController: NSObject, NSApplicationDelegate, WKNavigationDelegate, NSTextFieldDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var webExtensionSupport: AnyObject?
    private var didStart = false

    private let addressField = NSTextField()
    private let backButton = BrowserController.makeIconButton(symbolName: "chevron.left", description: "Back")
    private let forwardButton = BrowserController.makeIconButton(symbolName: "chevron.right", description: "Forward")
    private let reloadButton = BrowserController.makeIconButton(symbolName: "arrow.clockwise", description: "Reload")
    private let stopButton = BrowserController.makeIconButton(symbolName: "xmark", description: "Stop")
    private let homeButton = BrowserController.makeIconButton(symbolName: "house", description: "Home")
    private let extensionsButton = BrowserController.makeIconButton(symbolName: "puzzlepiece.extension", description: "Extensions")

    private let homeURL = URL(string: "https://www.example.com")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        start()
    }

    func start() {
        guard didStart == false else {
            return
        }

        didStart = true

        buildMenu()
        buildWindow()
        loadSavedExtensionsThenLoadHome()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildWindow() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController = WKUserContentController()

        if #available(macOS 15.4, *) {
            let support = QuartzWebExtensionSupport(browser: self, webViewConfiguration: configuration)
            configuration.webExtensionController = support.controller
            webExtensionSupport = support
        }

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        addressField.placeholderString = "Search or enter website name"
        addressField.target = self
        addressField.action = #selector(addressSubmitted(_:))
        addressField.lineBreakMode = .byTruncatingMiddle
        addressField.font = .systemFont(ofSize: 14)
        addressField.translatesAutoresizingMaskIntoConstraints = false
        addressField.focusRingType = .default

        let goButton = NSButton(title: "Go", target: self, action: #selector(addressSubmitted(_:)))
        goButton.bezelStyle = .rounded
        goButton.controlSize = .regular

        configure(button: backButton, action: #selector(goBack(_:)))
        configure(button: forwardButton, action: #selector(goForward(_:)))
        configure(button: reloadButton, action: #selector(reload(_:)))
        configure(button: stopButton, action: #selector(stopLoading(_:)))
        configure(button: homeButton, action: #selector(goHome(_:)))
        configure(button: extensionsButton, action: #selector(showExtensionStatus(_:)))
        updateExtensionsButton()

        let toolbar = NSStackView(views: [
            backButton,
            forwardButton,
            reloadButton,
            stopButton,
            homeButton,
            extensionsButton,
            addressField,
            goButton
        ])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolbar)
        container.addSubview(webView)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),

            addressField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),

            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Quartz"
        window.center()
        window.minSize = NSSize(width: 520, height: 360)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)

        updateControls()
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Quartz", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")

        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let navigationMenuItem = NSMenuItem()
        let navigationMenu = NSMenu(title: "Navigate")

        let backItem = NSMenuItem(title: "Back", action: #selector(goBack(_:)), keyEquivalent: "[")
        backItem.target = self
        navigationMenu.addItem(backItem)

        let forwardItem = NSMenuItem(title: "Forward", action: #selector(goForward(_:)), keyEquivalent: "]")
        forwardItem.target = self
        navigationMenu.addItem(forwardItem)

        let reloadItem = NSMenuItem(title: "Reload", action: #selector(reload(_:)), keyEquivalent: "r")
        reloadItem.target = self
        navigationMenu.addItem(reloadItem)

        let homeItem = NSMenuItem(title: "Home", action: #selector(goHome(_:)), keyEquivalent: "h")
        homeItem.target = self
        navigationMenu.addItem(homeItem)

        navigationMenuItem.submenu = navigationMenu
        mainMenu.addItem(navigationMenuItem)

        let extensionsMenuItem = NSMenuItem()
        let extensionsMenu = NSMenu(title: "Extensions")

        let installExtensionItem = NSMenuItem(title: "Install Extension...", action: #selector(installExtension(_:)), keyEquivalent: "e")
        installExtensionItem.target = self
        extensionsMenu.addItem(installExtensionItem)

        let extensionStatusItem = NSMenuItem(title: "Extension Status", action: #selector(showExtensionStatus(_:)), keyEquivalent: "")
        extensionStatusItem.target = self
        extensionsMenu.addItem(extensionStatusItem)

        extensionsMenuItem.submenu = extensionsMenu
        mainMenu.addItem(extensionsMenuItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    private static func makeIconButton(symbolName: String, description: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.bezelStyle = .texturedRounded
        button.controlSize = .regular
        button.imagePosition = .imageOnly
        button.toolTip = description
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        return button
    }

    private func configure(button: NSButton, action: Selector) {
        button.target = self
        button.action = action
    }

    @objc private func addressSubmitted(_ sender: Any?) {
        guard let url = normalizedURL(from: addressField.stringValue) else {
            return
        }

        load(url)
    }

    @objc private func goBack(_ sender: Any?) {
        if webView.canGoBack {
            webView.goBack()
        }
        updateControls()
    }

    @objc private func goForward(_ sender: Any?) {
        if webView.canGoForward {
            webView.goForward()
        }
        updateControls()
    }

    @objc private func reload(_ sender: Any?) {
        webView.reload()
        updateControls()
    }

    @objc private func stopLoading(_ sender: Any?) {
        webView.stopLoading()
        updateControls()
    }

    @objc private func goHome(_ sender: Any?) {
        load(homeURL)
    }

    @objc private func installExtension(_ sender: Any?) {
        guard #available(macOS 15.4, *), let support = webExtensionSupport as? QuartzWebExtensionSupport else {
            showExtensionsUnavailableAlert()
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Install Quartz Extension"
        panel.message = "Choose a WebExtension directory or ZIP archive."
        panel.prompt = "Install"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        support.installExtension(from: url) { [weak self] result in
            guard let self else {
                return
            }

            self.updateExtensionsButton()

            switch result {
            case .success(let summary):
                self.showExtensionAlert(title: "Extension Installed", message: summary)
            case .failure(let error):
                self.showExtensionAlert(title: "Extension Could Not Be Installed", message: error.localizedDescription)
            }
        }
    }

    @objc private func showExtensionStatus(_ sender: Any?) {
        guard #available(macOS 15.4, *), let support = webExtensionSupport as? QuartzWebExtensionSupport else {
            showExtensionsUnavailableAlert()
            return
        }

        let installedExtensions = support.installedExtensionNames
        let message = installedExtensions.isEmpty
            ? "No extensions are installed."
            : installedExtensions.joined(separator: "\n")

        showExtensionAlert(title: "Extensions", message: message)
    }

    private func showExtensionsUnavailableAlert() {
        showExtensionAlert(
            title: "Extensions Unavailable",
            message: "Quartz can install WebExtension directories or ZIP archives on macOS 15.4 or later."
        )
    }

    private func showExtensionAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func loadSavedExtensionsThenLoadHome() {
        if #available(macOS 15.4, *), let support = webExtensionSupport as? QuartzWebExtensionSupport {
            addressField.stringValue = "Loading extensions..."
            extensionsButton.isEnabled = false

            support.loadSavedExtensions { [weak self] in
                guard let self else {
                    return
                }

                self.updateExtensionsButton()
                self.load(self.homeURL)
            }
            return
        }

        load(homeURL)
    }

    private func updateExtensionsButton() {
        guard #available(macOS 15.4, *), let support = webExtensionSupport as? QuartzWebExtensionSupport else {
            extensionsButton.image = NSImage(
                systemSymbolName: "puzzlepiece.extension",
                accessibilityDescription: "Extensions unavailable"
            )
            extensionsButton.toolTip = "Extensions require macOS 15.4 or later"
            extensionsButton.isEnabled = true
            return
        }

        let count = support.installedExtensionNames.count
        extensionsButton.image = NSImage(
            systemSymbolName: count == 0 ? "puzzlepiece.extension" : "puzzlepiece.extension.fill",
            accessibilityDescription: "Extensions"
        )
        extensionsButton.toolTip = count == 1 ? "1 extension installed" : "\(count) extensions installed"
        extensionsButton.isEnabled = true
    }

    var extensionWebView: WKWebView? {
        webView
    }

    var extensionWindow: NSWindow? {
        window
    }

    func loadFromExtension(_ url: URL) {
        load(url)
    }

    private func load(_ url: URL) {
        addressField.stringValue = url.absoluteString

        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }

        updateControls()
    }

    private func normalizedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "file"].contains(scheme) {
            return url
        }

        if looksLikeHost(trimmed), let url = URL(string: "https://\(trimmed)") {
            return url
        }

        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components.url
    }

    private func looksLikeHost(_ text: String) -> Bool {
        text == "localhost"
            || text.contains(".")
            || text.hasPrefix("localhost:")
            || text.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?$"#, options: .regularExpression) != nil
    }

    private func updateControls() {
        guard webView != nil else {
            return
        }

        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
        reloadButton.isHidden = webView.isLoading
        stopButton.isHidden = !webView.isLoading
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        updateControls()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url {
            addressField.stringValue = url.absoluteString
        }
        window.title = webView.title?.isEmpty == false ? "\(webView.title!) - Quartz" : "Quartz"
        updateControls()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showLoadError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showLoadError(error)
    }

    private func showLoadError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "Quartz could not load this page."
        alert.informativeText = error.localizedDescription
        print("Quartz load error: \(error)")
        alert.runModal()
        updateControls()
    }
}
