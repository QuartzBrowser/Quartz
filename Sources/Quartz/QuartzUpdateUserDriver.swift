import Foundation
import Sparkle

enum QuartzUpdateState: Equatable {
    case idle
    case checking
    case available(version: String)
    case informationOnly(version: String, url: URL?)
    case downloading(progress: Double?)
    case extracting(progress: Double?)
    case readyToRestart
    case installing
    case failed(message: String)
}

/// Bridges Sparkle's verified update lifecycle to the browser's persistent toolbar.
@MainActor
final class QuartzUpdateUserDriver: NSObject, SPUUserDriver {
    private let automaticallyChecksForUpdates: () -> Bool
    private let stateChanged: (QuartzUpdateState) -> Void
    private let presentMessage: (String, String, @escaping () -> Void) -> Void
    private let openInformationURL: (URL) -> Void
    private var pendingChoice: ((SPUUserUpdateChoice) -> Void)?
    private var cancellation: (() -> Void)?
    private var retryTermination: (() -> Void)?
    private var consentedToInstall = false
    private var acknowledgementID = UUID()
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private(set) var hasPendingManualCheck = false
    private(set) var state: QuartzUpdateState = .idle

    var canCancel: Bool { cancellation != nil }

    init(
        automaticallyChecksForUpdates: @escaping () -> Bool = { true },
        stateChanged: @escaping (QuartzUpdateState) -> Void,
        presentMessage: @escaping (String, String, @escaping () -> Void) -> Void,
        openInformationURL: @escaping (URL) -> Void
    ) {
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.stateChanged = stateChanged
        self.presentMessage = presentMessage
        self.openInformationURL = openInformationURL
    }

    private func setState(_ state: QuartzUpdateState) {
        self.state = state
        stateChanged(state)
    }

    func manualCheckRequestedDuringBackgroundCheck() {
        hasPendingManualCheck = true
        setState(.checking)
    }

    func offerUpdate(
        version: String,
        informationOnly: Bool,
        informationURL: URL?,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        cancellation = nil
        retryTermination = nil
        acknowledgementID = UUID()
        consentedToInstall = false
        pendingChoice = reply
        if informationOnly {
            // Never pass .install for Sparkle information-only entries.
            setState(.informationOnly(version: version, url: Self.safeInformationURL(informationURL)))
        } else {
            setState(.available(version: version))
        }
    }

    func installUpdate() {
        switch state {
        case .available, .readyToRestart:
            guard let reply = pendingChoice else { return }
            pendingChoice = nil
            consentedToInstall = state != .readyToRestart
            setState(state == .readyToRestart ? .installing : .downloading(progress: nil))
            reply(.install)
        default:
            break
        }
    }

    func openUpdateInformation() {
        guard case .informationOnly(_, let url) = state else { return }
        guard let url else {
            let reply = pendingChoice
            clearSessionActions()
            let message = "The release did not provide a valid HTTPS information link. Try checking again later."
            setState(.failed(message: message))
            reply?(.dismiss)
            presentMessage("Update Information Unavailable", message, {})
            return
        }
        let reply = pendingChoice
        pendingChoice = nil
        openInformationURL(url)
        setState(.idle)
        reply?(.dismiss)
    }

