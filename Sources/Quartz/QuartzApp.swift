import AppKit
import UniformTypeIdentifiers
import WebKit

@main
struct QuartzApp {
    @MainActor
    private static var browserController: BrowserController?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = BrowserController()

        browserController = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        delegate.start()
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

@MainActor
final class BrowserController: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, NSTextFieldDelegate, FacetPanelViewDelegate {
    private(set) static var openBrowsers = [BrowserController]()
    private static weak var applicationController: BrowserController?
    private static var latestUpdateState: QuartzUpdateState = .idle
    private(set) static weak var lastFocusedBrowser: BrowserController?
    private let restoresSavedSession: Bool
    private let focusesWindowOnOpen: Bool
    private let sessionDefaults: UserDefaults
    private var initialNavigation: ((BrowserController) -> Void)?
    private var window: NSWindow!
    private var webContentView: NSView!
    private var facetPanelView: FacetPanelView!
    private var facetPanelWidthConstraint: NSLayoutConstraint!
    private var standardWebView: WKWebView!
    private var webView: WKWebView!
    private var activeWebViewConstraints = [NSLayoutConstraint]()
    private var displayURLOverride: URL?
    private var webExtensionSupport: AnyObject?
    private let facetClient = FacetOpenRouterClient()
    private var activeFacetTask: Task<Void, Never>?
    private var activeFacetRequestID: UUID?
    private var facetModelOptionsTask: Task<Void, Never>?
    private var facetMessages = [FacetChatMessage]()
    private var hasLoadedFacetModels = false
    private var didStart = false
    private var hasClosedWindow = false
    private var sessionURL: URL?
    private var pendingNavigationURL: URL?
    private var isShowingStartPage = false
    private var didRestoreSession = false
    private var pendingUpdateReleaseURL: URL?
    private var checkForUpdatesMenuItem: NSMenuItem?
    private var automaticUpdatesMenuItem: NSMenuItem?
    private let updateProgressIndicator = NSProgressIndicator()
    private var updateController: QuartzUpdateController {
        (Self.applicationController ?? self).ownedUpdateController
    }
    private lazy var ownedUpdateController: QuartzUpdateController = QuartzUpdateController(
        stateChanged: { [weak self] state in
            Self.latestUpdateState = state
            for browser in Self.openBrowsers {
                browser.updateUpdateControls(state)
            }
            if Self.openBrowsers.isEmpty { self?.updateUpdateControls(state) }
        },
        presentMessage: { [weak self] title, message, acknowledgement in
            guard let self else { acknowledgement(); return }
            (Self.lastFocusedBrowser ?? self).presentUpdateMessage(title: title, message: message, acknowledgement: acknowledgement)
        },
        openInformationURL: { [weak self] url in
            (Self.lastFocusedBrowser ?? self)?.openUpdateRelease(url)
        },
        prepareForRelaunch: { [weak self] in
            (Self.lastFocusedBrowser ?? self)?.saveCurrentSession()
        }
    )

    private let addressField = NSTextField()
    private let backButton = BrowserController.makeIconButton(symbolName: "chevron.left", description: "Back")
    private let forwardButton = BrowserController.makeIconButton(symbolName: "chevron.right", description: "Forward")
    private let reloadButton = BrowserController.makeIconButton(symbolName: "arrow.clockwise", description: "Reload")
    private let stopButton = BrowserController.makeIconButton(symbolName: "xmark", description: "Stop")
    private let homeButton = BrowserController.makeIconButton(symbolName: "house", description: "Home")
    private let adBlockerButton = BrowserController.makeIconButton(symbolName: "shield", description: "Ad Blocker")
    private let readerButton = BrowserController.makeIconButton(symbolName: "doc.text", description: "Reading Mode")
    private let facetButton = BrowserController.makeIconButton(symbolName: "sparkles", description: "Facet")
    private let extensionsButton = BrowserController.makeIconButton(symbolName: "puzzlepiece.extension", description: "Extensions")
    private let webStoreInstallButton = BrowserController.makeCommandButton(
        title: "Install",
        symbolName: "puzzlepiece.extension.fill",
        description: "Install this Chrome Web Store extension"
    )
    private let updateButton = BrowserController.makeCommandButton(
        title: "Update & Restart",
        symbolName: "arrow.down.circle.fill",
        description: "Download, verify and install the Quartz update, then restart"
    )
    private let cancelUpdateButton = BrowserController.makeIconButton(
        symbolName: "xmark.circle",
        description: "Cancel update"
    )
    private let adBlocker = QuartzAdBlocker()
    private var adBlockerMenuItem: NSMenuItem?
    private var readerModeMenuItem: NSMenuItem?
    private var facetMenuItem: NSMenuItem?
    private var installCurrentChromeWebStoreExtensionMenuItem: NSMenuItem?
    private var installExtensionMenuItem: NSMenuItem?
    private var installChromeWebStoreExtensionMenuItem: NSMenuItem?
    private weak var extensionActionPopupAnchorView: NSView?
    private var isInstallingExtension = false
    private var isReaderModeActive = false
    private var isFacetPanelVisible = false

    private static let savedSessionURLKey = "Quartz.savedSession.url"
    private static let sandboxedExtensionPageScheme = "quartz-extension-sandbox"

