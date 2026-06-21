import AppKit
@preconcurrency import WebKit

@available(macOS 15.4, *)
@MainActor
final class QuartzWebExtensionSupport: NSObject {
    let controller: WKWebExtensionController

    private weak var browser: BrowserController?
    private var extensionContextsByPath = [String: WKWebExtensionContext]()
    private let savedExtensionPathsKey = "QuartzInstalledExtensionPaths"
    private let appSupportDirectoryName = "Quartz"
    private let installedPackagesDirectoryName = "Extensions"
    private let extensionLoadCacheDirectoryName = "ExtensionLoadCache"
    private let quartzExtensionPackageExtension = "qrx"

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
                let installedPackageURL = try installPackage(from: url)
                let summary = try await loadExtension(at: installedPackageURL, shouldSave: true)
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

        let resourceBaseURL = try resourceBaseURL(for: standardizedURL)
        let webExtension = try await WKWebExtension(resourceBaseURL: resourceBaseURL)
        let context = WKWebExtensionContext(for: webExtension)

        grantInstallTimePermissions(to: context)

        try controller.load(context)
        extensionContextsByPath[path] = context

        if shouldSave {
            saveExtensionPath(path)
        }

        return summary(for: context, wasAlreadyLoaded: false)
    }

    private func installPackage(from sourceURL: URL) throws -> URL {
        let standardizedSourceURL = sourceURL.standardizedFileURL

        guard isQuartzExtensionPackage(standardizedSourceURL) else {
            throw QuartzWebExtensionSupportError.unsupportedPackage
        }

        guard FileManager.default.fileExists(atPath: standardizedSourceURL.path) else {
            throw QuartzWebExtensionSupportError.missingPackage(standardizedSourceURL.lastPathComponent)
        }

        let packagesDirectoryURL = try installedPackagesDirectory()
        let packageName = standardizedSourceURL.lastPathComponent
        let destinationURL = packagesDirectoryURL.appendingPathComponent(packageName, isDirectory: false)
        let standardizedDestinationURL = destinationURL.standardizedFileURL

        if extensionContextsByPath[standardizedDestinationURL.path] != nil {
            return standardizedDestinationURL
        }

        if standardizedSourceURL.path == standardizedDestinationURL.path {
            return standardizedDestinationURL
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.copyItem(at: standardizedSourceURL, to: destinationURL)
        return standardizedDestinationURL
    }

    private func resourceBaseURL(for url: URL) throws -> URL {
        guard isQuartzExtensionPackage(url) else {
            return url
        }

        return try mirroredZIPArchive(for: url)
    }

    private func mirroredZIPArchive(for packageURL: URL) throws -> URL {
        let cacheDirectoryURL = try extensionLoadCacheDirectory()
        let packageBaseName = packageURL.deletingPathExtension().lastPathComponent
        let packageIdentifier = stableIdentifier(for: packageURL.path)
        let archiveURL = cacheDirectoryURL
            .appendingPathComponent("\(packageBaseName)-\(packageIdentifier)", isDirectory: false)
            .appendingPathExtension("zip")

        if FileManager.default.fileExists(atPath: archiveURL.path) {
            try FileManager.default.removeItem(at: archiveURL)
        }

        try FileManager.default.copyItem(at: packageURL, to: archiveURL)
        return archiveURL.standardizedFileURL
    }

    private func installedPackagesDirectory() throws -> URL {
        let appSupportURL = try quartzStorageDirectory(
            searchPathDirectory: .applicationSupportDirectory,
            unavailableError: .applicationSupportUnavailable
        )
        let directoryURL = appSupportURL.appendingPathComponent(installedPackagesDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func extensionLoadCacheDirectory() throws -> URL {
        let cacheURL = try quartzStorageDirectory(
            searchPathDirectory: .cachesDirectory,
            unavailableError: .cacheUnavailable
        )
        let directoryURL = cacheURL.appendingPathComponent(extensionLoadCacheDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func quartzStorageDirectory(
        searchPathDirectory: FileManager.SearchPathDirectory,
        unavailableError: QuartzWebExtensionSupportError
    ) throws -> URL {
        guard let baseURL = FileManager.default.urls(for: searchPathDirectory, in: .userDomainMask).first else {
            throw unavailableError
        }

        let directoryURL = baseURL.appendingPathComponent(appSupportDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func isQuartzExtensionPackage(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == quartzExtensionPackageExtension
    }

    private func stableIdentifier(for text: String) -> String {
        var hash: UInt64 = 5381

        for byte in text.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }

        return String(hash, radix: 16)
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
    case unsupportedPackage
    case missingPackage(String)
    case applicationSupportUnavailable
    case cacheUnavailable

    var errorDescription: String? {
        switch self {
        case .missingOptionsPage:
            "The extension does not provide an options page."
        case .missingPopup:
            "The extension does not provide a popup that Quartz can display."
        case .unsupportedPackage:
            "Choose a Quartz extension package with the .qrx file extension."
        case .missingPackage(let packageName):
            "Quartz could not find \(packageName)."
        case .applicationSupportUnavailable:
            "Quartz could not access Application Support to install the extension."
        case .cacheUnavailable:
            "Quartz could not prepare the extension package for WebKit."
        }
    }
}