    static func safeInformationURL(_ url: URL?) -> URL? {
        guard let url, url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    func cancel() {
        guard let cancellation else { return }
        self.cancellation = nil
        consentedToInstall = false
        hasPendingManualCheck = false
        setState(.idle)
        cancellation()
    }

    func retryRelaunch() {
        guard state == .installing else { return }
        retryTermination?()
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Release configuration already opts into checks; the menu controls this preference.
        reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: automaticallyChecksForUpdates(),
            automaticUpdateDownloading: false,
            sendSystemProfile: false
        ))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        acknowledgementID = UUID()
        retryTermination = nil
        pendingChoice = nil
        consentedToInstall = false
        self.cancellation = cancellation
        setState(.checking)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let manuallyRequested = state.userInitiated || hasPendingManualCheck
        hasPendingManualCheck = false
        offerUpdate(
            version: appcastItem.displayVersionString,
            informationOnly: appcastItem.isInformationOnlyUpdate,
            informationURL: appcastItem.infoURL,
            reply: reply
        )
        if manuallyRequested { showUpdateInFocus() }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // Updates need no web content in the native toolbar; release notes are optional.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        // Failure to fetch optional release notes does not block a verified update.
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        clearSessionActions()
        hasPendingManualCheck = false
        setState(.idle)
        presentAcknowledgedMessage("No Update Available", Self.message(for: error), acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        clearSessionActions()
        hasPendingManualCheck = false
        let message = Self.message(for: error)
        setState(.failed(message: message))
        presentAcknowledgedMessage("Unable to Update Quartz", message + "\n\nYou can keep browsing and try again.", acknowledgement: acknowledgement)
    }

    private func presentAcknowledgedMessage(_ title: String, _ message: String, acknowledgement: @escaping () -> Void) {
        let identifier = UUID()
        acknowledgementID = identifier
        var pendingAcknowledgement: (() -> Void)? = acknowledgement
        presentMessage(title, message) { [weak self] in
            guard self?.acknowledgementID == identifier,
                  let completion = pendingAcknowledgement else { return }
            pendingAcknowledgement = nil
            completion()
        }
    }

    private static func message(for error: Error) -> String {
        let error = error as NSError
        return [error.localizedDescription, error.localizedRecoverySuggestion]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        expectedBytes = 0
        receivedBytes = 0
        setState(.downloading(progress: nil))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
        updateDownloadProgress()
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        let result = receivedBytes.addingReportingOverflow(length)
        receivedBytes = result.overflow ? UInt64.max : result.partialValue
        updateDownloadProgress()
    }

    private func updateDownloadProgress() {
        let progress = expectedBytes == 0 ? nil : min(1, Double(receivedBytes) / Double(expectedBytes))
        setState(.downloading(progress: progress))
    }

    func showDownloadDidStartExtractingUpdate() {
        // Sparkle's cancellation handler is invalid once extraction starts.
        cancellation = nil
        setState(.extracting(progress: nil))
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        setState(.extracting(progress: progress.isFinite ? min(1, max(0, progress)) : nil))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard state != .installing else { return }
        cancellation = nil
        if consentedToInstall {
            consentedToInstall = false
            setState(.installing)
            reply(.install)
        } else {
            pendingChoice = reply
            setState(.readyToRestart)
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        cancellation = nil
        retryTermination = applicationTerminated ? nil : retryTerminatingApplication
        setState(.installing)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        clearSessionActions()
        hasPendingManualCheck = false
        setState(.idle)
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        clearSessionActions()
        if case .failed = state { return }
        setState(.idle)
    }

    private func clearSessionActions() {
        pendingChoice = nil
        cancellation = nil
        retryTermination = nil
        consentedToInstall = false
        hasPendingManualCheck = false
        acknowledgementID = UUID()
    }

    func showUpdateInFocus() {
        switch state {
        case .available(let version):
            presentMessage("Quartz \(version) Is Available", "Press Update & Restart in the toolbar. Quartz will download and verify the update, save your current page, then restart automatically.", {})
        case .informationOnly(let version, _):
            presentMessage("Quartz \(version) Update Information", "This release requires additional steps. Press Update Details in the toolbar to read the release information.", {})
        case .readyToRestart:
            presentMessage("Quartz Is Ready to Update", "Press Update & Restart in the toolbar to install the verified update and restore your current page.", {})
        case .checking, .downloading, .extracting, .installing:
            presentMessage("Quartz Update in Progress", "Update progress is shown in the toolbar. Quartz will restart when installation is ready.", {})
        case .failed(let message):
            presentMessage("Unable to Update Quartz", message, {})
        case .idle:
            break
        }
    }
}