    init(sharedExtensionSupport: AnyObject? = nil, restoresSavedSession: Bool = true, focusesWindow: Bool = true, sessionDefaults: UserDefaults = .standard) {
        self.webExtensionSupport = sharedExtensionSupport
        self.restoresSavedSession = restoresSavedSession
        self.focusesWindowOnOpen = focusesWindow
        self.sessionDefaults = sessionDefaults
        super.init()
    }
    private lazy var downloadCoordinator = QuartzDownloadCoordinator(window: { [weak self] in self?.window })

    func applicationDidFinishLaunching(_ notification: Notification) {
        start()
        updateController.start()
    }

    func start() {
        guard didStart == false else {
            return
        }

        didStart = true
        if Self.applicationController == nil {
            Self.applicationController = self
            buildMenu()
        }
        buildWindow()
        loadSavedExtensionsThenRestoreSession()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        for browser in Self.openBrowsers {
            browser.activeFacetTask?.cancel()
            browser.facetModelOptionsTask?.cancel()
            browser.downloadCoordinator.cancelAll(discardStagingImmediately: true)
        }
        Self.lastFocusedBrowser?.saveCurrentSession()
    }

    func windowWillClose(_ notification: Notification) {
        saveCurrentSession()
        hasClosedWindow = true
        initialNavigation = nil
        pendingNavigationURL = nil
        activeFacetTask?.cancel()
        facetModelOptionsTask?.cancel()
        downloadCoordinator.cancelAll()
        webView.stopLoading()
        Self.openBrowsers.removeAll { $0 === self }
        if Self.lastFocusedBrowser === self { Self.lastFocusedBrowser = Self.openBrowsers.last }
        if #available(macOS 15.4, *), let support = webExtensionSupport as? QuartzWebExtensionSupport {
            support.unregisterBrowser(self)
        }
        Self.lastFocusedBrowser?.buildMenu()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        Self.lastFocusedBrowser = self
        buildMenu()
        updateControls()
    }

    @discardableResult
    func openBrowserWindow(focused: Bool = true, initialURL: URL? = nil, navigate: ((BrowserController) -> Void)? = nil) -> BrowserController {
        let browser = BrowserController(sharedExtensionSupport: webExtensionSupport, restoresSavedSession: false, focusesWindow: focused, sessionDefaults: sessionDefaults)
        browser.initialNavigation = navigate
        browser.pendingNavigationURL = initialURL ?? QuartzStartPage.url
        browser.start()
        return browser
    }

    @objc private func newWindow(_ sender: Any?) {
        openBrowserWindow()
    }

    private func buildWindow() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(
            QuartzStartPageSchemeHandler(),
            forURLScheme: QuartzStartPage.scheme
        )
        let userContentController = WKUserContentController()
        configuration.userContentController = userContentController
        adBlocker.connect(to: userContentController)

