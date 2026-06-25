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
}

@available(macOS 15.4, *)
@MainActor
final class QuartzWebExtensionSupport: NSObject {
    let controller: WKWebExtensionController

    private weak var browser: BrowserController?
    private var extensionContextsByPath = [String: WKWebExtensionContext]()
    private let savedExtensionPathsKey = "QuartzInstalledExtensionPaths"
    private let appSupportDirectoryName = "Quartz"
    private let installedExtensionsDirectoryName = "Extensions"
    private let chromeWebStoreDownloadDirectoryName = "ChromeWebStoreDownloads"
    private let sandboxedExtensionPagesDirectoryName = "SandboxedExtensionPages"
    private let chromeWebStoreUpdateURL = URL(string: "https://clients2.google.com/service/update2/crx")!

    var installedExtensionNames: [String] {
        extensionContextsByPath.values
            .map { displayName(for: $0) }
            .sorted()
    }

    var installedExtensions: [QuartzInstalledWebExtension] {
        extensionContextsByPath
            .map { path, context in
                let action = context.action(for: self)
                let displayName = displayName(for: context)
                let actionLabel = nonEmpty(action?.label) ?? displayName

                return QuartzInstalledWebExtension(
                    identifier: path,
                    displayName: displayName,
                    actionLabel: actionLabel,
                    badgeText: action?.badgeText ?? "",
                    icon: action?.icon(for: NSSize(width: 18, height: 18)),
                    isActionEnabled: action?.isEnabled == true
                )
            }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
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
                let installedExtensionURL = try installExtensionSource(from: url)
                let summary = try await loadExtension(at: installedExtensionURL, shouldSave: true)
                completion(.success(summary))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func installExtensionFromChromeWebStore(_ reference: String, completion: @escaping (Result<String, Error>) -> Void) {
        Task { @MainActor in
            do {
                let extensionID = try Self.chromeWebStoreExtensionID(from: reference)
                let downloadedPackageURL = try await downloadChromeWebStoreExtension(withID: extensionID)
                defer {
                    try? FileManager.default.removeItem(at: downloadedPackageURL)
                }

                let installedExtensionURL = try installExtensionSource(from: downloadedPackageURL)
                let summary = try await loadExtension(at: installedExtensionURL, shouldSave: true)
                completion(.success(summary))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func performAction(forInstalledExtensionWithIdentifier identifier: String) throws {
        guard let context = extensionContextsByPath[identifier] else {
            throw QuartzWebExtensionSupportError.missingInstalledExtension
        }

        let displayName = displayName(for: context)
        guard let action = context.action(for: self) else {
            throw QuartzWebExtensionSupportError.missingAction(displayName)
        }

        guard action.isEnabled else {
            throw QuartzWebExtensionSupportError.disabledAction(displayName)
        }

        context.performAction(for: self)
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
        let destinationURL = downloadDirectoryURL.appendingPathComponent("\(extensionID).crx", isDirectory: false)

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

    private static func chromeWebStoreExtensionID(from reference: String) throws -> String {
        let trimmedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = trimmedReference.components(separatedBy: CharacterSet.alphanumerics.inverted)

        for token in tokens where isChromeWebStoreExtensionID(token) {
            return token.lowercased()
        }

        throw QuartzWebExtensionSupportError.invalidChromeWebStoreReference
    }

    private static func isChromeWebStoreExtensionID(_ token: String) -> Bool {
        let lowercasedToken = token.lowercased()
        guard lowercasedToken.count == 32 else {
            return false
        }

        let validCharacters = CharacterSet(charactersIn: "abcdefghijklmnop")
        return lowercasedToken.unicodeScalars.allSatisfy { validCharacters.contains($0) }
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

        return directoryURL.appendingPathComponent(destinationName, isDirectory: isDirectory)
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

        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private func installedExtensionsDirectory() throws -> URL {
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

    private func grantInstallTimePermissions(to context: WKWebExtensionContext) {
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

        guard pagePath.split(separator: "/").contains("..") == false else {
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
        let resourceDirectoryPath = resourceDirectoryURL.standardizedFileURL.path
        guard pageURL.path.hasPrefix(resourceDirectoryPath + "/") else {
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
        let scalars = rawSignature.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? scalar : UnicodeScalar("-")
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

    private func openURLFromExtension(_ url: URL, context: WKWebExtensionContext) {
        let owningContext = controller.extensionContext(for: url) ?? context

        do {
            if let sandboxedPage = try sandboxedExtensionPage(for: url, context: owningContext) {
                browser?.loadSandboxedExtensionPage(
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
            browser?.loadExtensionPage(url, using: configuration)
        } else {
            browser?.loadFromExtension(url)
        }
    }

    private func summary(for context: WKWebExtensionContext, wasAlreadyLoaded: Bool) -> String {
        let name = displayName(for: context)
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
            openURLFromExtension(url, context: extensionContext)
        }

        completionHandler(self, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        if let url = extensionContext.optionsPageURL {
            openURLFromExtension(url, context: extensionContext)
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
        guard let popover = action.popupPopover,
              let anchorView = browser?.extensionPopupAnchorView ?? browser?.extensionWebView
        else {
            completionHandler(QuartzWebExtensionSupportError.missingPopup)
            return
        }

        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
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

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        openURLFromExtension(url, context: context)
        completionHandler(nil)
    }
}

private enum QuartzWebExtensionSupportError: LocalizedError {
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
