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
    private let isUpdateChannelAllowed: (String?) -> Bool
    private let stateChanged: (QuartzUpdateState) -> Void
    private let presentMessage: (String, String, @escaping () -> Void) -> Void
    private let openInformationURL: (URL) -> Void
    private var pendingChoice: ((SPUUserUpdateChoice) -> Void)?
    private var cancellation: (() -> Void)?
    private var retryTermination: (() -> Void)?
    private var consentedToInstall = false
    private var activeUpdateChannel: String?
    private var hasActiveUpdate = false
    private var channelInvalidated = false
    private var pendingChoiceIsOffer = false
    private var isChannelRefreshCheck = false
    private(set) var needsFreshChannelCheck = false
    private var acknowledgementID = UUID()
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private(set) var hasPendingManualCheck = false
    private(set) var state: QuartzUpdateState = .idle

    var canCancel: Bool { cancellation != nil }
    var canChangeUpdateChannel: Bool {
        switch state {
        case .extracting, .installing: false
        default: true
        }
    }

    private var activeUpdateIsAllowed: Bool {
        !channelInvalidated && (!hasActiveUpdate || isUpdateChannelAllowed(activeUpdateChannel))
    }

    init(
        automaticallyChecksForUpdates: @escaping () -> Bool = { true },
        isUpdateChannelAllowed: @escaping (String?) -> Bool = { $0 == nil || $0 == "" },
        stateChanged: @escaping (QuartzUpdateState) -> Void,
        presentMessage: @escaping (String, String, @escaping () -> Void) -> Void,
        openInformationURL: @escaping (URL) -> Void
    ) {
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.isUpdateChannelAllowed = isUpdateChannelAllowed
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
        channel: String? = nil,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        guard !channelInvalidated, isUpdateChannelAllowed(channel) else {
            channelInvalidated = true
            needsFreshChannelCheck = true
            clearSessionActions()
            setState(.idle)
            // Skip also clears a resumed download; dismiss can keep serving
            // that excluded item on every later check. The controller follows
            // with a fresh check to clear Sparkle's version-skip threshold.
            reply(.skip)
            return
        }
        cancellation = nil
        retryTermination = nil
        acknowledgementID = UUID()
        consentedToInstall = false
        activeUpdateChannel = channel
        hasActiveUpdate = true
        pendingChoiceIsOffer = true
        pendingChoice = reply
        if informationOnly {
            // Never pass .install for Sparkle information-only entries.
            setState(.informationOnly(version: version, url: Self.safeInformationURL(informationURL)))
        } else {
            setState(.available(version: version))
        }
    }

    func installUpdate() {
        guard activeUpdateIsAllowed else {
            invalidateExcludedUpdate()
            return
        }
        switch state {
        case .available, .readyToRestart:
            guard let reply = pendingChoice else { return }
            let wasOffer = pendingChoiceIsOffer
            pendingChoice = nil
            consentedToInstall = state != .readyToRestart
            setState(state == .readyToRestart ? .installing : .downloading(progress: nil))
            // State publication can synchronously change preferences before
            // Sparkle receives the choice. Recheck after that boundary too.
            guard activeUpdateIsAllowed else {
                needsFreshChannelCheck = needsFreshChannelCheck || wasOffer
                reply(.skip)
                return
            }
            reply(.install)
        default:
            break
        }
    }

    func openUpdateInformation() {
        guard activeUpdateIsAllowed else {
            invalidateExcludedUpdate()
            return
        }
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
        guard state == .installing, activeUpdateIsAllowed else { return }
        retryTermination?()
    }

    func updateChannelDidChange() {
        guard !activeUpdateIsAllowed else { return }
        invalidateExcludedUpdate()
    }

    private func invalidateExcludedUpdate() {
        channelInvalidated = true
        let cancel = cancellation
        let reply = pendingChoice
        if reply != nil && pendingChoiceIsOffer { needsFreshChannelCheck = true }
        clearSessionActions()
        setState(.idle)
        if let cancel {
            cancel()
        } else {
            reply?(.skip)
        }
    }

    /// Sparkle completes one cycle before beginning another. Keep revocation
    /// latched until then so late download/readiness callbacks cannot revive it.
    @discardableResult
    func updateCycleDidFinish() -> Bool {
        let wasInvalidated = channelInvalidated
        channelInvalidated = false
        hasActiveUpdate = false
        activeUpdateChannel = nil
        needsFreshChannelCheck = false
        isChannelRefreshCheck = false
        return wasInvalidated
    }

    /// A public manual Sparkle check clears its version-skip threshold after
    /// cancelling a resumed beta. Keep the background refresh quiet unless the
    /// user explicitly requests its result while it is running.
    func beginChannelRefreshCheck() {
        isChannelRefreshCheck = true
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
        let manuallyRequested = (state.userInitiated && !isChannelRefreshCheck) || hasPendingManualCheck
        hasPendingManualCheck = false
        offerUpdate(
            version: appcastItem.displayVersionString,
            informationOnly: appcastItem.isInformationOnlyUpdate,
            informationURL: appcastItem.infoURL,
            channel: appcastItem.channel,
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
        guard activeUpdateIsAllowed else { acknowledgement(); return }
        if isChannelRefreshCheck && !hasPendingManualCheck {
            clearSessionActions()
            setState(.idle)
            acknowledgement()
            return
        }
        clearSessionActions()
        hasPendingManualCheck = false
        setState(.idle)
        presentAcknowledgedMessage("No Update Available", Self.message(for: error), acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        guard activeUpdateIsAllowed else { acknowledgement(); return }
        if isChannelRefreshCheck && !hasPendingManualCheck {
            clearSessionActions()
            setState(.idle)
            acknowledgement()
            return
        }
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
        guard activeUpdateIsAllowed else {
            cancellation()
            return
        }
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
        guard activeUpdateIsAllowed else { return }
        let progress = expectedBytes == 0 ? nil : min(1, Double(receivedBytes) / Double(expectedBytes))
        setState(.downloading(progress: progress))
    }

    func showDownloadDidStartExtractingUpdate() {
        // Sparkle's cancellation handler is invalid once extraction starts.
        cancellation = nil
        guard activeUpdateIsAllowed else { return }
        setState(.extracting(progress: nil))
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        guard activeUpdateIsAllowed else { return }
        setState(.extracting(progress: progress.isFinite ? min(1, max(0, progress)) : nil))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard activeUpdateIsAllowed else {
            channelInvalidated = true
            clearSessionActions()
            setState(.idle)
            reply(.skip)
            return
        }
        guard state != .installing else { return }
        cancellation = nil
        if consentedToInstall {
            consentedToInstall = false
            setState(.installing)
            guard activeUpdateIsAllowed else {
                reply(.skip)
                return
            }
            reply(.install)
        } else {
            pendingChoice = reply
            pendingChoiceIsOffer = false
            setState(.readyToRestart)
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        guard activeUpdateIsAllowed else { return }
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
        pendingChoiceIsOffer = false
        cancellation = nil
        retryTermination = nil
        consentedToInstall = false
        hasPendingManualCheck = false
        acknowledgementID = UUID()
    }

    func showUpdateInFocus() {
        isChannelRefreshCheck = false
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
