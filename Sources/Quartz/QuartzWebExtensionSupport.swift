import AppKit
@preconcurrency import WebKit

@available(macOS 15.4, *)
@MainActor
final class QuartzWebExtensionSupport: NSObject {
    let controller: WKWebExtensionController

    private weak var browser: BrowserController?
    private var extensionContextsByPath = [String: WKWebExtensionContext]()
    private let savedExtensionPathsKey = "QuartzInstalledExtensionPaths"

    var installedExtensionNames: [String] {
        extensionContextsByPath.values
            .map { context in
                let extensionName = context.webExtension.displayName ?? context.webExtension.displayShortName
                return extensionName ?? context.webExtension.version.map { "Extension \($0)" } ?? "Unnamed Extension"
            }
            .sorted()
    }

    init(browser: BrowserController, webViewConfiguration: WKWebViewConfiguration) {
        self.browser = browser

        let configuration = WKWebExtensionController.Configuration.default()
        configuration.webViewConfiguration = webViewConfiguration
        configuration.defaultWebsiteDataStore = webViewConfiguration.websiteDataStore

        controller = WKWebExtensionController(configuration: configuration)

        super.init()

        controller.delegate = self
    }

    func loadSavedExtensions(completion: @escaping () -> Void) {
        Task { @MainActor in
            for path in savedExtensionPaths() {
                do {
                    _ = try await loadExtension(at: URL(fileURLWithPath: path), shouldSave: false)
                } catch {
                    print("Quartz extension unavailable at \(path): \(error.localizedDescription)")
                }
            }

            completion()
        }
    }

    func installExtension(from url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        Task { @MainActor in
            do {
                let summary = try await loadExtension(at: url, shouldSave: true)
                completion(.success(summary))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func loadExtension(at url: URL, shouldSave: Bool) async throws -> String {
        let standardizedURL = url.standardizedFileURL
        let path = standardizedURL.path

        if let existingContext = extensionContextsByPath[path] {
            return summary(for: existingContext, wasAlreadyLoaded: true)
        }

        let webExtension = try await WKWebExtension(resourceBaseURL: standardizedURL)
        let context = WKWebExtensionContext(for: webExtension)

        grantInstallTimePermissions(to: context)

        try controller.load(context)
        extensionContextsByPath[path] = context

        if shouldSave {
            saveExtensionPath(path)
        }

        return summary(for: context, wasAlreadyLoaded: false)
    }

    private func grantInstallTimePermissions(to context: WKWebExtensionContext) {
        for permission in context.webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }

        for pattern in context.webExtension.requestedPermissionMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
    }

    private func summary(for context: WKWebExtensionContext, wasAlreadyLoaded: Bool) -> String {
        let name = context.webExtension.displayName ?? context.webExtension.displayShortName ?? "Extension"
        let versionText = context.webExtension.version.map { " \($0)" } ?? ""
        let stateText = wasAlreadyLoaded ? "is already installed" : "was installed"
        return "\(name)\(versionText) \(stateText)."
    }

    private func savedExtensionPaths() -> [String] {
        UserDefaults.standard.stringArray(forKey: savedExtensionPathsKey) ?? []
    }

    private func saveExtensionPath(_ path: String) {
        var paths = savedExtensionPaths()
        guard paths.contains(path) == false else {
            return
        }

        paths.append(path)
        UserDefaults.standard.set(paths, forKey: savedExtensionPathsKey)
    }
}

@available(macOS 15.4, *)
extension QuartzWebExtensionSupport: WKWebExtensionControllerDelegate {
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        [self]
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        self
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void
    ) {
        if let url = configuration.url {
            browser?.loadFromExtension(url)
        }

        completionHandler(self, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        if let url = extensionContext.optionsPageURL {
            browser?.loadFromExtension(url)
            completionHandler(nil)
        } else {
            completionHandler(QuartzWebExtensionSupportError.missingOptionsPage)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        completionHandler(permissions, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        completionHandler(matchPatterns, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let popover = action.popupPopover, let button = browser?.extensionWebView else {
            completionHandler(QuartzWebExtensionSupportError.missingPopup)
            return
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        completionHandler(nil)
    }
}

@available(macOS 15.4, *)
extension QuartzWebExtensionSupport: WKWebExtensionWindow {
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        [self]
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        self
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        browser?.extensionWindow?.frame ?? .null
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        browser?.extensionWindow?.screen?.frame ?? .null
    }
}

@available(macOS 15.4, *)
extension QuartzWebExtensionSupport: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        self
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        0
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        browser?.extensionWebView
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        browser?.extensionWebView?.url
    }

    func pendingURL(for context: WKWebExtensionContext) -> URL? {
        nil
    }
}

private enum QuartzWebExtensionSupportError: LocalizedError {
    case missingOptionsPage
    case missingPopup

    var errorDescription: String? {
        switch self {
        case .missingOptionsPage:
            "The extension does not provide an options page."
        case .missingPopup:
            "The extension does not provide a popup that Quartz can display."
        }
    }
}
