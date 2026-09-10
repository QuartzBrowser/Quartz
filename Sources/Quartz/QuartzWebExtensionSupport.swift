import AppKit
@preconcurrency import WebKit

@available(macOS 15.4, *)
struct QuartzInstalledWebExtension {
    let identifier: String
    let displayName: String
    let actionLabel: String
    let badgeText: String
    let icon: NSImage?
    let isActionEnabled: Bool
    let isEnabled: Bool
    let status: String
}

@available(macOS 15.4, *)
@MainActor
final class QuartzWebExtensionSupport: NSObject {
    let controller: WKWebExtensionController

    private weak var initialBrowser: BrowserController?
    private(set) var browserTabs = [QuartzWebExtensionBrowserTab]()
    private weak var presentedPopupWebView: WKWebView?
    private weak var presentedPopupBrowser: BrowserController?
    private var reportedFocus = QuartzBrowserFocusChange()
    private var focusUpdateScheduled = false
    private var browser: BrowserController? {
        focusedTab?.browser
            ?? browserTabs.first(where: { $0.browser === BrowserController.lastFocusedBrowser })?.browser
            ?? browserTabs.first?.browser
            ?? initialBrowser
    }
    var focusedTab: QuartzWebExtensionBrowserTab? {
        let app = NSApplication.shared
        let focusedWindow = QuartzBrowserFocus.window(
            applicationIsActive: app.isActive,
            keyWindow: app.keyWindow,
            mainWindow: app.mainWindow,
            browserWindows: browserTabs.compactMap { $0.browser?.extensionWindow },
            popupWindow: presentedPopupWebView?.window,
            popupOwner: presentedPopupBrowser?.extensionWindow
        )
        guard let focusedWindow else { return nil }
        return browserTabs.first { $0.browser?.extensionWindow === focusedWindow }
    }
    private var actionTab: QuartzWebExtensionBrowserTab? {
        browserTabs.first { $0.browser === browser }
    }
    private var extensionContextsByPath = [String: WKWebExtensionContext]()
    private let registry: QuartzExtensionRegistry
    private let storageDirectory: URL?
    private let permissionPrompt: @MainActor (String, Set<String>, Set<String>, Bool) -> Bool
    private var loadErrorsByPath = [String: String]()
    private var loadingPaths = Set<String>()
    private var manager: QuartzExtensionManagerController?
    var onChange: (() -> Void)?
    private let appSupportDirectoryName = "Quartz"
    private let installedExtensionsDirectoryName = "Extensions"
    private let chromeWebStoreDownloadDirectoryName = "ChromeWebStoreDownloads"
    private let sandboxedExtensionPagesDirectoryName = "SandboxedExtensionPages"
    private var chromeWebStoreUpdateURL: URL {
        guard let url = URL(string: "https://clients2.google.com/service/update2/crx") else {
            fatalError("Invalid Chrome Web Store update URL constant.")
        }
        return url
    }

    var installedExtensionNames: [String] { installedExtensions.map(\.displayName) }