        if #available(macOS 15.4, *) {
            let support = (webExtensionSupport as? QuartzWebExtensionSupport)
                ?? QuartzWebExtensionSupport(browser: self, webViewConfiguration: configuration)
            configuration.webExtensionController = support.controller
            webExtensionSupport = support
            support.onChange = {
                for browser in Self.openBrowsers { browser.updateControls() }
            }
        }

        let initialWebView = makeWebView(configuration: configuration)
        standardWebView = initialWebView
        webView = initialWebView

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
        configure(button: facetButton, action: #selector(toggleFacetPanel(_:)))
        configure(button: extensionsButton, action: #selector(showExtensionsMenu(_:)))
        configure(button: webStoreInstallButton, action: #selector(installCurrentChromeWebStoreExtension(_:)))
        configure(button: updateButton, action: #selector(performUpdateAction(_:)))
        configure(button: cancelUpdateButton, action: #selector(cancelUpdate(_:)))
        updateProgressIndicator.style = .bar
        updateProgressIndicator.controlSize = .small
        updateProgressIndicator.minValue = 0
        updateProgressIndicator.maxValue = 1
        updateProgressIndicator.translatesAutoresizingMaskIntoConstraints = false
        updateProgressIndicator.widthAnchor.constraint(equalToConstant: 50).isActive = true
        updateProgressIndicator.setAccessibilityLabel("Quartz update progress")
        updateUpdateControls(Self.latestUpdateState)
        webStoreInstallButton.isHidden = true
        updateAdBlockerControls()
        updateExtensionsButton()
        updateExtensionInstallControls()

        let toolbar = NSStackView(views: [
            backButton,
            forwardButton,
            reloadButton,
            stopButton,
            homeButton,
            adBlockerButton,
            readerButton,
            facetButton,
            extensionsButton,
            webStoreInstallButton,
            addressField,
            goButton,
            updateButton,
            updateProgressIndicator,
            cancelUpdateButton
        ])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 740))
        container.autoresizingMask = [.width, .height]
        let contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        webContentView = NSView()
        webContentView.translatesAutoresizingMaskIntoConstraints = false
        facetPanelView = FacetPanelView()
        facetPanelView.delegate = self
        facetPanelView.isHidden = true
        facetPanelView.translatesAutoresizingMaskIntoConstraints = false
        facetPanelWidthConstraint = facetPanelView.widthAnchor.constraint(equalToConstant: 0)
        container.addSubview(toolbar)
        container.addSubview(contentContainer)
        contentContainer.addSubview(webContentView)
        contentContainer.addSubview(facetPanelView)
        embed(webView: initialWebView)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 54),

            addressField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            contentContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 686),

            contentContainer.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            webContentView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            webContentView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            webContentView.trailingAnchor.constraint(equalTo: facetPanelView.leadingAnchor),
            webContentView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            facetPanelView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            facetPanelView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            facetPanelView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            facetPanelWidthConstraint
        ])

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Quartz"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.center()
        window.minSize = NSSize(width: 520, height: 360)
        window.contentView = container
        Self.openBrowsers.append(self)
        if #available(macOS 15.4, *), let support = webExtensionSupport as? QuartzWebExtensionSupport {
            support.registerBrowser(self)
        }
        if focusesWindowOnOpen {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderBack(nil)
        }
        window.setContentSize(NSSize(width: 1100, height: 740))
        window.layoutIfNeeded()

        updateControls()
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.autoenablesItems = false
        let checkItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        checkItem.target = self
        appMenu.addItem(checkItem)
        checkForUpdatesMenuItem = checkItem
        let automaticItem = NSMenuItem(
            title: "Automatically Check for Updates",
            action: #selector(toggleAutomaticUpdates(_:)),
            keyEquivalent: ""
        )
        automaticItem.target = self
        automaticItem.state = updateController.automaticallyChecksForUpdates ? .on : .off
        appMenu.addItem(automaticItem)
        automaticUpdatesMenuItem = automaticItem
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Quartz", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenu = NSMenu(title: "File")
        let newWindowItem = NSMenuItem(title: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        newWindowItem.target = self
        fileMenu.addItem(newWindowItem)
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

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

        let facetItem = NSMenuItem(title: "Show Facet", action: #selector(toggleFacetPanel(_:)), keyEquivalent: "f")
        facetItem.keyEquivalentModifierMask = [.command, .shift]
        facetItem.target = self
        viewMenu.addItem(facetItem)
        facetMenuItem = facetItem

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

        let installCurrentChromeWebStoreExtensionItem = NSMenuItem(
            title: "Install This Web Store Extension",
            action: #selector(installCurrentChromeWebStoreExtension(_:)),
            keyEquivalent: ""
        )
        installCurrentChromeWebStoreExtensionItem.target = self
        extensionsMenu.addItem(installCurrentChromeWebStoreExtensionItem)
        installCurrentChromeWebStoreExtensionMenuItem = installCurrentChromeWebStoreExtensionItem

        extensionsMenu.addItem(.separator())

        let installChromeWebStoreExtensionItem = NSMenuItem(
            title: "Install from Chrome Web Store...",
            action: #selector(installExtensionFromChromeWebStore(_:)),
            keyEquivalent: ""
        )
        installChromeWebStoreExtensionItem.target = self
        extensionsMenu.addItem(installChromeWebStoreExtensionItem)
        installChromeWebStoreExtensionMenuItem = installChromeWebStoreExtensionItem

        let installExtensionItem = NSMenuItem(title: "Install Extension from File...", action: #selector(installExtension(_:)), keyEquivalent: "e")
        installExtensionItem.target = self
        extensionsMenu.addItem(installExtensionItem)
        installExtensionMenuItem = installExtensionItem

        extensionsMenu.addItem(.separator())

        let extensionStatusItem = NSMenuItem(title: "Manage Extensions…", action: #selector(showExtensionStatus(_:)), keyEquivalent: "")
        extensionStatusItem.target = self
        extensionsMenu.addItem(extensionStatusItem)

        extensionsMenuItem.submenu = extensionsMenu
        mainMenu.addItem(extensionsMenuItem)

        let windowsMenu = NSMenu(title: "Window")
        windowsMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowsMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        let windowsMenuItem = NSMenuItem()
        windowsMenuItem.submenu = windowsMenu
        mainMenu.addItem(windowsMenuItem)

        NSApplication.shared.mainMenu = mainMenu
        NSApplication.shared.windowsMenu = windowsMenu
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

    private static func makeCommandButton(title: String, symbolName: String, description: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
        button.imagePosition = .imageLeading
        button.toolTip = description
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true
        return button
    }

    private func configure(button: NSButton, action: Selector) {
        button.target = self
        button.action = action
    }

    private func makeWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    private func embed(webView: WKWebView) {
        webView.translatesAutoresizingMaskIntoConstraints = false
        webContentView.addSubview(webView)

        activeWebViewConstraints = [
            webView.topAnchor.constraint(equalTo: webContentView.topAnchor),
            webView.leadingAnchor.constraint(equalTo: webContentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webContentView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: webContentView.bottomAnchor)
        ]
        NSLayoutConstraint.activate(activeWebViewConstraints)
    }

    private func switchActiveWebView(to newWebView: WKWebView) {
        guard webView !== newWebView else {
            return
        }

        NSLayoutConstraint.deactivate(activeWebViewConstraints)
        webView.removeFromSuperview()
        webView = newWebView
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        embed(webView: newWebView)
        if #available(macOS 15.4, *), let support = webExtensionSupport as? QuartzWebExtensionSupport {
            support.webViewDidChange(in: self)
        }
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updateController.checkForUpdates()
    }

    @objc private func performUpdateAction(_ sender: Any?) {
        updateController.performPrimaryAction()
    }

    @objc private func cancelUpdate(_ sender: Any?) {
        updateController.cancel()
    }

    @objc private func toggleAutomaticUpdates(_ sender: Any?) {
        updateController.automaticallyChecksForUpdates.toggle()
        automaticUpdatesMenuItem?.state = updateController.automaticallyChecksForUpdates ? .on : .off
    }

    private func openUpdateRelease(_ url: URL) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        if didRestoreSession {
            load(url)
        } else {
            pendingUpdateReleaseURL = url
        }
    }

    private func presentUpdateMessage(title: String, message: String, acknowledgement: @escaping () -> Void) {
        guard let window else { acknowledgement(); return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in acknowledgement() }
    }

    private func updateUpdateControls(_ state: QuartzUpdateState) {
        updateButton.isHidden = state == .idle
        updateButton.isEnabled = false
        cancelUpdateButton.isHidden = !updateController.canCancel
        updateProgressIndicator.isHidden = true
        updateProgressIndicator.stopAnimation(nil)
        checkForUpdatesMenuItem?.isEnabled = state != .checking
        checkForUpdatesMenuItem?.title = state == .checking ? "Checking for Updates…" : "Check for Updates…"

        switch state {
        case .idle:
            break
        case .checking:
            updateButton.title = "Checking…"
            updateButton.toolTip = "Checking for a new Quartz release"
            showUpdateProgress(nil)
        case .available(let version):
            updateButton.title = "Update & Restart"
            updateButton.toolTip = "Install Quartz \(version) and restart. Your current page will be restored."
            updateButton.isEnabled = true
        case .informationOnly(let version, _):
            updateButton.title = "Update Details"
            updateButton.toolTip = "Read the update instructions for Quartz \(version)"
            updateButton.isEnabled = true
        case .downloading(let progress):
            updateButton.title = "Downloading…"
            updateButton.toolTip = "Downloading the Quartz update. You can keep browsing."
            showUpdateProgress(progress)
        case .extracting(let progress):
            updateButton.title = "Preparing…"
            updateButton.toolTip = "Verifying and preparing the update for installation"
            showUpdateProgress(progress)
        case .readyToRestart:
            updateButton.title = "Update & Restart"
            updateButton.toolTip = "Install the prepared Quartz update and restart"
            updateButton.isEnabled = true
        case .installing:
            updateButton.title = "Restarting…"
            updateButton.toolTip = "Installing Quartz. Click to retry restarting if the application has delayed quitting."
            updateButton.isEnabled = true
            showUpdateProgress(nil)
        case .failed(let message):
            updateButton.title = "Retry Update"
            updateButton.toolTip = message
            updateButton.isEnabled = true
        }
        updateButton.setAccessibilityLabel(updateButton.title)
    }

    private func showUpdateProgress(_ progress: Double?) {
        updateProgressIndicator.isHidden = false
        updateProgressIndicator.isIndeterminate = progress == nil
        if let progress {
            updateProgressIndicator.doubleValue = progress
        } else {
            updateProgressIndicator.startAnimation(nil)
        }
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
        loadStartPage()
    }

    @objc private func toggleReaderMode(_ sender: Any?) {
        if isReaderModeActive {
            exitReaderMode()
        } else {
            enterReaderMode()
        }
    }

    @objc private func toggleFacetPanel(_ sender: Any?) {
        setFacetPanelVisible(!isFacetPanelVisible)
    }

    private func setFacetPanelVisible(_ isVisible: Bool) {
        isFacetPanelVisible = isVisible
        facetPanelView.isHidden = !isVisible
        facetPanelWidthConstraint.constant = isVisible ? 380 : 0
        updateFacetControls()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            window.contentView?.layoutSubtreeIfNeeded()
        }

        if isVisible {
            facetPanelView.prepareForDisplay()
            if !hasLoadedFacetModels {
                loadFacetModelOptions()
            }
            facetPanelView.focusPrompt()
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
        panel.title = "Install Chromium Extension"
        panel.message = "Choose an unpacked extension folder, .zip archive, or .crx package."
        panel.prompt = "Install"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = BrowserController.extensionInstallContentTypes()

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        setExtensionInstallControlsEnabled(false)

        support.installExtension(from: url) { [weak self] result in
            guard let self else {
                return
            }

            self.setExtensionInstallControlsEnabled(true)
            self.updateExtensionsButton()

            switch result {
            case .success(let summary):
                self.showExtensionAlert(title: "Extension Installed", message: summary)
            case .failure(let error):
                self.showExtensionAlert(title: "Extension Could Not Be Installed", message: error.localizedDescription)
            }
        }
    }

    @objc private func installExtensionFromChromeWebStore(_ sender: Any?) {
        guard #available(macOS 15.4, *), let support = webExtensionSupport as? QuartzWebExtensionSupport else {
            showExtensionsUnavailableAlert()
            return
        }

        guard let reference = chromeWebStoreExtensionReferenceFromUser() else {
            return
        }

        installChromeWebStoreExtension(reference: reference, support: support)
    }

    @objc private func installCurrentChromeWebStoreExtension(_ sender: Any?) {
        guard #available(macOS 15.4, *), let support = webExtensionSupport as? QuartzWebExtensionSupport else {
            showExtensionsUnavailableAlert()
            return
        }

        guard let reference = currentChromeWebStoreExtensionReference else {
            showExtensionAlert(
                title: "Chrome Web Store Extension Required",
                message: "Open a Chrome Web Store extension listing, then choose Install."
            )
            return
        }

        installChromeWebStoreExtension(reference: reference, support: support)
    }

    @objc private func showExtensionsMenu(_ sender: Any?) {
        guard #available(macOS 15.4, *), let support = webExtensionSupport as? QuartzWebExtensionSupport else {
            showExtensionsUnavailableAlert()
            return
        }

        let anchorView = sender as? NSView ?? extensionsButton
        extensionActionPopupAnchorView = anchorView

        let menu = makeExtensionsMenu(support: support)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchorView.bounds.height + 2), in: anchorView)
    }

    @available(macOS 15.4, *)
    private func makeExtensionsMenu(support: QuartzWebExtensionSupport) -> NSMenu {
        let menu = NSMenu(title: "Extensions")
        let installedExtensions = support.installedExtensions

        if installedExtensions.isEmpty {
            let item = NSMenuItem(title: "No Extensions Installed", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for installedExtension in installedExtensions {
                menu.addItem(extensionMenuItem(for: installedExtension))
            }
        }

        menu.addItem(.separator())
        menu.addItem(makeMenuItem(
            title: "Install This Web Store Extension",
            action: #selector(installCurrentChromeWebStoreExtension(_:)),
            isEnabled: !isInstallingExtension && currentChromeWebStoreExtensionReference != nil
        ))
        menu.addItem(makeMenuItem(
            title: "Install from Chrome Web Store...",
            action: #selector(installExtensionFromChromeWebStore(_:)),
            isEnabled: !isInstallingExtension
        ))
        menu.addItem(makeMenuItem(
            title: "Install Extension from File...",
            action: #selector(installExtension(_:)),
            isEnabled: !isInstallingExtension
        ))
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "Manage Extensions…", action: #selector(showExtensionStatus(_:))))

        return menu
    }

    @available(macOS 15.4, *)
    private func extensionMenuItem(for installedExtension: QuartzInstalledWebExtension) -> NSMenuItem {
        let title = installedExtension.badgeText.isEmpty
            ? installedExtension.displayName
            : "\(installedExtension.displayName) (\(installedExtension.badgeText))"
        let item = makeMenuItem(
            title: title,
            action: #selector(performInstalledExtensionAction(_:)),
            isEnabled: installedExtension.isActionEnabled
        )
        item.representedObject = installedExtension.identifier
        item.toolTip = installedExtension.isActionEnabled
            ? installedExtension.actionLabel
            : "\(installedExtension.displayName) is unavailable on this page."

        if let icon = installedExtension.icon?.copy() as? NSImage {
            icon.size = NSSize(width: 18, height: 18)
            item.image = icon
        }

        return item
    }

    private func makeMenuItem(title: String, action: Selector, isEnabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = isEnabled
        return item
    }

    @objc private func performInstalledExtensionAction(_ sender: Any?) {
        guard #available(macOS 15.4, *), let support = webExtensionSupport as? QuartzWebExtensionSupport else {
            showExtensionsUnavailableAlert()
            return
        }

        guard let item = sender as? NSMenuItem,
              let identifier = item.representedObject as? String
        else {
            return
        }

        extensionActionPopupAnchorView = extensionsButton

        do {
            try support.performAction(forInstalledExtensionWithIdentifier: identifier)
        } catch {
            showExtensionAlert(title: "Extension Could Not Be Used", message: error.localizedDescription)
        }
    }

    @available(macOS 15.4, *)
    private func installChromeWebStoreExtension(reference: String, support: QuartzWebExtensionSupport) {
        setExtensionInstallControlsEnabled(false)

        support.installExtensionFromChromeWebStore(reference) { [weak self] result in
            guard let self else {
                return
            }

            self.setExtensionInstallControlsEnabled(true)
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

        support.showManager()
    }

    private func showExtensionsUnavailableAlert() {
        showExtensionAlert(
            title: "Extensions Unavailable",
            message: "Quartz can install Chromium-format WebExtensions on macOS 15.4 or later."
        )
    }

    private func chromeWebStoreExtensionReferenceFromUser() -> String? {
        let alert = NSAlert()
        alert.messageText = "Install from Chrome Web Store"
        alert.informativeText = "Paste a Chrome Web Store listing URL or extension ID."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")

        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 460, height: 24))
        inputField.placeholderString = "https://chromewebstore.google.com/detail/..."
        alert.accessoryView = inputField

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        let reference = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if reference.isEmpty {
            showExtensionAlert(
                title: "Chrome Web Store URL Required",
                message: "Paste a Chrome Web Store extension URL or extension ID to install."
            )
            return nil
        }

        return reference
    }

    private var currentChromeWebStoreExtensionReference: String? {
        guard webView != nil,
              let url = webView.url ?? sessionURL,
              QuartzChromeWebStoreReference.extensionID(fromURL: url) != nil
        else {
            return nil
        }

        return url.absoluteString
    }

    private static func extensionInstallContentTypes() -> [UTType] {
        var contentTypes: [UTType] = [.folder]

        for filenameExtension in ["zip", "crx"] {
            if let contentType = UTType(filenameExtension: filenameExtension) {
                contentTypes.append(contentType)
            }
        }

        return contentTypes
    }

    private func showExtensionAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func setExtensionInstallControlsEnabled(_ isEnabled: Bool) {
        isInstallingExtension = !isEnabled
        updateExtensionsButton()
        updateExtensionInstallControls()
    }

    private func loadSavedExtensionsThenRestoreSession() {
        addressField.stringValue = "Preparing content filters..."
        adBlockerButton.isEnabled = false
        adBlockerMenuItem?.isEnabled = false

        adBlocker.prepare { [weak self] result in
            guard let self, !self.hasClosedWindow else {
                return
            }

            if case .failure(let error) = result {
                print("Quartz ad blocker unavailable: \(error.localizedDescription)")
                self.adBlocker.disable()
            }

            self.updateAdBlockerControls()
            self.loadSavedExtensionsThenRestoreSessionAfterContentFilters()
        }
    }

    private func loadSavedExtensionsThenRestoreSessionAfterContentFilters() {
        if !restoresSavedSession {
            guard !didRestoreSession else { return }
            didRestoreSession = true
            if let navigate = initialNavigation {
                initialNavigation = nil
                navigate(self)
            } else {
                loadStartPage()
            }
            return
        }
        if #available(macOS 15.4, *), let support = webExtensionSupport as? QuartzWebExtensionSupport {
            addressField.stringValue = "Loading extensions..."
            extensionsButton.isEnabled = false

            support.loadSavedExtensions { [weak self] in
                guard let self, !self.hasClosedWindow else {
                    return
                }

                self.updateExtensionsButton()
                self.restoreSession()
            }
            return
        }

        restoreSession()
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
        extensionsButton.isEnabled = !isInstallingExtension
    }

    private func updateExtensionInstallControls() {
        let canUseExtensions: Bool
        if #available(macOS 15.4, *), webExtensionSupport is QuartzWebExtensionSupport {
            canUseExtensions = true
        } else {
            canUseExtensions = false
        }

        let canInstall = canUseExtensions && !isInstallingExtension
        let currentReference = currentChromeWebStoreExtensionReference
        let canInstallCurrentWebStoreExtension = canInstall && currentReference != nil

        webStoreInstallButton.isHidden = !canUseExtensions || currentReference == nil
        webStoreInstallButton.isEnabled = canInstallCurrentWebStoreExtension
        webStoreInstallButton.toolTip = canInstallCurrentWebStoreExtension
            ? "Install this Chrome Web Store extension"
            : "Open a Chrome Web Store extension listing to install it"

        installCurrentChromeWebStoreExtensionMenuItem?.isEnabled = canInstallCurrentWebStoreExtension
        installExtensionMenuItem?.isEnabled = canInstall
        installChromeWebStoreExtensionMenuItem?.isEnabled = canInstall
    }

    var extensionWebView: WKWebView? {
        webView
    }

    var extensionPopupAnchorView: NSView? {
        extensionActionPopupAnchorView ?? extensionsButton
    }

    var extensionWindow: NSWindow? {
        window
    }

    var extensionURL: URL? {
        displayURLOverride ?? webView?.url
    }

    var extensionPendingURL: URL? {
        pendingNavigationURL
    }

    func loadFromExtension(_ url: URL) {
        load(url)
    }

    func loadSandboxedExtensionPage(_ url: URL, from resourceRootURL: URL, displayURL: URL) {
        guard !hasClosedWindow else { return }
        guard let sandboxURL = Self.sandboxedExtensionPageURL(for: url, in: resourceRootURL) else {
            load(displayURL)
            return
        }

        displayURLOverride = displayURL
        initialNavigation = nil
        didRestoreSession = true
        pendingNavigationURL = displayURL

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(
            QuartzSandboxedExtensionSchemeHandler(resourceRootURL: resourceRootURL),
            forURLScheme: Self.sandboxedExtensionPageScheme
        )

        let sandboxedWebView = makeWebView(configuration: configuration)
        switchActiveWebView(to: sandboxedWebView)

        sessionURL = displayURL
        addressField.stringValue = displayURL.absoluteString
        webView.load(URLRequest(url: sandboxURL))
        updateControls()
    }

    func loadExtensionPage(_ url: URL, using configuration: WKWebViewConfiguration) {
        let extensionWebView = makeWebView(configuration: configuration)
        switchActiveWebView(to: extensionWebView)
        load(url)
    }

    private func load(_ url: URL) {
        guard !hasClosedWindow else { return }
        initialNavigation = nil
        didRestoreSession = true
        pendingNavigationURL = url
        displayURLOverride = nil
        let isStartPageRequest = QuartzStartPage.isStartPageURL(url)

        if (Self.isStandardBrowsingURL(url) || isStartPageRequest), webView !== standardWebView {
            switchActiveWebView(to: standardWebView)
        }

        sessionURL = url
        addressField.stringValue = isStartPageRequest ? "" : url.absoluteString

        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }

        updateControls()
    }

    private func restoreSession() {
        guard !hasClosedWindow, !didRestoreSession else { return }
        didRestoreSession = true
        if let releaseURL = pendingUpdateReleaseURL {
            pendingUpdateReleaseURL = nil
            load(releaseURL)
        } else if let restoredURL = restoredSessionURL() {
            load(restoredURL)
        } else {
            loadStartPage()
        }
    }

    private func loadStartPage() {
        load(QuartzStartPage.url)
    }

    private func saveCurrentSession() {
        if isShowingStartPage || QuartzStartPage.isStartPageURL(webView?.url) {
            sessionDefaults.removeObject(forKey: Self.savedSessionURLKey)
            _ = sessionDefaults.synchronize()
            return
        }

        guard let url = webView?.url ?? sessionURL,
              Self.isRestorableSessionURL(url)
        else {
            return
        }

        sessionDefaults.set(url.absoluteString, forKey: Self.savedSessionURLKey)
        _ = sessionDefaults.synchronize()
    }

    private func restoredSessionURL() -> URL? {
        guard let savedValue = sessionDefaults.string(forKey: Self.savedSessionURLKey),
              let url = URL(string: savedValue),
              Self.isRestorableSessionURL(url)
        else {
            return nil
        }

        return url
    }

    private static func isRestorableSessionURL(_ url: URL) -> Bool {
        QuartzURLRouting.isRestorableSessionURL(url)
    }

    private static func isStandardBrowsingURL(_ url: URL) -> Bool {
        QuartzURLRouting.isStandardBrowsingURL(url)
    }

    private static func sandboxedExtensionPageURL(for pageURL: URL, in resourceRootURL: URL) -> URL? {
        let standardizedPageURL = pageURL.standardizedFileURL
        let standardizedRootURL = resourceRootURL.standardizedFileURL
        let rootPath = standardizedRootURL.path
        guard standardizedPageURL.path.hasPrefix(rootPath + "/") else {
            return nil
        }

        let relativePath = String(standardizedPageURL.path.dropFirst(rootPath.count + 1))
        var components = URLComponents()
        components.scheme = sandboxedExtensionPageScheme
        components.host = "extension"
        components.path = "/" + relativePath
        return components.url
    }

    private func normalizedURL(from text: String) -> URL? {
        QuartzURLRouting.normalizedURL(from: text)
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
        updateExtensionsButton()
        updateExtensionInstallControls()
        updateReaderModeControls()
        updateFacetControls()
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

    private func updateFacetControls() {
        facetButton.state = isFacetPanelVisible ? .on : .off
        facetButton.image = NSImage(
            systemSymbolName: "sparkles",
            accessibilityDescription: "Facet"
        )
        facetButton.toolTip = isFacetPanelVisible ? "Hide Facet" : "Show Facet"
        facetButton.contentTintColor = isFacetPanelVisible ? .controlAccentColor : nil

        facetMenuItem?.state = isFacetPanelVisible ? .on : .off
        facetMenuItem?.title = isFacetPanelVisible ? "Hide Facet" : "Show Facet"
    }

    private func enterReaderMode() {
        guard canUseReaderMode else {
            showReaderModeAlert(message: "Reading Mode is available for loaded web pages and local HTML files.")
            return
        }

        readerButton.isEnabled = false
        readerModeMenuItem?.isEnabled = false

        webView.evaluateJavaScript(QuartzReaderMode.enterScript) { [weak self] result, error in
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

        webView.evaluateJavaScript(QuartzReaderMode.exitScript) { [weak self] _, _ in
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

    func facetPanel(_ panel: FacetPanelView, didSubmit prompt: String, includePageContext: Bool, configuration: FacetConfiguration, apiKey: String) {
        guard activeFacetRequestID == nil else { return }
        let requestID = UUID()
        activeFacetRequestID = requestID
        panel.appendUserMessage(prompt)
        panel.setRunning(true)

        if includePageContext {
            captureFacetPageContext { [weak self] pageContext in
                guard let self,
                      self.activeFacetRequestID == requestID
                else {
                    return
                }

                self.startFacetRun(
                    requestID: requestID,
                    userPrompt: prompt,
                    pageContext: pageContext,
                    configuration: configuration,
                    apiKey: apiKey
                )
            }
        } else {
            startFacetRun(
                requestID: requestID,
                userPrompt: prompt,
                pageContext: nil,
                configuration: configuration,
                apiKey: apiKey
            )
        }
    }

    func facetPanelDidRequestCancel(_ panel: FacetPanelView) {
        activeFacetRequestID = nil
        activeFacetTask?.cancel()
        activeFacetTask = nil
        panel.setRunning(false)
        panel.appendSystemMessage("Stopped.")
    }

    func facetPanelDidRequestClose(_ panel: FacetPanelView) {
        setFacetPanelVisible(false)
    }

    func facetPanelDidRequestModelRefresh(_ panel: FacetPanelView) {
        loadFacetModelOptions()
    }

    private func startFacetRun(
        requestID: UUID,
        userPrompt: String,
        pageContext: FacetPageContext?,
        configuration: FacetConfiguration,
        apiKey: String
    ) {
        let messages = FacetConversation.requestMessages(
            userPrompt: userPrompt,
            pageContext: pageContext,
            previousMessages: facetMessages
        )

        activeFacetTask = Task { [weak self] in
            guard let self else { return }

            do {
                let output = try await self.facetClient.run(
                    messages: messages,
                    configuration: configuration,
                    apiKey: apiKey
                )
                guard !Task.isCancelled, self.activeFacetRequestID == requestID else { return }
                // Keep completed exchanges only; page extracts belong only to the request that enabled them.
                self.facetMessages.append(FacetChatMessage(role: "user", content: userPrompt))
                self.facetMessages.append(FacetChatMessage(role: "assistant", content: output))
                self.facetMessages = Array(self.facetMessages.suffix(8))
                self.facetPanelView.appendAgentMessage(output)
            } catch {
                guard !Task.isCancelled, self.activeFacetRequestID == requestID else { return }
                self.facetPanelView.appendSystemMessage(error.localizedDescription)
            }

            self.activeFacetRequestID = nil
            self.activeFacetTask = nil
            self.facetPanelView.setRunning(false)
        }
    }

    private func loadFacetModelOptions() {
        facetModelOptionsTask?.cancel()
        facetPanelView.setModelsLoading(true)
        facetModelOptionsTask = Task { [weak self] in
            guard let self else { return }

            do {
                let options = try await self.facetClient.loadModelOptions()
                guard !Task.isCancelled else { return }
                self.facetPanelView.setModelOptions(options)
                self.hasLoadedFacetModels = true
            } catch {
                guard !Task.isCancelled else { return }
                self.facetPanelView.appendSystemMessage(
                    "Could not refresh OpenRouter models. Your current selection is still available. Use the refresh button to try again.\n\(error.localizedDescription)"
                )
            }
            self.facetPanelView.setModelsLoading(false)
            self.facetModelOptionsTask = nil
        }
    }

    private func captureFacetPageContext(completion: @escaping (FacetPageContext?) -> Void) {
        let fallbackContext = currentFacetPageContextFallback()
        guard webView != nil else {
            completion(fallbackContext)
            return
        }

        webView.evaluateJavaScript(Self.facetPageContextScript) { result, _ in
            guard let dictionary = result as? [String: Any] else {
                completion(fallbackContext)
                return
            }

            let context = FacetPageContext(
                url: Self.facetStringValue("url", in: dictionary, fallback: fallbackContext?.url ?? ""),
                title: Self.facetStringValue("title", in: dictionary, fallback: fallbackContext?.title ?? ""),
                selectedText: Self.facetStringValue("selectedText", in: dictionary),
                description: Self.facetStringValue("description", in: dictionary),
                textExcerpt: Self.facetStringValue("textExcerpt", in: dictionary)
            )
            completion(context.hasUsefulContent ? context : fallbackContext)
        }
    }

    private func currentFacetPageContextFallback() -> FacetPageContext? {
        let displayURL = displayURLOverride ?? webView?.url ?? sessionURL
        let urlText = displayURL?.absoluteString ?? ""
        let title = webView?.title ?? ""
        let context = FacetPageContext(
            url: urlText,
            title: title,
            selectedText: "",
            description: "",
            textExcerpt: ""
        )
        return context.hasUsefulContent ? context : nil
    }

    private static func facetStringValue(_ key: String, in dictionary: [String: Any], fallback: String = "") -> String {
        guard let value = dictionary[key] as? String else {
            return fallback
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        updateControls()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if QuartzStartPage.isActionURL(url) {
            decisionHandler(.cancel)

            guard webView === self.webView,
                  webView === standardWebView,
                  let action = QuartzStartPage.authorizedAction(
                      for: url,
                      sourcePageURL: navigationAction.sourceFrame.request.url,
                      sourceIsMainFrame: navigationAction.sourceFrame.isMainFrame
                  )
            else {
                return
            }

            handleStartPageAction(action)
            return
        }

        if webView === self.webView, navigationAction.targetFrame?.isMainFrame == true, !navigationAction.shouldPerformDownload {
            pendingNavigationURL = displayURLOverride ?? url
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        let shouldDownload = QuartzDownloadPolicy.shouldDownload(
            navigationResponse.response, canShowMIMEType: navigationResponse.canShowMIMEType
        )
        decisionHandler(shouldDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        if webView === self.webView { pendingNavigationURL = nil }
        downloadCoordinator.begin(download)
        updateControls()
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        if webView === self.webView { pendingNavigationURL = nil }
        downloadCoordinator.begin(download)
        updateControls()
    }

    private func handleStartPageAction(_ action: QuartzStartPageAction) {
        switch action {
        case .navigate(let text):
            guard let url = normalizedURL(from: text) else {
                window.makeFirstResponder(addressField)
                return
            }
            load(url)
        case .showFacet:
            setFacetPanelVisible(true)
        case .showExtensions:
            showExtensionsMenu(extensionsButton)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if webView === self.webView { pendingNavigationURL = nil }
        isShowingStartPage = webView === standardWebView
            && QuartzStartPage.isStartPageURL(webView.url)
        if isShowingStartPage {
            sessionURL = QuartzStartPage.url
            addressField.stringValue = ""
        }

        if isReaderModeActive {
            isReaderModeActive = false
        }

        updateControls()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, !hasClosedWindow else { return }
        pendingNavigationURL = nil
        if let url = webView.url {
            let displayURL = displayURLOverride ?? url
            isShowingStartPage = QuartzStartPage.isStartPageURL(displayURL)
            sessionURL = isShowingStartPage ? QuartzStartPage.url : displayURL
            addressField.stringValue = isShowingStartPage ? "" : displayURL.absoluteString
        }
        window.title = isShowingStartPage
            ? "Quartz"
            : (webView.title?.isEmpty == false ? "\(webView.title!) - Quartz" : "Quartz")
        updateControls()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, !hasClosedWindow else { return }
        pendingNavigationURL = nil
        showLoadError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, !hasClosedWindow else { return }
        pendingNavigationURL = nil
        showLoadError(error)
    }

    private func showLoadError(_ error: Error) {
        let navigationError = error as NSError
        // WebKit cancels navigation when handing a response to a download.
        if (navigationError.domain == NSURLErrorDomain && navigationError.code == NSURLErrorCancelled)
            || (navigationError.domain == "WebKitErrorDomain" && navigationError.code == 102) {
            updateControls()
            return
        }
        let alert = NSAlert(error: error)
        alert.messageText = "Quartz could not load this page."
        alert.informativeText = error.localizedDescription
        print("Quartz load error: \(error)")
        alert.runModal()
        updateControls()
    }

    private static let facetPageContextScript = #"""
(() => {
    const cleanText = (value) => (value || "").replace(/\s+/g, " ").trim();
    const selectedText = cleanText(window.getSelection?.().toString() || "");
    const description = cleanText(
        document.querySelector("meta[name='description']")?.content ||
        document.querySelector("meta[property='og:description']")?.content ||
        ""
    );
    const visibleText = cleanText(document.body?.innerText || "");

    return {
        url: location.href,
        title: cleanText(document.title || ""),
        selectedText,
        description,
        textExcerpt: visibleText.slice(0, 12000)
    };
})();
"""#


}
