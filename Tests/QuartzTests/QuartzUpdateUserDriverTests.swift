import Sparkle
import XCTest
@testable import Quartz

@MainActor
final class QuartzUpdateUserDriverTests: XCTestCase {
    func testOneUpdateClickDownloadsAndInstallsWithoutAnotherConfirmation() {
        let fixture = UpdateDriverFixture()
        let driver = fixture.driver
        var downloadReplies: [SPUUserUpdateChoice] = []
        var installReplies: [SPUUserUpdateChoice] = []

        driver.offerUpdate(version: "0.9.0", informationOnly: false, informationURL: nil) {
            downloadReplies.append($0)
        }
        XCTAssertEqual(driver.state, .available(version: "0.9.0"))
        XCTAssertTrue(downloadReplies.isEmpty, "Finding an update does not authorize installation.")

        driver.installUpdate()
        driver.installUpdate()
        XCTAssertEqual(downloadReplies, [.install])

        driver.showDownloadInitiated(cancellation: {})
        driver.showDownloadDidReceiveExpectedContentLength(100)
        driver.showDownloadDidReceiveData(ofLength: 100)
        driver.showDownloadDidStartExtractingUpdate()
        driver.showExtractionReceivedProgress(1)
        driver.showReady(toInstallAndRelaunch: { installReplies.append($0) })
        driver.installUpdate()

        XCTAssertEqual(installReplies, [.install], "The initial Update click also authorizes relaunch.")
        XCTAssertEqual(driver.state, .installing)
        XCTAssertTrue(fixture.messages.isEmpty)
    }

    func testReadyUpdateWithoutConsentWaitsForAnUpdateClick() {
        let fixture = UpdateDriverFixture()
        var replies: [SPUUserUpdateChoice] = []
        fixture.driver.showReady(toInstallAndRelaunch: { replies.append($0) })

        XCTAssertEqual(fixture.driver.state, .readyToRestart)
        XCTAssertTrue(replies.isEmpty)

        fixture.driver.installUpdate()
        fixture.driver.installUpdate()
        XCTAssertEqual(replies, [.install])
    }

    func testOfferKeepsWaitingForConsentWhenCancellationIsUnavailable() {
        let fixture = UpdateDriverFixture()
        var replies: [SPUUserUpdateChoice] = []
        fixture.driver.offerUpdate(version: "0.9.0", informationOnly: false, informationURL: nil) {
            replies.append($0)
        }

        XCTAssertFalse(fixture.driver.canCancel)
        fixture.driver.cancel()
        XCTAssertTrue(replies.isEmpty)
        XCTAssertEqual(fixture.driver.state, .available(version: "0.9.0"))
        fixture.driver.installUpdate()

        XCTAssertEqual(replies, [.install])
    }

    func testReadyUpdateHasNoCancellationAndStillWaitsForConsent() {
        let fixture = UpdateDriverFixture()
        var replies: [SPUUserUpdateChoice] = []
        fixture.driver.showReady(toInstallAndRelaunch: { replies.append($0) })
        XCTAssertFalse(fixture.driver.canCancel)

        fixture.driver.cancel()
        XCTAssertTrue(replies.isEmpty)
        XCTAssertEqual(fixture.driver.state, .readyToRestart)
        fixture.driver.installUpdate()

        XCTAssertEqual(replies, [.install])
    }

    func testCancellingDownloadRevokesConsentAndConsumesCancellation() {
        let fixture = UpdateDriverFixture()
        var cancellations = 0
        var readyReplies: [SPUUserUpdateChoice] = []
        fixture.driver.offerUpdate(version: "0.9.0", informationOnly: false, informationURL: nil) { _ in }
        fixture.driver.installUpdate()
        fixture.driver.showDownloadInitiated(cancellation: { cancellations += 1 })
        XCTAssertTrue(fixture.driver.canCancel)

        fixture.driver.cancel()
        fixture.driver.cancel()
        fixture.driver.showReady(toInstallAndRelaunch: { readyReplies.append($0) })

        XCTAssertEqual(cancellations, 1)
        XCTAssertTrue(readyReplies.isEmpty, "Cancelled consent must not authorize a later ready callback.")
    }

    func testDownloadCancellationCannotFireAfterExtractionBegins() {
        let fixture = UpdateDriverFixture()
        var cancellations = 0
        fixture.driver.showDownloadInitiated(cancellation: { cancellations += 1 })
        fixture.driver.showDownloadDidStartExtractingUpdate()

        XCTAssertFalse(fixture.driver.canCancel)
        fixture.driver.cancel()
        XCTAssertEqual(cancellations, 0)
    }