    var installedExtensions: [QuartzInstalledWebExtension] {
        registry.read().map { record in
            let context = extensionContextsByPath[record.path]
            let action = context?.action(for: actionTab)
            let name = context.map { displayName(for: $0) } ?? record.displayName
            return QuartzInstalledWebExtension(
                identifier: record.path,
                displayName: name,
                actionLabel: nonEmpty(action?.label) ?? name,
                badgeText: action?.badgeText ?? "",
                icon: action?.icon(for: NSSize(width: 18, height: 18)),
                isActionEnabled: action?.isEnabled == true,
                isEnabled: record.isEnabled,
                status: loadErrorsByPath[record.path] ?? (context != nil ? "Enabled" : record.isEnabled ? "Not loaded" : "Disabled")
            )
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func showManager() {
        if manager == nil { manager = QuartzExtensionManagerController(support: self) }
        manager?.reload()
        manager?.showWindow(nil)
        manager?.window?.makeKeyAndOrderFront(nil)
    }

    func setEnabled(_ enabled: Bool, identifier: String, completion: @escaping (Result<Void, Error>) -> Void) {
        Task { @MainActor in
            do {
                guard !loadingPaths.contains(identifier) else { throw QuartzWebExtensionSupportError.operationInProgress }
                guard var record = registry.read().first(where: { $0.path == identifier }) else {
                    throw QuartzWebExtensionSupportError.missingInstalledExtension
                }
                if enabled {
                    _ = try await loadExtension(at: URL(fileURLWithPath: identifier), shouldSave: false)
                } else if let context = extensionContextsByPath[identifier] {
                    try controller.unload(context)
                    extensionContextsByPath.removeValue(forKey: identifier)
                }
                // Loading may have updated the remembered permission choices.
                record = registry.read().first(where: { $0.path == identifier }) ?? record
                record.isEnabled = enabled
                saveRecord(record)
                loadErrorsByPath.removeValue(forKey: identifier)
                extensionsDidChange()
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func uninstall(identifier: String) throws {
        guard !loadingPaths.contains(identifier) else { throw QuartzWebExtensionSupportError.operationInProgress }
        guard var record = registry.read().first(where: { $0.path == identifier }) else {
            throw QuartzWebExtensionSupportError.missingInstalledExtension
        }
        if let context = extensionContextsByPath[identifier] {
            try controller.unload(context)
            extensionContextsByPath.removeValue(forKey: identifier)
        }
        record.isEnabled = false
        saveRecord(record)
        defer { extensionsDidChange() }
        if let ownedURL = QuartzExtensionRegistry.ownedRemovalURL(for: identifier, storageDirectory: try installedExtensionsDirectory()),
           FileManager.default.fileExists(atPath: ownedURL.path) {
            try FileManager.default.removeItem(at: ownedURL)
        }
        registry.write(registry.read().filter { $0.path != identifier })
        loadErrorsByPath.removeValue(forKey: identifier)
    }

    private func extensionsDidChange() {
        manager?.reload()
        onChange?()
    }

    init(
        browser: BrowserController,
        webViewConfiguration: WKWebViewConfiguration,
        defaults: UserDefaults = .standard,
        storageDirectory: URL? = nil,
        permissionPrompt: @escaping @MainActor (String, Set<String>, Set<String>, Bool) -> Bool = QuartzExtensionPermissionPrompt.request
    ) {
        self.initialBrowser = browser
        self.registry = QuartzExtensionRegistry(defaults: defaults)
        self.storageDirectory = storageDirectory
        self.permissionPrompt = permissionPrompt

        let configuration = webViewConfiguration.websiteDataStore.isPersistent
            ? WKWebExtensionController.Configuration.default()
            : WKWebExtensionController.Configuration.nonPersistent()
        configuration.webViewConfiguration = webViewConfiguration
        configuration.defaultWebsiteDataStore = webViewConfiguration.websiteDataStore

        controller = WKWebExtensionController(configuration: configuration)

        super.init()

        controller.delegate = self
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(appKitFocusDidChange(_:)), name: name, object: nil)
        }
    }

    func registerBrowser(_ browser: BrowserController) {
        guard !browserTabs.contains(where: { $0.browser === browser }) else { return }
        let tab = QuartzWebExtensionBrowserTab(browser: browser, support: self)
        browserTabs.append(tab)
        // Opening/closing a window also reports its contained tabs to WebKit.
        controller.didOpenWindow(tab)
        focusDidChange(force: true)
    }

    func unregisterBrowser(_ browser: BrowserController) {
        guard let tab = browserTabs.first(where: { $0.browser === browser }) else { return }
        browserTabs.removeAll { $0 === tab }
        controller.didCloseWindow(tab)
        tab.didClose()
        focusDidChange(force: true)
    }

    @objc private func appKitFocusDidChange(_ notification: Notification) {
        // A resign-key notification arrives before the new key panel is assigned.
        // Wait until the transfer settles so a popup click never reports nil focus.
        guard !focusUpdateScheduled else { return }
        focusUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusUpdateScheduled = false
            self.focusDidChange()
        }
    }

    func focusDidChange(force: Bool = false) {
        let tab = focusedTab
        let didChange = reportedFocus.update(window: tab?.browser?.extensionWindow)
        if force || didChange { controller.didFocusWindow(tab) }
    }

    func webViewDidChange(in browser: BrowserController) {
        browserTabs.first { $0.browser === browser }?.observeWebView()
    }

    func tabDidChange(_ tab: QuartzWebExtensionBrowserTab, properties: WKWebExtension.TabChangedProperties) {
        guard browserTabs.contains(where: { $0 === tab }) else { return }
        controller.didChangeTabProperties(properties, for: tab)
    }

    @discardableResult
    func openBrowserTab(url: URL?, context: WKWebExtensionContext, focused: Bool) -> QuartzWebExtensionBrowserTab? {
        guard let source = browser else { return nil }
        let newBrowser = source.openBrowserWindow(focused: focused, initialURL: url) { [weak self] target in
            guard let self else { return }
            self.openURLFromExtension(url ?? QuartzStartPage.url, context: context, in: target)
        }
        return browserTabs.first { $0.browser === newBrowser }
    }

    func loadSavedExtensions(completion: @escaping () -> Void) {
        Task { @MainActor in
            for record in registry.read() where record.isEnabled {
                do {
                    _ = try await loadExtension(at: URL(fileURLWithPath: record.path), shouldSave: false)
                } catch {
                    loadErrorsByPath[record.path] = error.localizedDescription
                    var disabledRecord = record
                    disabledRecord.isEnabled = false
                    saveRecord(disabledRecord)
                    print("Quartz extension unavailable at \(record.path): \(error.localizedDescription)")
                }
            }
            extensionsDidChange()
            completion()
        }
    }

    func installExtension(from url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        Task { @MainActor in
            do {
                completion(.success(try await installAndLoad(from: url)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func installExtensionFromChromeWebStore(_ reference: String, completion: @escaping (Result<String, Error>) -> Void) {
        Task { @MainActor in
            do {
                guard let extensionID = QuartzChromeWebStoreReference.extensionID(from: reference) else {
                    throw QuartzWebExtensionSupportError.invalidChromeWebStoreReference
                }
                let downloadedPackageURL = try await downloadChromeWebStoreExtension(withID: extensionID)
                defer { try? FileManager.default.removeItem(at: downloadedPackageURL) }
                completion(.success(try await installAndLoad(from: downloadedPackageURL)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func installAndLoad(from sourceURL: URL) async throws -> String {
        let installedURL = try installExtensionSource(from: sourceURL)
        do {
            return try await loadExtension(at: installedURL, shouldSave: true)
        } catch {
            // A new installation always receives a unique owned copy. Canceling leaves the original untouched.
            if let ownedURL = QuartzExtensionRegistry.ownedRemovalURL(for: installedURL.path, storageDirectory: try installedExtensionsDirectory()) {
                try? FileManager.default.removeItem(at: ownedURL)
            }
            throw error
        }
    }

    func performAction(forInstalledExtensionWithIdentifier identifier: String) throws {
        guard let context = extensionContextsByPath[identifier] else {
            throw QuartzWebExtensionSupportError.missingInstalledExtension
        }

        let displayName = displayName(for: context)
        guard let action = context.action(for: actionTab) else {
            throw QuartzWebExtensionSupportError.missingAction(displayName)
        }

        guard action.isEnabled else {
            throw QuartzWebExtensionSupportError.disabledAction(displayName)
        }

        context.performAction(for: actionTab)
    }

    private func loadExtension(at url: URL, shouldSave: Bool) async throws -> String {
        let standardizedURL = url.standardizedFileURL
        let path = standardizedURL.path

        if let existingContext = extensionContextsByPath[path] {
            return summary(for: existingContext, wasAlreadyLoaded: true)
        }

        guard loadingPaths.insert(path).inserted else { throw QuartzWebExtensionSupportError.operationInProgress }
        defer { loadingPaths.remove(path) }
        let resourceBaseURL = try resourceBaseURL(for: standardizedURL)
        let webExtension = try await WKWebExtension(resourceBaseURL: resourceBaseURL)
        let context = WKWebExtensionContext(for: webExtension)

        var record = registry.read().first { $0.path == path }
            ?? QuartzExtensionRecord(path: path, displayName: displayName(for: context), isEnabled: true)
        let contextID = record.contextIdentifier.flatMap(UUID.init(uuidString:)) ?? UUID()
        record.contextIdentifier = contextID.uuidString.lowercased()
        context.uniqueIdentifier = contextID.uuidString.lowercased()
        context.baseURL = URL(string: "webkit-extension://\(contextID.uuidString.lowercased())")!
        try grantInstallTimePermissions(to: context, record: &record)

        try controller.load(context)
        extensionContextsByPath[path] = context

        record.displayName = displayName(for: context)
        if shouldSave { record.isEnabled = true }
        saveRecord(record)
        loadErrorsByPath.removeValue(forKey: path)
        extensionsDidChange()
        return summary(for: context, wasAlreadyLoaded: false)
    }

    private func installExtensionSource(from sourceURL: URL) throws -> URL {
        let standardizedSourceURL = sourceURL.standardizedFileURL
        var isDirectory = ObjCBool(false)

        guard FileManager.default.fileExists(atPath: standardizedSourceURL.path, isDirectory: &isDirectory) else {
            throw QuartzWebExtensionSupportError.missingExtensionSource(standardizedSourceURL.lastPathComponent)
        }

        if isDirectory.boolValue {
            let extensionRootURL = try extensionRootDirectory(for: standardizedSourceURL)
            return try installUnpackedExtension(from: extensionRootURL)
        }

        switch standardizedSourceURL.pathExtension.lowercased() {
        case "zip":
            return try installArchive(from: standardizedSourceURL)
        case "crx":
            return try installChromiumPackage(from: standardizedSourceURL)
        default:
            throw QuartzWebExtensionSupportError.unsupportedExtensionSource
        }
    }

    private func downloadChromeWebStoreExtension(withID extensionID: String) async throws -> URL {
        let downloadURL = try chromeWebStoreDownloadURL(for: extensionID)
        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 90

        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            throw QuartzWebExtensionSupportError.chromeWebStoreDownloadFailed(statusCode)
        }

        let downloadDirectoryURL = try chromeWebStoreDownloadDirectory()
        let destinationURL = downloadDirectoryURL.appendingPathComponent("\(UUID().uuidString)-\(extensionID).crx", isDirectory: false)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL.standardizedFileURL
    }

    private func chromeWebStoreDownloadURL(for extensionID: String) throws -> URL {
        guard var components = URLComponents(url: chromeWebStoreUpdateURL, resolvingAgainstBaseURL: false) else {
            throw QuartzWebExtensionSupportError.invalidChromeWebStoreReference
        }

        components.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: "2147483647"),
            URLQueryItem(name: "acceptformat", value: "crx2,crx3"),
            URLQueryItem(name: "x", value: "id=\(extensionID)&uc")
        ]

        guard let url = components.url else {
            throw QuartzWebExtensionSupportError.invalidChromeWebStoreReference
        }

        return url
    }

    private func installUnpackedExtension(from sourceURL: URL) throws -> URL {
        let destinationURL = try installedDestinationURL(for: sourceURL, isDirectory: true)
        return try copyExtensionItem(from: sourceURL, to: destinationURL)
    }

    private func installArchive(from sourceURL: URL) throws -> URL {
        let destinationURL = try installedDestinationURL(for: sourceURL, isDirectory: false)
        return try copyExtensionItem(from: sourceURL, to: destinationURL)
    }

    private func installChromiumPackage(from sourceURL: URL) throws -> URL {
        let archiveData = try zipPayload(fromChromiumPackageAt: sourceURL)
        let destinationURL = try installedDestinationURL(
            for: sourceURL,
            replacingPathExtensionWith: "zip",
            isDirectory: false
        )
        let standardizedDestinationURL = destinationURL.standardizedFileURL

        if extensionContextsByPath[standardizedDestinationURL.path] != nil {
            return standardizedDestinationURL
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try archiveData.write(to: destinationURL, options: .atomic)
        return standardizedDestinationURL
    }

    private func resourceBaseURL(for url: URL) throws -> URL {
        var isDirectory = ObjCBool(false)

        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw QuartzWebExtensionSupportError.missingExtensionSource(url.lastPathComponent)
        }

        if isDirectory.boolValue {
            return try extensionRootDirectory(for: url)
        }

        guard url.pathExtension.lowercased() == "zip" else {
            throw QuartzWebExtensionSupportError.unsupportedExtensionSource
        }

        return url
    }

    private func installedDestinationURL(
        for sourceURL: URL,
        replacingPathExtensionWith pathExtension: String? = nil,
        isDirectory: Bool
    ) throws -> URL {
        let directoryURL = try installedExtensionsDirectory()
        let destinationName = pathExtension.map { "\(sourceURL.deletingPathExtension().lastPathComponent).\($0)" }
            ?? sourceURL.lastPathComponent

        return directoryURL.appendingPathComponent("\(UUID().uuidString)-\(destinationName)", isDirectory: isDirectory)
    }

    private func copyExtensionItem(from sourceURL: URL, to destinationURL: URL) throws -> URL {
        let standardizedSourceURL = sourceURL.standardizedFileURL
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

    private func extensionRootDirectory(for directoryURL: URL) throws -> URL {
        if hasManifest(in: directoryURL) {
            return directoryURL.standardizedFileURL
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let childDirectories = contents.filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == true
        }

        if childDirectories.count == 1, hasManifest(in: childDirectories[0]) {
            return childDirectories[0].standardizedFileURL
        }

        throw QuartzWebExtensionSupportError.missingManifest(directoryURL.lastPathComponent)
    }

    private func hasManifest(in directoryURL: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        let manifestURL = directoryURL.appendingPathComponent("manifest.json", isDirectory: false)
        let exists = FileManager.default.fileExists(atPath: manifestURL.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue == false
    }

    private func zipPayload(fromChromiumPackageAt packageURL: URL) throws -> Data {
        let data = try Data(contentsOf: packageURL)
        let bytes = [UInt8](data)

        guard bytes.starts(with: [0x43, 0x72, 0x32, 0x34]) else {
            throw QuartzWebExtensionSupportError.invalidChromiumPackage
        }

        let version = try littleEndianUInt32(in: bytes, at: 4)
        let zipOffset: Int

        switch version {
        case 2:
            let publicKeyLength = try littleEndianUInt32(in: bytes, at: 8)
            let signatureLength = try littleEndianUInt32(in: bytes, at: 12)
            zipOffset = 16 + Int(publicKeyLength) + Int(signatureLength)
        case 3:
            let headerLength = try littleEndianUInt32(in: bytes, at: 8)
            zipOffset = 12 + Int(headerLength)
        default:
            throw QuartzWebExtensionSupportError.invalidChromiumPackage
        }

        guard zipOffset + 2 <= bytes.count, bytes[zipOffset] == 0x50, bytes[zipOffset + 1] == 0x4b else {
            throw QuartzWebExtensionSupportError.invalidChromiumPackage
        }

        return data.subdata(in: zipOffset..<data.count)
    }

    private func littleEndianUInt32(in bytes: [UInt8], at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else {
            throw QuartzWebExtensionSupportError.invalidChromiumPackage
        }

        let valueBytes = Array(bytes[offset..<(offset + 4)])
        return valueBytes.withUnsafeBytes { rawBuffer in
            let rawValue =
                UInt32(rawBuffer.load(fromByteOffset: 0, as: UInt8.self))
                | (UInt32(rawBuffer.load(fromByteOffset: 1, as: UInt8.self)) << 8)
                | (UInt32(rawBuffer.load(fromByteOffset: 2, as: UInt8.self)) << 16)
                | (UInt32(rawBuffer.load(fromByteOffset: 3, as: UInt8.self)) << 24)
            return UInt32(littleEndian: rawValue)
        }
    }

    private func installedExtensionsDirectory() throws -> URL {
        if let storageDirectory {
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            return storageDirectory
        }
        let appSupportURL = try quartzStorageDirectory(
            searchPathDirectory: .applicationSupportDirectory,
            unavailableError: .applicationSupportUnavailable
        )
        let directoryURL = appSupportURL.appendingPathComponent(installedExtensionsDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func chromeWebStoreDownloadDirectory() throws -> URL {
        let appSupportURL = try quartzStorageDirectory(
            searchPathDirectory: .applicationSupportDirectory,
            unavailableError: .applicationSupportUnavailable
        )
        let directoryURL = appSupportURL.appendingPathComponent(chromeWebStoreDownloadDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func sandboxedExtensionPagesDirectory() throws -> URL {
        let appSupportURL = try quartzStorageDirectory(
            searchPathDirectory: .applicationSupportDirectory,
            unavailableError: .applicationSupportUnavailable
        )
        let directoryURL = appSupportURL.appendingPathComponent(sandboxedExtensionPagesDirectoryName, isDirectory: true)
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

    private func grantInstallTimePermissions(to context: WKWebExtensionContext, record: inout QuartzExtensionRecord) throws {
        let permissions = Set(context.webExtension.requestedPermissions.map(\.rawValue))
        let patterns = Set(context.webExtension.requestedPermissionMatchPatterns.map(\.string))
        let newPermissions = permissions.subtracting(record.approvedPermissions)
        let newPatterns = patterns.subtracting(record.approvedMatchPatterns)
        guard (newPermissions.isEmpty && newPatterns.isEmpty) || permissionPrompt(
            displayName(for: context), newPermissions, newPatterns, true
        ) else { throw QuartzWebExtensionSupportError.permissionDenied }
        record.approvedPermissions.formUnion(permissions)
        record.approvedMatchPatterns.formUnion(patterns)
        for permission in context.webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in context.webExtension.requestedPermissionMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
    }

    private func displayName(for context: WKWebExtensionContext) -> String {
        nonEmpty(context.webExtension.displayName)
            ?? nonEmpty(context.webExtension.displayShortName)
            ?? context.webExtension.version.map { "Extension \($0)" }
            ?? "Unnamed Extension"
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false
        else {
            return nil
        }

        return value
    }

    private func sandboxedExtensionPage(
        for url: URL,
        context: WKWebExtensionContext
    ) throws -> (pageURL: URL, readAccessURL: URL)? {
        let pagePath = normalizedExtensionResourcePath(url.path)
        guard pagePath.isEmpty == false else {
            return nil
        }

        let decodedPagePath = pagePath.removingPercentEncoding ?? pagePath
        let standardizedPagePath = (decodedPagePath as NSString).standardizingPath
        let normalizedPagePath = standardizedPagePath.replacingOccurrences(of: "\\", with: "/")

        guard normalizedPagePath.hasPrefix("/") == false,
              normalizedPagePath.split(separator: "/").contains("..") == false
        else {
            throw QuartzWebExtensionSupportError.sandboxedExtensionPageUnavailable(pagePath)
        }

        guard let installedPath = installedPath(for: context) else {
            return nil
        }

        let installedURL = URL(fileURLWithPath: installedPath).standardizedFileURL
        let resourceDirectoryURL = try localResourceDirectory(for: installedURL)
        let sandboxPages = try sandboxPagePaths(in: resourceDirectoryURL)
        guard sandboxPages.contains(pagePath) else {
            return nil
        }

        let pageURL = resourceDirectoryURL
            .appendingPathComponent(pagePath, isDirectory: false)
            .standardizedFileURL
        let resolvedResourceDirectoryURL = resourceDirectoryURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let resolvedPageURL = pageURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let resourceDirectoryPath = resolvedResourceDirectoryURL.path
        guard resolvedPageURL.path.hasPrefix(resourceDirectoryPath + "/") else {
            throw QuartzWebExtensionSupportError.sandboxedExtensionPageUnavailable(pagePath)
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: pageURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue == false
        else {
            throw QuartzWebExtensionSupportError.sandboxedExtensionPageUnavailable(pagePath)
        }

        return (pageURL, resourceDirectoryURL)
    }

    private func installedPath(for context: WKWebExtensionContext) -> String? {
        extensionContextsByPath.first { _, installedContext in
            installedContext === context
        }?.key
    }

    private func localResourceDirectory(for sourceURL: URL) throws -> URL {
        var isDirectory = ObjCBool(false)

        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw QuartzWebExtensionSupportError.missingExtensionSource(sourceURL.lastPathComponent)
        }

        if isDirectory.boolValue {
            return try extensionRootDirectory(for: sourceURL)
        }

        guard sourceURL.pathExtension.lowercased() == "zip" else {
            throw QuartzWebExtensionSupportError.unsupportedExtensionSource
        }

        return try extractedSandboxResourceDirectory(for: sourceURL)
    }

    private func extractedSandboxResourceDirectory(for archiveURL: URL) throws -> URL {
        let cacheDirectoryURL = try sandboxedExtensionPagesDirectory()
        let signature = try archiveSignature(for: archiveURL)
        let destinationURL = cacheDirectoryURL.appendingPathComponent(signature, isDirectory: true)

        if let resourceDirectoryURL = try? extensionRootDirectory(for: destinationURL) {
            return resourceDirectoryURL
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try extractArchive(at: archiveURL, to: destinationURL)
        return try extensionRootDirectory(for: destinationURL)
    }

    private func extractArchive(at archiveURL: URL, to destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, destinationURL.path]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw QuartzWebExtensionSupportError.sandboxedExtensionPageUnavailable(archiveURL.lastPathComponent)
        }
    }

    private func archiveSignature(for archiveURL: URL) throws -> String {
        let values = try archiveURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modifiedAt = Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        let size = values.fileSize ?? 0
        let rawSignature = "\(archiveURL.deletingPathExtension().lastPathComponent)-\(size)-\(modifiedAt)"
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let fallbackScalar = "-".unicodeScalars.first!
        let scalars = rawSignature.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? scalar : fallbackScalar
        }

        let signature = String(String.UnicodeScalarView(scalars))
        return signature.isEmpty ? "extension-\(size)-\(modifiedAt)" : signature
    }

    private func sandboxPagePaths(in resourceDirectoryURL: URL) throws -> Set<String> {
        let manifestURL = resourceDirectoryURL.appendingPathComponent("manifest.json", isDirectory: false)
        let data = try Data(contentsOf: manifestURL)
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sandbox = manifest["sandbox"] as? [String: Any],
              let pages = sandbox["pages"] as? [String]
        else {
            return []
        }

        return Set(pages.map(normalizedExtensionResourcePath).filter { $0.isEmpty == false })
    }

    private func normalizedExtensionResourcePath(_ path: String) -> String {
        var trimmedPath = path.removingPercentEncoding ?? path
        while trimmedPath.hasPrefix("/") {
            trimmedPath.removeFirst()
        }

        return trimmedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")
    }

    func openURLFromExtension(_ url: URL, context: WKWebExtensionContext, in targetBrowser: BrowserController? = nil) {
        guard let browser = targetBrowser ?? browser else { return }
        if QuartzURLRouting.isStandardBrowsingURL(url) || QuartzStartPage.isStartPageURL(url) {
            browser.loadFromExtension(url)
            return
        }
        let owningContext = controller.extensionContext(for: url) ?? context

        do {
            if let sandboxedPage = try sandboxedExtensionPage(for: url, context: owningContext) {
                browser.loadSandboxedExtensionPage(
                    sandboxedPage.pageURL,
                    from: sandboxedPage.readAccessURL,
                    displayURL: url
                )
                return
            }
        } catch {
            print("Quartz sandboxed extension page unavailable: \(error.localizedDescription)")
        }

        if let configuration = owningContext.webViewConfiguration {
            browser.loadExtensionPage(url, using: configuration)
        } else {
            browser.loadFromExtension(url)
        }
    }

    private func summary(for context: WKWebExtensionContext, wasAlreadyLoaded: Bool) -> String {
        let name = displayName(for: context)
        let versionText = context.webExtension.version.map { " \($0)" } ?? ""
        let stateText = wasAlreadyLoaded ? "is already installed" : "was installed"
        return "\(name)\(versionText) \(stateText)."
    }

    func popupBrowser(for action: WKWebExtension.Action) -> BrowserController? {
        if let associatedTab = action.associatedTab {
            guard let tab = associatedTab as? QuartzWebExtensionBrowserTab,
                  browserTabs.contains(where: { $0 === tab }) else { return nil }
            return tab.browser
        }
        // WebKit clears associatedTab when that tab closes. Only the context's
        // actual global action may fall back to the focused browser.
        guard controller.extensionContexts.contains(where: { $0.action(for: nil) === action }) else { return nil }
        return browser
    }

    private func saveRecord(_ record: QuartzExtensionRecord) {
        var records = registry.read()
        records.removeAll { $0.path == record.path }
        records.append(record)
        registry.write(records)
    }

}

@available(macOS 15.4, *)
extension QuartzWebExtensionSupport: WKWebExtensionControllerDelegate {
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        browserTabs
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        focusedTab
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void
    ) {
        guard let tab = openBrowserTab(url: configuration.url, context: extensionContext, focused: configuration.shouldBeActive) else {
            completionHandler(nil, QuartzBrowserWindowError.noBrowserWindow)
            return
        }
        completionHandler(tab, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, Error?) -> Void
    ) {
        guard !configuration.shouldBePrivate else {
            completionHandler(nil, QuartzBrowserWindowError.privateWindowsUnsupported)
            return
        }
        guard configuration.tabs.isEmpty, configuration.tabURLs.count <= 1 else {
            completionHandler(nil, QuartzBrowserWindowError.multipleTabsUnsupported)
            return
        }
        guard let tab = openBrowserTab(url: configuration.tabURLs.first, context: extensionContext, focused: configuration.shouldBeFocused) else {
            completionHandler(nil, QuartzBrowserWindowError.noBrowserWindow)
            return
        }
        tab.applyInitialFrame(configuration.frame)
        tab.setWindowState(configuration.windowState, for: extensionContext) { error in
            completionHandler(error == nil ? tab : nil, error)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        if let url = extensionContext.optionsPageURL {
            let tab = openBrowserTab(url: url, context: extensionContext, focused: true)
            completionHandler(tab == nil ? QuartzBrowserWindowError.noBrowserWindow : nil)
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
        guard installedPath(for: extensionContext) != nil else { completionHandler([], nil); return }
        let allowed = permissionPrompt(displayName(for: extensionContext), Set(permissions.map(\.rawValue)), [], false)
        completionHandler(allowed ? permissions : [], nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        guard installedPath(for: extensionContext) != nil else { completionHandler([], nil); return }
        let allowed = permissionPrompt(displayName(for: extensionContext), [], Set(matchPatterns.map(\.string)), false)
        completionHandler(allowed ? matchPatterns : [], nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        guard installedPath(for: extensionContext) != nil else { completionHandler([], nil); return }
        let allowed = permissionPrompt(displayName(for: extensionContext), [], Set(urls.map(\.absoluteString)), false)
        completionHandler(allowed ? urls : [], nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        extensionsDidChange()
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let targetBrowser = popupBrowser(for: action)
        guard context.isLoaded, context.webExtensionController === controller,
              let popover = action.popupPopover,
              let anchorView = targetBrowser?.extensionPopupAnchorView ?? targetBrowser?.extensionWebView,
              anchorView.window?.isVisible == true
        else {
            completionHandler(QuartzWebExtensionSupportError.missingPopup)
            return
        }

        presentedPopupBrowser = targetBrowser
        presentedPopupWebView = action.popupWebView
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
        completionHandler(nil)
    }
}

private enum QuartzWebExtensionSupportError: LocalizedError {
    case operationInProgress
    case permissionDenied
    case missingOptionsPage
    case missingPopup
    case missingInstalledExtension
    case missingAction(String)
    case disabledAction(String)
    case unsupportedExtensionSource
    case missingExtensionSource(String)
    case missingManifest(String)
    case invalidChromiumPackage
    case applicationSupportUnavailable
    case invalidChromeWebStoreReference
    case chromeWebStoreDownloadFailed(Int?)
    case sandboxedExtensionPageUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            "The extension is being loaded. Try again when loading finishes."
        case .permissionDenied:
            "Access was canceled. The extension was not enabled."
        case .missingOptionsPage:
            "The extension does not provide an options page."
        case .missingPopup:
            "The extension does not provide a popup that Quartz can display."
        case .missingInstalledExtension:
            "Quartz could not find that installed extension."
        case .missingAction(let extensionName):
            "\(extensionName) does not provide a toolbar action."
        case .disabledAction(let extensionName):
            "\(extensionName) is unavailable on this page."
        case .unsupportedExtensionSource:
            "Choose an unpacked Chromium extension folder, .zip archive, or .crx package."
        case .missingExtensionSource(let sourceName):
            "Quartz could not find \(sourceName)."
        case .missingManifest(let directoryName):
            "Quartz could not find manifest.json in \(directoryName)."
        case .invalidChromiumPackage:
            "Quartz could not read that Chromium extension package."
        case .applicationSupportUnavailable:
            "Quartz could not access Application Support to install the extension."
        case .invalidChromeWebStoreReference:
            "Paste a Chrome Web Store extension URL or a 32-character extension ID."
        case .chromeWebStoreDownloadFailed(let statusCode):
            if let statusCode {
                "Quartz could not download that extension from the Chrome Web Store. The server returned HTTP \(statusCode)."
            } else {
                "Quartz could not download that extension from the Chrome Web Store."
            }
        case .sandboxedExtensionPageUnavailable(let page):
            "Quartz could not prepare the sandboxed extension page \(page)."
        }
    }
}
