import XCTest
@testable import Quartz

@MainActor
final class QuartzUpdateControllerTests: XCTestCase {
    func testAutomaticChecksAreThrottledAcrossControllerInstances() async {
        let fixture = UpdateControllerFixture()
        let first = fixture.makeController()
        await first.check()
        await first.check()

        let relaunched = fixture.makeController()
        fixture.date += QuartzUpdateController.checkInterval - 1
        await relaunched.check()
        XCTAssertEqual(fixture.fetchedVersions, ["0.7.0"])

        fixture.date += 1
        await relaunched.check()
        XCTAssertEqual(fixture.fetchedVersions, ["0.7.0", "0.7.0"])
        XCTAssertEqual(fixture.checkingStates, [true, false, true, false])
    }

    func testBackwardClockChangeDoesNotDisableAutomaticChecks() async {
        let fixture = UpdateControllerFixture()
        let controller = fixture.makeController()
        await controller.check()
        fixture.date -= 60
        await controller.check()
        XCTAssertEqual(fixture.fetchedVersions.count, 2)
    }

    func testSuccessfulAnnouncementIsRememberedAndLaterReleaseIsAnnounced() async {
        let fixture = UpdateControllerFixture()
        let firstRelease = fixture.release
        await fixture.makeController().check()

        fixture.date += QuartzUpdateController.checkInterval
        await fixture.makeController().check()
        XCTAssertEqual(fixture.notifiedReleases, [firstRelease])

        fixture.release = UpdateControllerFixture.release("0.9.0")
        fixture.date += QuartzUpdateController.checkInterval
        await fixture.makeController().check()
        XCTAssertEqual(fixture.notifiedReleases, [firstRelease, fixture.release])
        XCTAssertTrue(fixture.presentedResults.isEmpty)
    }

    func testOptOutPersistsAndManualCheckBypassesOptOutThrottleAndDeduplication() async {
        let fixture = UpdateControllerFixture()
        let controller = fixture.makeController()
        await controller.check()
        controller.automaticallyChecksForUpdates = false

        let relaunched = fixture.makeController()
        XCTAssertFalse(relaunched.automaticallyChecksForUpdates)
        fixture.date += QuartzUpdateController.checkInterval
        await relaunched.check()
        XCTAssertEqual(fixture.fetchedVersions.count, 1)

        await relaunched.check(manually: true)
        await relaunched.check(manually: true)
        XCTAssertEqual(fixture.fetchedVersions.count, 3)
        XCTAssertEqual(fixture.notifiedReleases, [fixture.release])
        XCTAssertEqual(fixture.presentedResults, [.available(fixture.release), .available(fixture.release)])
    }

    func testDeniedNotificationFallsBackToPresentationAndRemembersSuccess() async {
        let fixture = UpdateControllerFixture()
        fixture.notificationSucceeds = false
        await fixture.makeController().check()
        XCTAssertEqual(fixture.presentedResults, [.available(fixture.release)])

        fixture.date += QuartzUpdateController.checkInterval
        await fixture.makeController().check()
        XCTAssertEqual(fixture.notifiedReleases.count, 1)
        XCTAssertEqual(fixture.presentedResults.count, 1)
    }

    func testFailedNotificationAndPresentationAreRetriedAtNextCheck() async {
        let fixture = UpdateControllerFixture()
        fixture.notificationSucceeds = false
        fixture.presentationSucceeds = false
        await fixture.makeController().check()

        fixture.date += QuartzUpdateController.checkInterval
        fixture.presentationSucceeds = true
        await fixture.makeController().check()
        XCTAssertEqual(fixture.notifiedReleases, [fixture.release, fixture.release])
        XCTAssertEqual(fixture.presentedResults, [.available(fixture.release), .available(fixture.release)])

        fixture.date += QuartzUpdateController.checkInterval
        await fixture.makeController().check()
        XCTAssertEqual(fixture.notifiedReleases.count, 2)
    }

    func testAutomaticNetworkErrorsAreSilentAndManualErrorsArePresented() async {
        let fixture = UpdateControllerFixture()
        let controller = fixture.makeController(fetchUpdate: { _ in throw URLError(.notConnectedToInternet) })
        await controller.check()
        XCTAssertTrue(fixture.presentedResults.isEmpty)
        XCTAssertTrue(fixture.notifiedReleases.isEmpty)

        await controller.check(manually: true)
        XCTAssertEqual(fixture.presentedResults, [.failed])
        XCTAssertEqual(fixture.checkingStates, [true, false, true, false])
    }

    func testNoUpdateIsSilentAutomaticallyAndReportedForManualCheck() async {
        let fixture = UpdateControllerFixture()
        let controller = fixture.makeController(fetchUpdate: { _ in nil })
        await controller.check()
        XCTAssertTrue(fixture.presentedResults.isEmpty)
        XCTAssertTrue(fixture.notifiedReleases.isEmpty)

        await controller.check(manually: true)
        XCTAssertEqual(fixture.presentedResults, [.upToDate("0.7.0")])
    }

