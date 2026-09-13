import AppKit
import Darwin
import MachO
import WebKit

enum QuartzWebKitRuntime {
    static let repository = "https://github.com/QuartzBrowser/WebKit.git"
    static let manifestName = "QuartzWebKit.json"

    // AppKit Writing Tools loads the system WebKit through its assistant UI.
    // Apply its public opt-outs before native controls or pages are displayed.
    @MainActor
    static func configureWritingTools(for configuration: WKWebViewConfiguration) {
        #if QUARTZ_FORK_WEBKIT
        if #available(macOS 15.0, *) {
            configuration.writingToolsBehavior = .none
        }
        #endif
    }

    @MainActor
    static func configureWritingTools(for textField: NSTextField) {
        #if QUARTZ_FORK_WEBKIT
        if #available(macOS 15.2, *) {
            textField.allowsWritingTools = false
        }
        #endif
    }

    @MainActor
    static func configureWritingTools(for textView: NSTextView) {
        #if QUARTZ_FORK_WEBKIT
        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = .none
        }
        #endif
    }

    @MainActor
    static func configureWritingTools(for menu: NSMenu) {
        #if QUARTZ_FORK_WEBKIT
        if #available(macOS 15.2, *) {
            menu.automaticallyInsertsWritingToolsItems = false
            for item in menu.items {
                if let submenu = item.submenu {
                    configureWritingTools(for: submenu)
                }
            }
        }
        #endif
    }

    struct Manifest: Decodable, Sendable {
        let repository: String
        let revision: String
        let minimumSystemVersion: String
    }

    struct Report: Encodable, Sendable {
        let valid: Bool
        let mode: String
        let loadedFrameworkPath: String
        let loadedEngineImages: [String]
        let expectedFrameworkPath: String?
        let manifestPath: String?
        let repository: String?
        let revision: String?
        let minimumSystemVersion: String?
        let error: String?
    }

    @MainActor
    static func currentReport() -> Report {
        #if QUARTZ_FORK_WEBKIT
        let requiresFork = true
        #else
        let requiresFork = false
        #endif

        let loadedFrameworkURL = Bundle(for: WKWebView.self).bundleURL
        let loadedImages = (0..<_dyld_image_count()).compactMap { index -> String? in
            guard let name = _dyld_get_image_name(index) else { return nil }
            return String(cString: name)
        }
        return inspect(
            loadedFrameworkURL: loadedFrameworkURL,
            applicationBundleURL: Bundle.main.bundleURL,
            applicationResourcesURL: Bundle.main.resourceURL,
            applicationFrameworksURL: Bundle.main.privateFrameworksURL,
            environment: ProcessInfo.processInfo.environment,
            requiresFork: requiresFork,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersion,
            loadedImagePaths: loadedImages
        )
    }

    /// Read engine metadata before creating browser controllers or restoring a profile.
    @MainActor
    static func checkBeforeLaunch() {
        let report = currentReport()
        if CommandLine.arguments.contains("--quartz-webkit-info") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            do {
                var data = try encoder.encode(report)
                data.append(0x0A)
                FileHandle.standardOutput.write(data)
            } catch {
                FileHandle.standardError.write(Data("Quartz: could not encode WebKit diagnostic: \(error)\n".utf8))
                exit(EXIT_FAILURE)
            }
            exit(report.valid ? EXIT_SUCCESS : EXIT_FAILURE)
        }

        guard !report.valid else { return }
        let explanation = report.error ?? "The configured WebKit engine could not be verified."
        FileHandle.standardError.write(Data("Quartz: \(explanation)\n".utf8))
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Quartz could not load its WebKit engine"
        alert.informativeText = "\(explanation)\n\nReinstall Quartz or rebuild it with the configured QuartzBrowser WebKit fork."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        exit(EXIT_FAILURE)
    }

    static func inspect(
        loadedFrameworkURL: URL,
        applicationBundleURL: URL,
        applicationResourcesURL: URL?,
        applicationFrameworksURL: URL?,
        environment: [String: String],
        requiresFork: Bool,
        systemVersion: OperatingSystemVersion,
        loadedImagePaths: [String] = []
    ) -> Report {
        let loadedPath = loadedFrameworkURL.resolvingSymlinksInPath().standardizedFileURL.path
        let engineFrameworkNames: Set<String> = ["WebKit.framework", "WebCore.framework", "JavaScriptCore.framework"]
        let engineImages = Set(loadedImagePaths.compactMap { path -> String? in
            let url = URL(fileURLWithPath: path)
            guard url.pathComponents.contains(where: engineFrameworkNames.contains) else { return nil }
            return url.resolvingSymlinksInPath().standardizedFileURL.path
        }).sorted()
        let isPackaged = applicationBundleURL.pathExtension == "app"
        let productsPath = environment["QUARTZ_WEBKIT_PRODUCTS_DIR"]
        let adjacentProductsURL = loadedFrameworkURL.deletingLastPathComponent()
        let adjacentManifestExists = FileManager.default.fileExists(
            atPath: adjacentProductsURL.appendingPathComponent(manifestName).path
        )
        let productsURL: URL?
        if let productsPath {
            productsURL = productsPath.isEmpty ? nil : URL(fileURLWithPath: productsPath, isDirectory: true)
        } else {
            productsURL = adjacentManifestExists ? adjacentProductsURL : nil
        }
        // A packaged app must use its own engine even when launched from a development shell.
        let frameworksURL = isPackaged ? applicationFrameworksURL : productsURL
        let manifestURL = (isPackaged ? applicationResourcesURL : productsURL)?
            .appendingPathComponent(manifestName)
        let expectedPath = frameworksURL?.appendingPathComponent("WebKit.framework", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let manifestExists = manifestURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let expectsFork = requiresFork || manifestExists || (!isPackaged && productsPath != nil)
        var manifest: Manifest?

        func report(_ error: String? = nil) -> Report {
            Report(
                valid: error == nil,
                mode: expectsFork ? "fork" : "system-development",
                loadedFrameworkPath: loadedPath,
                loadedEngineImages: engineImages,
                expectedFrameworkPath: expectsFork ? expectedPath : nil,
                manifestPath: expectsFork ? manifestURL?.path : nil,
                repository: manifest?.repository,
                revision: manifest?.revision,
                minimumSystemVersion: manifest?.minimumSystemVersion,
                error: error
            )
        }

        guard expectsFork else { return report() }
        guard let manifestURL, manifestExists else {
            return report("Missing \(manifestName) for the required QuartzBrowser WebKit fork\(manifestURL.map { " at \($0.path)" } ?? "").")
        }
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            return report("Cannot read valid WebKit metadata at \(manifestURL.path): \(error.localizedDescription)")
        }
        guard let manifest else { return report("Missing WebKit metadata.") }
        guard manifest.repository == repository else {
            return report("WebKit metadata names an unexpected repository: \(manifest.repository).")
        }
        guard manifest.revision.utf8.count == 40,
              manifest.revision.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil else {
            return report("WebKit metadata must contain a full 40-character Git revision.")
        }
        guard let minimumVersion = parseVersion(manifest.minimumSystemVersion) else {
            return report("WebKit metadata contains an invalid minimumSystemVersion.")
        }
        let currentVersion = [systemVersion.majorVersion, systemVersion.minorVersion, systemVersion.patchVersion]
        if currentVersion.lexicographicallyPrecedes(minimumVersion) {
            return report("This WebKit engine requires macOS \(manifest.minimumSystemVersion) or newer.")
        }
        guard let expectedPath else {
            return report("The required WebKit framework directory is missing.")
        }
        guard loadedPath == expectedPath else {
            return report("Quartz loaded WebKit from \(loadedPath), but its configured fork is at \(expectedPath).")
        }
        if let frameworkDirectory = frameworksURL?.resolvingSymlinksInPath().standardizedFileURL.path,
           let unexpectedImage = engineImages.first(where: { !$0.hasPrefix(frameworkDirectory + "/") }) {
            return report("Quartz loaded an engine image from \(unexpectedImage), outside its configured framework directory \(frameworkDirectory).")
        }
        return report()
    }

    private static func parseVersion(_ value: String) -> [Int]? {
        guard value.range(of: "^[0-9]+\\.[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil else { return nil }
        let components = value.split(separator: ".").compactMap { Int($0) }
        guard components.count == value.split(separator: ".").count else { return nil }
        return components.count == 2 ? components + [0] : components
    }
}