    func testUpdateDiscoveryDiscardsTheFinishedCheckCancellation() {
        let fixture = UpdateDriverFixture()
        var cancelledChecks = 0
        var replies: [SPUUserUpdateChoice] = []
        fixture.driver.showUserInitiatedUpdateCheck(cancellation: { cancelledChecks += 1 })
        XCTAssertEqual(fixture.driver.state, .checking)
        fixture.driver.offerUpdate(version: "0.9.0", informationOnly: false, informationURL: nil) {
            replies.append($0)
        }

        fixture.driver.cancel()
        XCTAssertEqual(cancelledChecks, 0)
        XCTAssertTrue(replies.isEmpty)
        fixture.driver.installUpdate()
        XCTAssertEqual(replies, [.install])
    }

    func testInformationOnlyUpdateNeverReceivesInstallReply() {
        let fixture = UpdateDriverFixture()
        let url = URL(string: "https://github.com/QuartzBrowser/Quartz/releases/tag/v0.9.0")!
        var replies: [SPUUserUpdateChoice] = []
        fixture.driver.offerUpdate(version: "0.9.0", informationOnly: true, informationURL: url) {
            replies.append($0)
        }

        XCTAssertEqual(fixture.driver.state, .informationOnly(version: "0.9.0", url: url))
        fixture.driver.installUpdate()
        XCTAssertFalse(replies.contains(.install))
        fixture.driver.openUpdateInformation()
        XCTAssertEqual(fixture.openedURLs, [url])
        XCTAssertFalse(replies.contains(.install))
    }

    func testInformationOnlyUpdateWithNoURLEndsTheCycleSoCheckingCanBeRetried() {
        let fixture = UpdateDriverFixture()
        var replies: [SPUUserUpdateChoice] = []
        fixture.driver.offerUpdate(version: "0.9.0", informationOnly: true, informationURL: nil) {
            replies.append($0)
        }
        fixture.driver.installUpdate()
        fixture.driver.openUpdateInformation()
        fixture.driver.cancel()

        XCTAssertEqual(replies, [.dismiss])
        XCTAssertTrue(fixture.openedURLs.isEmpty)
        guard case .failed = fixture.driver.state else {
            return XCTFail("An unusable information-only update should allow the user to retry.")
        }
    }

    func testInformationOnlyUpdatesRejectUnsafeInformationLinks() {
        for value in ["http://example.org/update", "file:///tmp/update.html", "javascript:alert(1)", "https://user:password@example.org/update"] {
            let fixture = UpdateDriverFixture()
            var choices: [SPUUserUpdateChoice] = []
            fixture.driver.offerUpdate(version: "0.9.0", informationOnly: true, informationURL: URL(string: value)) {
                choices.append($0)
            }
            fixture.driver.openUpdateInformation()
            fixture.driver.installUpdate()

            XCTAssertTrue(fixture.openedURLs.isEmpty, value)
            XCTAssertEqual(choices, [.dismiss], value)
            XCTAssertEqual(fixture.messages.count, 1)
        }
    }

    func testDownloadProgressHandlesUnknownAndIncorrectContentLengths() {
        let fixture = UpdateDriverFixture()
        let driver = fixture.driver
        driver.showDownloadInitiated(cancellation: {})
        XCTAssertEqual(driver.state, .downloading(progress: nil))
        driver.showDownloadDidReceiveData(ofLength: 30)
        XCTAssertEqual(driver.state, .downloading(progress: nil))
        driver.showDownloadDidReceiveExpectedContentLength(100)
        XCTAssertEqual(driver.state, .downloading(progress: 0.3))
        driver.showDownloadDidReceiveData(ofLength: 30)
        XCTAssertEqual(driver.state, .downloading(progress: 0.6))

        driver.showDownloadDidReceiveExpectedContentLength(40)
        XCTAssertEqual(driver.state, .downloading(progress: 1))
        driver.showDownloadDidReceiveData(ofLength: .max)
        XCTAssertEqual(driver.state, .downloading(progress: 1))
        driver.showDownloadDidReceiveExpectedContentLength(0)
        XCTAssertEqual(driver.state, .downloading(progress: nil))
    }

    func testNewDownloadResetsThePreviousDownloadsByteCounts() {
        let fixture = UpdateDriverFixture()
        let driver = fixture.driver
        driver.showDownloadInitiated(cancellation: {})
        driver.showDownloadDidReceiveExpectedContentLength(100)
        driver.showDownloadDidReceiveData(ofLength: 100)
        driver.cancel()

        driver.showDownloadInitiated(cancellation: {})
        driver.showDownloadDidReceiveExpectedContentLength(200)
        driver.showDownloadDidReceiveData(ofLength: 50)
        XCTAssertEqual(driver.state, .downloading(progress: 0.25))
    }