    func testMissingBundleVersionSkipsNetworkingAndExplainsManualCheck() async {
        let versions: [String?] = [nil, ""]
        for version in versions {
            let fixture = UpdateControllerFixture()
            let controller = fixture.makeController(currentVersion: version)
            await controller.check()
            XCTAssertTrue(fixture.presentedResults.isEmpty)

            await controller.check(manually: true)
            XCTAssertTrue(fixture.fetchedVersions.isEmpty)
            XCTAssertTrue(fixture.notifiedReleases.isEmpty)
            XCTAssertTrue(fixture.checkingStates.isEmpty)
            XCTAssertEqual(fixture.presentedResults, [.unavailableVersion])
        }
    }

    func testManualRequestDuringAutomaticFetchReceivesTheSameResult() async {
        let fixture = UpdateControllerFixture()
        let gate = UpdateFetchGate()
        let controller = fixture.makeController(fetchUpdate: { _ in await gate.fetch() })
        let backgroundCheck = Task { await controller.check() }
        await gate.waitUntilStarted()

        await controller.check(manually: true)
        gate.finish(with: fixture.release)
        await backgroundCheck.value

        XCTAssertEqual(gate.fetchCount, 1)
        XCTAssertTrue(fixture.notifiedReleases.isEmpty)
        XCTAssertEqual(fixture.presentedResults, [.available(fixture.release)])
        XCTAssertEqual(fixture.checkingStates, [true, false])
    }

    func testManualRequestDuringSuccessfulNotificationDeliveryStillPresentsRelease() async {
        let fixture = UpdateControllerFixture()
        let gate = UpdateNotificationGate()
        let controller = fixture.makeController(notify: { _ in await gate.deliver() })
        let backgroundCheck = Task { await controller.check() }
        await gate.waitUntilStarted()

        await controller.check(manually: true)
        gate.finish(delivered: true)
        await backgroundCheck.value

        XCTAssertEqual(fixture.fetchedVersions, ["0.7.0"])
        XCTAssertEqual(fixture.notifiedReleases, [fixture.release])
        XCTAssertEqual(fixture.presentedResults, [.available(fixture.release)])
        XCTAssertEqual(fixture.checkingStates, [true, false])

        fixture.date += QuartzUpdateController.checkInterval
        await fixture.makeController().check()
        XCTAssertEqual(fixture.notifiedReleases.count, 1)
    }

    func testManualRequestDuringDeniedNotificationStillPresentsAfterAutomaticOptOut() async {
        let fixture = UpdateControllerFixture()
        let gate = UpdateNotificationGate()
        let controller = fixture.makeController(notify: { _ in await gate.deliver() })
        let backgroundCheck = Task { await controller.check() }
        await gate.waitUntilStarted()

        controller.automaticallyChecksForUpdates = false
        await controller.check(manually: true)
        gate.finish(delivered: false)
        await backgroundCheck.value

        XCTAssertEqual(fixture.fetchedVersions, ["0.7.0"])
        XCTAssertEqual(fixture.notifiedReleases, [fixture.release])
        XCTAssertEqual(fixture.presentedResults, [.available(fixture.release)])
        XCTAssertEqual(fixture.checkingStates, [true, false])

        controller.automaticallyChecksForUpdates = true
        fixture.date += QuartzUpdateController.checkInterval
        await fixture.makeController().check()
        XCTAssertEqual(fixture.notifiedReleases.count, 1)
    }

    func testStoppingDuringFetchSuppressesDeliveryAndFurtherChecks() async {
        let fixture = UpdateControllerFixture()
        let gate = UpdateFetchGate()
        let controller = fixture.makeController(fetchUpdate: { _ in await gate.fetch() })
        let backgroundCheck = Task { await controller.check() }
        await gate.waitUntilStarted()

        controller.stop()
        gate.finish(with: fixture.release)
        await backgroundCheck.value
        await controller.check(manually: true)

        XCTAssertEqual(gate.fetchCount, 1)
        XCTAssertTrue(fixture.notifiedReleases.isEmpty)
        XCTAssertTrue(fixture.presentedResults.isEmpty)
        XCTAssertEqual(fixture.checkingStates, [true, false])
    }

    func testDisablingAutomaticChecksDuringFetchSuppressesDelivery() async {
        let fixture = UpdateControllerFixture()
        let gate = UpdateFetchGate()
        let controller = fixture.makeController(fetchUpdate: { _ in await gate.fetch() })
        let backgroundCheck = Task { await controller.check() }
        await gate.waitUntilStarted()

        controller.automaticallyChecksForUpdates = false
        gate.finish(with: fixture.release)
        await backgroundCheck.value

        XCTAssertTrue(fixture.notifiedReleases.isEmpty)
        XCTAssertTrue(fixture.presentedResults.isEmpty)
        XCTAssertEqual(fixture.checkingStates, [true, false])
    }

