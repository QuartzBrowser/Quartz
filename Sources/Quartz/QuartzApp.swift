import AppKit
import UniformTypeIdentifiers
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
    private let adBlockerButton = BrowserController.makeIconButton(symbolName: "shield", description: "Ad Blocker")
    private let readerButton = BrowserController.makeIconButton(symbolName: "doc.text", description: "Reading Mode")
    private let extensionsButton = BrowserController.makeIconButton(symbolName: "puzzlepiece.extension", description: "Extensions")
    private let submitIssueButton = BrowserController.makeIconButton(symbolName: "exclamationmark.bubble", description: "Submit Issue")
    private let adBlocker = QuartzAdBlocker()
    private let issueReporter = GitHubIssueReporter(owner: "QuartzBrowser", repository: "Quartz")
    private var adBlockerMenuItem: NSMenuItem?
    private var readerModeMenuItem: NSMenuItem?
    private var submitIssueMenuItem: NSMenuItem?
    private var isReaderModeActive = false
    private var isSubmittingIssue = false

    private let homeURL = URL(string: "https://www.example.com")!

    private struct IssueForm {
        let view: NSView
        let titleField: NSTextField
        let bodyTextView: NSTextView
    }

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
        let userContentController = WKUserContentController()
        configuration.userContentController = userContentController
        adBlocker.connect(to: userContentController)

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
        configure(button: adBlockerButton, action: #selector(toggleAdBlocker(_:)))
        configure(button: readerButton, action: #selector(toggleReaderMode(_:)))
        configure(button: extensionsButton, action: #selector(showExtensionStatus(_:)))
        configure(button: submitIssueButton, action: #selector(showIssueReporter(_:)))
        updateAdBlockerControls()
        updateExtensionsButton()

        let toolbar = NSStackView(views: [
            backButton,
            forwardButton,
            reloadButton,
            stopButton,
            homeButton,
            adBlockerButton,
            readerButton,
            extensionsButton,
            submitIssueButton,
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

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")

        let adBlockerItem = NSMenuItem(title: "Disable Basic Ad Blocker", action: #selector(toggleAdBlocker(_:)), keyEquivalent: "b")
        adBlockerItem.keyEquivalentModifierMask = [.command, .shift]
        adBlockerItem.target = self
        viewMenu.addItem(adBlockerItem)
        adBlockerMenuItem = adBlockerItem

        let readerItem = NSMenuItem(title: "Enter Reading Mode", action: #selector(toggleReaderMode(_:)), keyEquivalent: "r")
        readerItem.keyEquivalentModifierMask = [.command, .shift]
        readerItem.target = self
        viewMenu.addItem(readerItem)
        readerModeMenuItem = readerItem

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

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

        let installExtensionItem = NSMenuItem(title: "Install .qrx Extension...", action: #selector(installExtension(_:)), keyEquivalent: "e")
        installExtensionItem.target = self
        extensionsMenu.addItem(installExtensionItem)

        let extensionStatusItem = NSMenuItem(title: "Extension Status", action: #selector(showExtensionStatus(_:)), keyEquivalent: "")
        extensionStatusItem.target = self
        extensionsMenu.addItem(extensionStatusItem)

        extensionsMenuItem.submenu = extensionsMenu
        mainMenu.addItem(extensionsMenuItem)

        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")

        let submitIssueItem = NSMenuItem(title: "Submit Issue...", action: #selector(showIssueReporter(_:)), keyEquivalent: "i")
        submitIssueItem.keyEquivalentModifierMask = [.command, .shift]
        submitIssueItem.target = self
        helpMenu.addItem(submitIssueItem)
        submitIssueMenuItem = submitIssueItem

        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

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

    @objc private func toggleReaderMode(_ sender: Any?) {
        if isReaderModeActive {
            exitReaderMode()
        } else {
            enterReaderMode()
        }
    }

    @objc private func toggleAdBlocker(_ sender: Any?) {
        let shouldEnable = !adBlocker.isEnabled
        adBlockerButton.isEnabled = false
        adBlockerMenuItem?.isEnabled = false

        adBlocker.setEnabled(shouldEnable) { [weak self] result in
            guard let self else {
                return
            }

            self.updateAdBlockerControls()

            switch result {
            case .success:
                if self.webView.url != nil {
                    self.webView.reload()
                }
            case .failure(let error):
                self.showAdBlockerAlert(message: error.localizedDescription)
            }
        }
    }

    @objc private func installExtension(_ sender: Any?) {
        guard #available(macOS 15.4, *), let support = webExtensionSupport as? QuartzWebExtensionSupport else {
            showExtensionsUnavailableAlert()
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Install Quartz Extension Package"
        panel.message = "Choose a Quartz extension package (.qrx)."
        panel.prompt = "Install"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "qrx") ?? .data]

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

    @objc private func showIssueReporter(_ sender: Any?) {
        let form = makeIssueForm()
        let alert = NSAlert()
        alert.messageText = "Submit Issue"
        alert.informativeText = "Create a GitHub issue in \(issueReporter.repositoryName)."
        alert.accessoryView = form.view
        alert.addButton(withTitle: "Submit")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let title = form.titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = form.bodyTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !title.isEmpty else {
            showIssueAlert(title: "Issue Needs a Title", message: "Enter a short title before submitting.")
            return
        }

        submitIssue(
            title: title,
            body: body.isEmpty ? "Submitted from Quartz." : body
        )
    }

    private func makeIssueForm() -> IssueForm {
        let titleField = NSTextField(string: defaultIssueTitle())
        titleField.placeholderString = "Issue title"
        titleField.font = .systemFont(ofSize: 13)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.widthAnchor.constraint(equalToConstant: 520).isActive = true

        let bodyTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        bodyTextView.string = defaultIssueBody()
        bodyTextView.font = .systemFont(ofSize: 13)
        bodyTextView.isRichText = false
        bodyTextView.isAutomaticQuoteSubstitutionEnabled = false
        bodyTextView.isAutomaticDashSubstitutionEnabled = false
        bodyTextView.isHorizontallyResizable = false
        bodyTextView.isVerticallyResizable = true
        bodyTextView.autoresizingMask = [.width]
        bodyTextView.textContainer?.containerSize = NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude)
        bodyTextView.textContainer?.widthTracksTextView = true

        let bodyScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        bodyScrollView.borderType = .bezelBorder
        bodyScrollView.hasVerticalScroller = true
        bodyScrollView.documentView = bodyTextView
        bodyScrollView.translatesAutoresizingMaskIntoConstraints = false
        bodyScrollView.widthAnchor.constraint(equalToConstant: 520).isActive = true
        bodyScrollView.heightAnchor.constraint(equalToConstant: 220).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(NSTextField(labelWithString: "Title"))
        stack.addArrangedSubview(titleField)
        stack.addArrangedSubview(NSTextField(labelWithString: "Details"))
        stack.addArrangedSubview(bodyScrollView)

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 295))
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        return IssueForm(
            view: view,
            titleField: titleField,
            bodyTextView: bodyTextView
        )
    }

    private func defaultIssueTitle() -> String {
        if let title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return "Issue on \(title)"
        }

        if let host = webView.url?.host, !host.isEmpty {
            return "Issue on \(host)"
        }

        return "Quartz issue"
    }

    private func defaultIssueBody() -> String {
        var lines = [
            "## What happened?",
            "",
            "",
            "## Context"
        ]

        if let url = webView.url?.absoluteString {
            lines.append("- Page URL: \(url)")
        }

        if let title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            lines.append("- Page title: \(title)")
        }

        lines.append("- macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("- Submitted from: Quartz")
        return lines.joined(separator: "\n")
    }

    private func submitIssue(title: String, body: String) {
        isSubmittingIssue = true
        updateIssueSubmissionControls()

        Task { @MainActor in
            do {
                let issue = try await issueReporter.createIssue(
                    title: title,
                    body: body,
                    context: issueSubmissionContext()
                )
                showIssueSubmittedAlert(issue: issue)
            } catch {
                showIssueAlert(title: "Issue Not Submitted", message: error.localizedDescription)
            }

            isSubmittingIssue = false
            updateIssueSubmissionControls()
        }
    }

    private func updateIssueSubmissionControls() {
        submitIssueButton.isEnabled = !isSubmittingIssue
        submitIssueButton.toolTip = isSubmittingIssue ? "Submitting Issue..." : "Submit Issue"
        submitIssueMenuItem?.isEnabled = !isSubmittingIssue
    }

    private func issueSubmissionContext() -> IssueSubmissionContext {
        let pageTitle = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines)

        return IssueSubmissionContext(
            pageURL: webView.url?.absoluteString,
            pageTitle: pageTitle?.isEmpty == false ? pageTitle : nil
        )
    }

    private func showIssueSubmittedAlert(issue: GitHubIssue) {
        let alert = NSAlert()
        alert.messageText = "Issue Submitted"
        alert.informativeText = "Created \(issueReporter.repositoryName)#\(issue.number)."

        alert.addButton(withTitle: "Open Issue")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn {
            load(issue.htmlURL)
        }
    }

    private func showIssueAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func showExtensionsUnavailableAlert() {
        showExtensionAlert(
            title: "Extensions Unavailable",
            message: "Quartz can install .qrx WebExtension packages on macOS 15.4 or later."
        )
    }

    private func showExtensionAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func loadSavedExtensionsThenLoadHome() {
        addressField.stringValue = "Preparing content filters..."
        adBlockerButton.isEnabled = false
        adBlockerMenuItem?.isEnabled = false

        adBlocker.prepare { [weak self] result in
            guard let self else {
                return
            }

            if case .failure(let error) = result {
                print("Quartz ad blocker unavailable: \(error.localizedDescription)")
                self.adBlocker.disable()
            }

            self.updateAdBlockerControls()
            self.loadSavedExtensionsThenLoadHomeAfterContentFilters()
        }
    }

    private func loadSavedExtensionsThenLoadHomeAfterContentFilters() {
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

    private func updateAdBlockerControls() {
        let isEnabled = adBlocker.isEnabled
        adBlockerButton.image = NSImage(
            systemSymbolName: isEnabled ? "shield.fill" : "shield",
            accessibilityDescription: "Ad Blocker"
        )
        adBlockerButton.state = isEnabled ? .on : .off
        adBlockerButton.toolTip = isEnabled ? "Basic Ad Blocker On" : "Basic Ad Blocker Off"
        adBlockerButton.contentTintColor = isEnabled ? .controlAccentColor : nil
        adBlockerButton.isEnabled = true

        adBlockerMenuItem?.isEnabled = true
        adBlockerMenuItem?.state = isEnabled ? .on : .off
        adBlockerMenuItem?.title = isEnabled ? "Disable Basic Ad Blocker" : "Enable Basic Ad Blocker"
    }

    private func showAdBlockerAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Ad Blocker"
        alert.informativeText = message
        alert.runModal()
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
        updateAdBlockerControls()
        updateReaderModeControls()
    }

    private var canUseReaderMode: Bool {
        guard webView != nil,
              let scheme = webView.url?.scheme?.lowercased()
        else {
            return false
        }

        return ["http", "https", "file"].contains(scheme)
    }

    private func updateReaderModeControls() {
        guard webView != nil else {
            return
        }

        let isAvailable = isReaderModeActive || (!webView.isLoading && canUseReaderMode)
        readerButton.isEnabled = isAvailable
        readerButton.state = isReaderModeActive ? .on : .off
        readerButton.image = NSImage(
            systemSymbolName: isReaderModeActive ? "doc.text.fill" : "doc.text",
            accessibilityDescription: "Reading Mode"
        )
        readerButton.toolTip = isReaderModeActive ? "Exit Reading Mode" : "Enter Reading Mode"
        readerButton.contentTintColor = isReaderModeActive ? .controlAccentColor : nil

        readerModeMenuItem?.isEnabled = isAvailable
        readerModeMenuItem?.state = isReaderModeActive ? .on : .off
        readerModeMenuItem?.title = isReaderModeActive ? "Exit Reading Mode" : "Enter Reading Mode"
    }

    private func enterReaderMode() {
        guard canUseReaderMode else {
            showReaderModeAlert(message: "Reading Mode is available for loaded web pages and local HTML files.")
            return
        }

        readerButton.isEnabled = false
        readerModeMenuItem?.isEnabled = false

        webView.evaluateJavaScript(Self.enterReaderModeScript) { [weak self] result, error in
            guard let self else {
                return
            }

            self.readerButton.isEnabled = true
            self.readerModeMenuItem?.isEnabled = true

            if let error {
                self.showReaderModeAlert(message: error.localizedDescription)
                self.updateReaderModeControls()
                return
            }

            guard let status = result as? [String: Any],
                  status["ok"] as? Bool == true
            else {
                self.showReaderModeAlert(message: "Quartz could not find enough article text on this page.")
                self.updateReaderModeControls()
                return
            }

            self.isReaderModeActive = true
            self.updateReaderModeControls()
        }
    }

    private func exitReaderMode() {
        readerButton.isEnabled = false
        readerModeMenuItem?.isEnabled = false

        webView.evaluateJavaScript(Self.exitReaderModeScript) { [weak self] _, _ in
            guard let self else {
                return
            }

            self.isReaderModeActive = false
            self.readerButton.isEnabled = true
            self.readerModeMenuItem?.isEnabled = true
            self.updateReaderModeControls()
        }
    }

    private func showReaderModeAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Reading Mode"
        alert.informativeText = message
        alert.runModal()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        updateControls()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if isReaderModeActive {
            isReaderModeActive = false
        }

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

    private static let enterReaderModeScript = #"""
(() => {
    if (window.__quartzReaderMode?.overlay?.isConnected) {
        return { ok: true, alreadyActive: true };
    }

    const cleanText = (value) => (value || "").replace(/\s+/g, " ").trim();
    const pageTitle = cleanText(
        document.querySelector("meta[property='og:title']")?.content ||
        document.querySelector("meta[name='twitter:title']")?.content ||
        document.querySelector("h1")?.innerText ||
        document.title ||
        location.hostname
    );
    const byline = cleanText(
        document.querySelector("meta[name='author']")?.content ||
        document.querySelector("[rel='author']")?.innerText ||
        document.querySelector(".byline, .author, [class*='byline'], [class*='author']")?.innerText ||
        ""
    );
    const site = cleanText(
        document.querySelector("meta[property='og:site_name']")?.content ||
        location.hostname.replace(/^www\./, "")
    );
    const isVisible = (element) => {
        const style = window.getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.display !== "none" &&
            style.visibility !== "hidden" &&
            rect.width > 0 &&
            rect.height > 0;
    };
    const textFor = (element) => cleanText(element.innerText || element.textContent || "");
    const signatureFor = (element) => `${element.id || ""} ${element.className || ""}`.toLowerCase();
    const scoreCandidate = (element) => {
        const text = textFor(element);
        const paragraphs = Array.from(element.querySelectorAll("p"));
        const paragraphTextLength = paragraphs.reduce((length, paragraph) => length + textFor(paragraph).length, 0);
        const linkTextLength = Array.from(element.querySelectorAll("a"))
            .reduce((length, link) => length + textFor(link).length, 0);
        const textLength = Math.max(text.length, paragraphTextLength);

        if (textLength < 500 || paragraphTextLength < 280) {
            return -Infinity;
        }

        const tagScore = {
            ARTICLE: 900,
            MAIN: 780,
            SECTION: 180,
            DIV: 80
        }[element.tagName] || 0;
        const signature = signatureFor(element);
        const positive = /(article|content|entry|feature|main|post|reader|story|text)/.test(signature) ? 420 : 0;
        const negative = /(ad|aside|banner|comment|footer|header|menu|modal|nav|promo|related|share|sidebar|sponsor|subscribe)/.test(signature) ? 760 : 0;
        const linkPenalty = (linkTextLength / Math.max(textLength, 1)) * 1050;
        const paragraphScore = paragraphs.length * 90;
        const headingScore = element.querySelectorAll("h1, h2, h3").length * 30;
        const mediaScore = Math.min(element.querySelectorAll("img, picture, figure").length, 4) * 25;

        return tagScore + positive + paragraphScore + headingScore + mediaScore + (textLength * 0.18) - negative - linkPenalty;
    };

    const candidates = Array.from(document.querySelectorAll("article, main, [role='main'], section, div"))
        .filter(isVisible);
    const best = candidates
        .map((element) => ({ element, score: scoreCandidate(element) }))
        .sort((left, right) => right.score - left.score)[0];
    const source = best?.score > 0 ? best.element : document.body;
    const clone = source.cloneNode(true);
    const junkSelector = [
        "script",
        "style",
        "noscript",
        "iframe",
        "nav",
        "footer",
        "header",
        "aside",
        "form",
        "button",
        "input",
        "textarea",
        "select",
        "svg",
        "canvas",
        "video",
        "audio",
        "[hidden]",
        "[aria-hidden='true']",
        "[role='banner']",
        "[role='contentinfo']",
        "[role='navigation']",
        "[class*='advert']",
        "[class*='comment']",
        "[class*='modal']",
        "[class*='newsletter']",
        "[class*='promo']",
        "[class*='related']",
        "[class*='share']",
        "[class*='sidebar']",
        "[class*='sponsor']",
        "[class*='subscribe']",
        "[id*='advert']",
        "[id*='comment']",
        "[id*='newsletter']",
        "[id*='promo']",
        "[id*='related']",
        "[id*='share']",
        "[id*='sidebar']",
        "[id*='subscribe']"
    ].join(",");

    clone.querySelectorAll(junkSelector).forEach((node) => node.remove());
    clone.querySelectorAll("a[href]").forEach((link) => {
        try {
            link.href = new URL(link.getAttribute("href"), document.baseURI).href;
        } catch {}
    });
    clone.querySelectorAll("img[src], source[src], picture source[src]").forEach((media) => {
        try {
            media.src = new URL(media.getAttribute("src"), document.baseURI).href;
        } catch {}
    });
    clone.querySelectorAll("*").forEach((node) => {
        for (const attribute of Array.from(node.attributes)) {
            const name = attribute.name.toLowerCase();
            const allowed = ["href", "src", "srcset", "alt", "title", "datetime", "cite", "colspan", "rowspan"];
            if (name.startsWith("on") || name === "style" || name === "id" || name === "class" || name === "srcdoc") {
                node.removeAttribute(attribute.name);
            } else if (!allowed.includes(name) && !name.startsWith("aria-")) {
                node.removeAttribute(attribute.name);
            }
        }
    });
    clone.querySelectorAll("p, li, blockquote, pre, h1, h2, h3, h4, h5, h6").forEach((node) => {
        if (!cleanText(node.textContent) && node.querySelector("img, picture, video, iframe") === null) {
            node.remove();
        }
    });

    const articleText = textFor(clone);
    if (articleText.length < 500) {
        return { ok: false, reason: "tooShort" };
    }

    const escapeHTML = (value) => String(value || "").replace(/[&<>"']/g, (character) => ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        "\"": "&quot;",
        "'": "&#39;"
    }[character]));
    const wordCount = articleText.split(/\s+/).filter(Boolean).length;
    const readingMinutes = Math.max(1, Math.round(wordCount / 235));
    const metaParts = [site, byline, `${readingMinutes} min read`].filter(Boolean);

    const overlay = document.createElement("div");
    overlay.id = "quartz-reading-mode";
    overlay.setAttribute("role", "main");
    const shadow = overlay.attachShadow({ mode: "open" });
    shadow.innerHTML = `
        <style>
            :host {
                all: initial;
                position: fixed;
                inset: 0;
                z-index: 2147483647;
                overflow: auto;
                background: #fafaf8;
                color: #202124;
                color-scheme: light;
                font-family: ui-serif, Georgia, Cambria, "Times New Roman", Times, serif;
                -webkit-font-smoothing: antialiased;
            }

            * {
                box-sizing: border-box;
            }

            .shell {
                min-height: 100%;
                padding: clamp(28px, 5vw, 72px) clamp(20px, 7vw, 96px);
            }

            article {
                width: min(100%, 760px);
                margin: 0 auto;
            }

            header {
                margin-bottom: 2.35rem;
                padding-bottom: 1.4rem;
                border-bottom: 1px solid rgba(32, 33, 36, 0.14);
            }

            .meta {
                margin-bottom: 0.9rem;
                color: #5f665f;
                font: 500 0.82rem/1.55 ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
                letter-spacing: 0;
            }

            h1 {
                margin: 0;
                color: #17191c;
                font-size: clamp(2rem, 4vw, 3.45rem);
                line-height: 1.06;
                font-weight: 720;
                letter-spacing: 0;
            }

            .content {
                font-size: 1.23rem;
                line-height: 1.75;
            }

            .content :is(h1, h2, h3, h4, h5, h6) {
                color: #1f2324;
                font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
                letter-spacing: 0;
                line-height: 1.2;
                margin: 2.2em 0 0.7em;
            }

            .content h1 {
                font-size: 2rem;
            }

            .content h2 {
                font-size: 1.55rem;
            }

            .content h3 {
                font-size: 1.28rem;
            }

            .content p,
            .content ul,
            .content ol,
            .content blockquote,
            .content pre,
            .content table,
            .content figure {
                margin: 0 0 1.25em;
            }

            .content a {
                color: #0b6f6a;
                text-decoration-color: rgba(11, 111, 106, 0.35);
                text-decoration-thickness: 0.08em;
                text-underline-offset: 0.16em;
            }

            .content img,
            .content picture {
                display: block;
                max-width: 100%;
                height: auto;
                margin: 1.55rem auto;
                border-radius: 6px;
            }

            .content blockquote {
                padding-left: 1.1em;
                border-left: 3px solid rgba(11, 111, 106, 0.42);
                color: #49524f;
                font-style: italic;
            }

            .content pre,
            .content code {
                font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
                font-size: 0.9em;
            }

            .content pre {
                overflow: auto;
                padding: 1rem;
                border-radius: 6px;
                background: rgba(32, 33, 36, 0.08);
            }

            .content table {
                width: 100%;
                border-collapse: collapse;
                font-size: 0.95em;
            }

            .content th,
            .content td {
                padding: 0.55rem 0.65rem;
                border-bottom: 1px solid rgba(32, 33, 36, 0.14);
                text-align: left;
                vertical-align: top;
            }

            @media (max-width: 620px) {
                .shell {
                    padding: 24px 18px 48px;
                }

                .content {
                    font-size: 1.1rem;
                    line-height: 1.68;
                }
            }
        </style>
        <div class="shell">
            <article>
                <header>
                    <div class="meta">${escapeHTML(metaParts.join(" · "))}</div>
                    <h1>${escapeHTML(pageTitle)}</h1>
                </header>
                <div class="content">${clone.innerHTML}</div>
            </article>
        </div>
    `;

    window.__quartzReaderMode = {
        overlay,
        documentOverflow: document.documentElement.style.overflow,
        bodyOverflow: document.body.style.overflow,
        bodyBackground: document.body.style.background
    };
    document.documentElement.style.overflow = "hidden";
    document.body.style.overflow = "hidden";
    document.body.style.background = "#fafaf8";
    document.body.appendChild(overlay);

    return { ok: true, title: pageTitle, wordCount };
})();
"""#

    private static let exitReaderModeScript = #"""
(() => {
    const readerMode = window.__quartzReaderMode;
    if (!readerMode) {
        return { ok: true, alreadyInactive: true };
    }

    readerMode.overlay?.remove();
    document.documentElement.style.overflow = readerMode.documentOverflow || "";
    document.body.style.overflow = readerMode.bodyOverflow || "";
    document.body.style.background = readerMode.bodyBackground || "";
    delete window.__quartzReaderMode;

    return { ok: true };
})();
"""#
}