    func testExtractionProgressIsFiniteAndBounded() {
        let fixture = UpdateDriverFixture()
        let driver = fixture.driver
        driver.showDownloadDidStartExtractingUpdate()
        XCTAssertEqual(driver.state, .extracting(progress: nil))

        for progress in [-1.0, 0, 0.25, 1, 2, Double.nan, .infinity, -.infinity] {
            driver.showExtractionReceivedProgress(progress)
            guard case let .extracting(value) = driver.state else {
                XCTFail("Extraction progress changed the installation phase.")
                continue
            }
            if let value {
                XCTAssertTrue(value.isFinite)
                XCTAssertTrue((0...1).contains(value))
            }
            if progress.isFinite {
                XCTAssertEqual(value, min(1, max(0, progress)))
            }
        }
    }

    func testDismissalClearsAllSessionActionsAndInstallationConsent() {
        let fixture = UpdateDriverFixture()
        let driver = fixture.driver
        var oldOfferReplies: [SPUUserUpdateChoice] = []
        driver.offerUpdate(version: "0.9.0", informationOnly: false, informationURL: nil) {
            oldOfferReplies.append($0)
        }
        driver.dismissUpdateInstallation()
        driver.installUpdate()
        driver.cancel()
        XCTAssertTrue(oldOfferReplies.isEmpty)

        var cancellations = 0
        driver.showDownloadInitiated(cancellation: { cancellations += 1 })
        driver.dismissUpdateInstallation()
        driver.cancel()
        XCTAssertEqual(cancellations, 0)

        driver.offerUpdate(version: "0.9.0", informationOnly: false, informationURL: nil) { _ in }
        driver.installUpdate()
        driver.dismissUpdateInstallation()
        var readyReplies: [SPUUserUpdateChoice] = []
        driver.showReady(toInstallAndRelaunch: { readyReplies.append($0) })
        XCTAssertTrue(readyReplies.isEmpty)
        driver.dismissUpdateInstallation()
        driver.installUpdate()
        XCTAssertTrue(readyReplies.isEmpty)

        var retries = 0
        driver.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: { retries += 1 })
        driver.dismissUpdateInstallation()
        driver.retryRelaunch()
        XCTAssertEqual(retries, 0)
        XCTAssertEqual(driver.state, .idle)
        XCTAssertFalse(driver.canCancel)
    }

    func testDismissalForgetsAManualCheckRequestedDuringBackgroundWork() {
        let fixture = UpdateDriverFixture()
        fixture.driver.manualCheckRequestedDuringBackgroundCheck()
        XCTAssertTrue(fixture.driver.hasPendingManualCheck)

        fixture.driver.dismissUpdateInstallation()
        XCTAssertFalse(fixture.driver.hasPendingManualCheck)
        XCTAssertEqual(fixture.driver.state, .idle)
    }

    func testRelaunchCanOnlyBeRetriedWhileTheApplicationIsStillRunning() {
        let fixture = UpdateDriverFixture()
        var retries = 0
        fixture.driver.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: { retries += 1 })
        fixture.driver.retryRelaunch()
        XCTAssertEqual(retries, 1)

        fixture.driver.showInstallingUpdate(withApplicationTerminated: true, retryTerminatingApplication: { retries += 1 })
        fixture.driver.retryRelaunch()
        XCTAssertEqual(retries, 1)
    }

    func testInstallationFailureClearsRelaunchRetry() {
        let fixture = UpdateDriverFixture()
        var retries = 0
        fixture.driver.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: { retries += 1 })
        fixture.driver.showUpdaterError(NSError(domain: "QuartzUpdateTest", code: 4), acknowledgement: {})
        fixture.driver.retryRelaunch()
        XCTAssertEqual(retries, 0)
    }

    func testCompletedInstallationReleasesSessionActionsAndConsent() {
        let fixture = UpdateDriverFixture()
        var retries = 0
        var acknowledgements = 0
        fixture.driver.offerUpdate(version: "0.9.0", informationOnly: false, informationURL: nil) { _ in }
        fixture.driver.installUpdate()
        fixture.driver.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: { retries += 1 })
        fixture.driver.showUpdateInstalledAndRelaunched(true, acknowledgement: { acknowledgements += 1 })

        XCTAssertEqual(acknowledgements, 1)
        XCTAssertEqual(fixture.driver.state, .idle)
        fixture.driver.retryRelaunch()
        XCTAssertEqual(retries, 0)

        var replies: [SPUUserUpdateChoice] = []
        fixture.driver.showReady(toInstallAndRelaunch: { replies.append($0) })
        XCTAssertTrue(replies.isEmpty)
    }

    func testErrorClearsThePendingUpdateAndAcknowledgesOnlyOnce() {
        let fixture = UpdateDriverFixture()
        var updateReplies: [SPUUserUpdateChoice] = []
        var acknowledgements = 0
        fixture.driver.offerUpdate(version: "0.9.0", informationOnly: false, informationURL: nil) {
            updateReplies.append($0)
        }
        let error = NSError(domain: "QuartzUpdateTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "The update could not be verified.",
            NSLocalizedRecoverySuggestionErrorKey: "Check for updates again."
        ])

        fixture.driver.showUpdaterError(error, acknowledgement: { acknowledgements += 1 })
        XCTAssertEqual(fixture.messages.count, 1)
        XCTAssertTrue(fixture.messages[0].text.contains(error.localizedDescription))
        guard case .failed = fixture.driver.state else {
            return XCTFail("The browser should explain an update failure.")
        }
        fixture.driver.installUpdate()
        fixture.driver.cancel()
        XCTAssertTrue(updateReplies.isEmpty)
        XCTAssertEqual(acknowledgements, 0)

        fixture.messages[0].acknowledgement()
        fixture.messages[0].acknowledgement()
        XCTAssertEqual(acknowledgements, 1)
    }

    func testDismissedErrorCannotAcknowledgeOrChangeANewSession() {
        let fixture = UpdateDriverFixture()
        var oldAcknowledgements = 0
        let error = NSError(domain: "QuartzUpdateTest", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "The connection was interrupted."
        ])
        fixture.driver.showUpdaterError(error, acknowledgement: { oldAcknowledgements += 1 })
        let oldMessage = fixture.messages[0]
        fixture.driver.dismissUpdateInstallation()

        var newReplies: [SPUUserUpdateChoice] = []
        fixture.driver.offerUpdate(version: "0.9.1", informationOnly: false, informationURL: nil) {
            newReplies.append($0)
        }
        oldMessage.acknowledgement()
        XCTAssertEqual(oldAcknowledgements, 0)
        XCTAssertEqual(fixture.driver.state, .available(version: "0.9.1"))
        fixture.driver.installUpdate()
        XCTAssertEqual(newReplies, [.install])
    }

    func testNoUpdateMessagePreservesTheReasonAndReleasesCheckCancellation() {
        let fixture = UpdateDriverFixture()
        var cancellations = 0
        var acknowledgements = 0
        fixture.driver.showUserInitiatedUpdateCheck(cancellation: { cancellations += 1 })
        let error = NSError(domain: "QuartzUpdateTest", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "This update requires a newer version of macOS."
        ])
        fixture.driver.showUpdateNotFoundWithError(error, acknowledgement: { acknowledgements += 1 })
        fixture.driver.cancel()

        XCTAssertEqual(cancellations, 0)
        XCTAssertEqual(fixture.messages.count, 1)
        XCTAssertTrue(fixture.messages[0].text.contains(error.localizedDescription))
        fixture.messages[0].acknowledgement()
        XCTAssertEqual(acknowledgements, 1)
    }

    func testPermissionResponsePreservesOptOutAndNeverEnablesSilentInstallation() {
        let fixture = UpdateDriverFixture()
        for automaticChecks in [false, true] {
            fixture.automaticChecks = automaticChecks
            var responses: [SUUpdatePermissionResponse] = []
            fixture.driver.show(SPUUpdatePermissionRequest(systemProfile: [])) {
                responses.append($0)
            }

            XCTAssertEqual(responses.count, 1)
            XCTAssertEqual(responses[0].automaticUpdateChecks, automaticChecks)
            XCTAssertEqual(responses[0].automaticUpdateDownloading?.boolValue, false)
            XCTAssertFalse(responses[0].sendSystemProfile)
        }
    }
}

@MainActor
private final class UpdateDriverFixture {
    struct Message {
        let title: String
        let text: String
        let acknowledgement: () -> Void
    }

    var automaticChecks = true
    var states: [QuartzUpdateState] = []
    var messages: [Message] = []
    var openedURLs: [URL] = []
    lazy var driver = QuartzUpdateUserDriver(
        automaticallyChecksForUpdates: { [unowned self] in self.automaticChecks },
        stateChanged: { [unowned self] in self.states.append($0) },
        presentMessage: { [unowned self] in self.messages.append(Message(title: $0, text: $1, acknowledgement: $2)) },
        openInformationURL: { [unowned self] in self.openedURLs.append($0) }
    )
}