    func testNotificationLinksAcceptOnlyQuartzGitHubReleasePages() {
        let releaseURL = "https://github.com/QuartzBrowser/Quartz/releases/tag/v0.8.0"
        XCTAssertEqual(QuartzUpdateNotifications.releaseURL(from: releaseURL)?.absoluteString, releaseURL)

        for value in [
            "http://github.com/QuartzBrowser/Quartz/releases/tag/v0.8.0",
            "https://github.com.evil.example/QuartzBrowser/Quartz/releases/tag/v0.8.0",
            "https://github.com@evil.example/QuartzBrowser/Quartz/releases/tag/v0.8.0",
            "https://user:password@github.com/QuartzBrowser/Quartz/releases/tag/v0.8.0",
            "https://github.com:443/QuartzBrowser/Quartz/releases/tag/v0.8.0",
            "https://github.com/AnotherOwner/Quartz/releases/tag/v0.8.0",
            "https://github.com/QuartzBrowser/AnotherApp/releases/tag/v0.8.0",
            "https://github.com/QuartzBrowser/Quartz/issues/1",
            "https://github.com/QuartzBrowser/Quartz/releases/tag/",
            "https://github.com/QuartzBrowser/Quartz/releases/tag/v0.8.0/extra",
            "https://github.com/QuartzBrowser/Quartz/releases/tag/v0.8.0?redirect=evil",
            "https://github.com/QuartzBrowser/Quartz/releases/tag/v0.8.0#fragment",
            "file:///tmp/update.html",
            "javascript:alert(1)"
        ] {
            XCTAssertNil(QuartzUpdateNotifications.releaseURL(from: value), value)
        }
    }

    func testNotificationDeliveryWithoutAppBundleReturnsFalseWithoutOpeningRelease() async {
        let bundle = Bundle(for: QuartzUpdateControllerTests.self)
        XCTAssertNotEqual(bundle.bundleURL.pathExtension, "app")
        var openedURLs: [URL] = []
        let notifications = QuartzUpdateNotifications(bundle: bundle) { openedURLs.append($0) }
        let release = UpdateControllerFixture.release("0.8.0")

        let disabledResult = await notifications.deliver(release, shouldDeliver: { false })
        let enabledResult = await notifications.deliver(release, shouldDeliver: { true })

        XCTAssertFalse(disabledResult)
        XCTAssertFalse(enabledResult)
        XCTAssertTrue(openedURLs.isEmpty)
    }
}

@MainActor
private final class UpdateControllerFixture {
    private let defaultsName = "QuartzUpdateControllerTests.\(UUID().uuidString)"
    private let defaults: UserDefaults
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    var release = UpdateControllerFixture.release("0.8.0")
    var notificationSucceeds = true
    var presentationSucceeds = true
    var fetchedVersions: [String] = []
    var notifiedReleases: [QuartzUpdateRelease] = []
    var presentedResults: [QuartzUpdateCheckResult] = []
    var checkingStates: [Bool] = []

    init() {
        defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
    }

    deinit {
        UserDefaults(suiteName: defaultsName)?.removePersistentDomain(forName: defaultsName)
    }

    static func release(_ version: String) -> QuartzUpdateRelease {
        QuartzUpdateRelease(
            version: version,
            url: URL(string: "https://github.com/QuartzBrowser/Quartz/releases/tag/v\(version)")!
        )
    }

    func makeController(
        currentVersion: String? = "0.7.0",
        fetchUpdate: ((String) async throws -> QuartzUpdateRelease?)? = nil,
        notify: ((QuartzUpdateRelease) async -> Bool)? = nil
    ) -> QuartzUpdateController {
        QuartzUpdateController(
            currentVersion: currentVersion,
            defaults: defaults,
            now: { self.date },
            fetchUpdate: { version in
                self.fetchedVersions.append(version)
                if let fetchUpdate { return try await fetchUpdate(version) }
                return self.release
            },
            notify: { release in
                self.notifiedReleases.append(release)
                if let notify { return await notify(release) }
                return self.notificationSucceeds
            },
            present: { result in
                self.presentedResults.append(result)
                return self.presentationSucceeds
            },
            checkingChanged: { self.checkingStates.append($0) }
        )
    }
}

/// Models a permission request or notification delivery that has not completed.
@MainActor
private final class UpdateNotificationGate {
    private var started: CheckedContinuation<Void, Never>?
    private var result: CheckedContinuation<Bool, Never>?
    private var isDelivering = false

    func deliver() async -> Bool {
        isDelivering = true
        return await withCheckedContinuation { continuation in
            result = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        guard !isDelivering else { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(delivered: Bool) {
        result?.resume(returning: delivered)
        result = nil
    }
}

/// Suspends the injected fetch so lifecycle changes can occur at a known point.
@MainActor
private final class UpdateFetchGate {
    private var started: CheckedContinuation<Void, Never>?
    private var result: CheckedContinuation<QuartzUpdateRelease?, Never>?
    private(set) var fetchCount = 0

    func fetch() async -> QuartzUpdateRelease? {
        fetchCount += 1
        return await withCheckedContinuation { continuation in
            result = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        guard fetchCount == 0 else { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(with release: QuartzUpdateRelease?) {
        result?.resume(returning: release)
        result = nil
    }
}
