import Foundation
import Sparkle

/// Owns Sparkle's update cycle. Sparkle downloads, verifies, replaces and relaunches the app.
@MainActor
final class QuartzUpdateController: NSObject, SPUUpdaterDelegate {
    private static let automaticChecksKey = "SUEnableAutomaticChecks"
    private static let legacyAutomaticChecksKey = "Quartz.updates.automaticChecks"

    private let bundle: Bundle
    private let defaults: UserDefaults
    private let presentMessage: (String, String, @escaping () -> Void) -> Void
    private let prepareForRelaunch: () -> Void
    private let userDriver: QuartzUpdateUserDriver
    private var updater: SPUUpdater?
    private var startupError: String?
    private var manualCheckPending = false

    var isConfigured: Bool { Self.configurationIssue(in: bundle) == nil }
    var hasStarted: Bool { updater != nil }
    var canCancel: Bool { userDriver.canCancel }

    var automaticallyChecksForUpdates: Bool {
        get {
            updater?.automaticallyChecksForUpdates
                ?? (defaults.object(forKey: Self.automaticChecksKey) as? Bool)
                ?? (bundle.object(forInfoDictionaryKey: Self.automaticChecksKey) as? Bool)
                ?? true
        }
        set {
            if let updater {
                updater.automaticallyChecksForUpdates = newValue
            } else {
                defaults.set(newValue, forKey: Self.automaticChecksKey)
            }
        }
    }

    init(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        stateChanged: @escaping (QuartzUpdateState) -> Void,
        presentMessage: @escaping (String, String, @escaping () -> Void) -> Void,
        openInformationURL: @escaping (URL) -> Void,
        prepareForRelaunch: @escaping () -> Void
    ) {
        self.bundle = bundle
        self.defaults = defaults
        self.presentMessage = presentMessage
        self.prepareForRelaunch = prepareForRelaunch
        Self.migrateAutomaticCheckPreference(defaults: defaults)
        userDriver = QuartzUpdateUserDriver(
            automaticallyChecksForUpdates: {
                (defaults.object(forKey: Self.automaticChecksKey) as? Bool)
                    ?? (bundle.object(forInfoDictionaryKey: Self.automaticChecksKey) as? Bool)
                    ?? true
            },
            stateChanged: stateChanged,
            presentMessage: presentMessage,
            openInformationURL: openInformationURL
        )
        super.init()
    }

    /// Copy the prior opt-out only once; Sparkle's setting is authoritative thereafter.
    static func migrateAutomaticCheckPreference(defaults: UserDefaults) {
        if defaults.object(forKey: automaticChecksKey) == nil,
           let previous = defaults.object(forKey: legacyAutomaticChecksKey) as? Bool {
            defaults.set(previous, forKey: automaticChecksKey)
        }
        defaults.removeObject(forKey: legacyAutomaticChecksKey)
    }

    static func configurationIssue(in bundle: Bundle) -> String? {
        guard bundle.bundleURL.pathExtension == "app",
              let version = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !version.isEmpty,
              let displayVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !displayVersion.isEmpty else {
            return "This development build cannot install updates. Run a packaged Quartz.app release to update from inside the browser."
        }
        guard let feedString = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let feedURL = URL(string: feedString), isValidFeedURL(feedURL),
              let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: publicKey)?.count == 32,
              bundle.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool == true,
              bundle.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool == true else {
            return "This build is not configured for secure updates. Install a Quartz.app release with update signing configured."
        }
        return nil
    }

    static func isValidFeedURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        // Local signed-fixture testing is configured in the packaged app itself.
        return url.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
    }

    func start() {
        guard updater == nil else { return }
        if let issue = Self.configurationIssue(in: bundle) {
            startupError = issue
            return
        }

        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: userDriver, delegate: self)
        // An update is downloaded and installed only after pressing Update & Restart.
        updater.automaticallyDownloadsUpdates = false
        do {
            try updater.start()
            self.updater = updater
            startupError = nil
        } catch {
            startupError = error.localizedDescription
        }
    }

    func checkForUpdates() {
        start()
        guard let updater else {
            presentMessage("Updates Unavailable", startupError ?? "Please try again later.", {})
            return
        }
        if updater.canCheckForUpdates {
            updater.checkForUpdates()
        } else {
            switch userDriver.state {
            case .idle, .failed:
                // A manual request during Sparkle's background fetch still receives a result.
                manualCheckPending = true
                userDriver.manualCheckRequestedDuringBackgroundCheck()
            default:
                userDriver.showUpdateInFocus()
            }
        }
    }

    func performPrimaryAction() {
        switch userDriver.state {
        case .available, .readyToRestart:
            userDriver.installUpdate()
        case .informationOnly:
            userDriver.openUpdateInformation()
        case .installing:
            userDriver.retryRelaunch()
        case .failed, .idle:
            checkForUpdates()
        case .checking, .downloading, .extracting:
            break
        }
    }

    func cancel() {
        manualCheckPending = false
        userDriver.cancel()
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        // The signed bundle owns the feed; a stale user-default URL cannot override it.
        bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        prepareForRelaunch()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard manualCheckPending else { return }
        manualCheckPending = false
        guard userDriver.hasPendingManualCheck else { return }
        // Automatic no-update/error cycles have no user-driver alert. A fresh manual
        // cycle gives the user Sparkle's complete result, including compatibility errors.
        // Sparkle clears its active driver and sets canCheckForUpdates before this delegate.
        updater.checkForUpdates()
    }
}
