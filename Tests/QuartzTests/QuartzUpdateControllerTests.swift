import XCTest
@testable import Quartz

@MainActor
final class QuartzUpdateControllerTests: XCTestCase {
    func testSparkleCanCallTheFeedRelaunchAndCycleCompletionDelegates() {
        let fixture = UpdateControllerFixture()
        let controller = fixture.makeController()
        for selector in [
            "feedURLStringForUpdater:",
            "updaterWillRelaunchApplication:",
            "updater:didFinishUpdateCycleForUpdateCheck:error:"
        ] {
            XCTAssertTrue(controller.responds(to: NSSelectorFromString(selector)), selector)
        }
    }

    func testLegacyAutomaticCheckOptOutMigratesToSparkle() {
        let fixture = UpdateControllerFixture()
        fixture.defaults.set(false, forKey: "Quartz.updates.automaticChecks")

        QuartzUpdateController.migrateAutomaticCheckPreference(defaults: fixture.defaults)

        XCTAssertEqual(fixture.defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool, false)
        XCTAssertFalse(fixture.makeController().automaticallyChecksForUpdates)
    }

    func testLegacyAutomaticCheckOptInMigratesToSparkle() {
        let fixture = UpdateControllerFixture()
        fixture.defaults.set(true, forKey: "Quartz.updates.automaticChecks")

        QuartzUpdateController.migrateAutomaticCheckPreference(defaults: fixture.defaults)

        XCTAssertEqual(fixture.defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool, true)
        XCTAssertTrue(fixture.makeController().automaticallyChecksForUpdates)
    }

    func testMigrationNeverOverwritesANewerSparklePreference() {
        for currentPreference in [false, true] {
            let fixture = UpdateControllerFixture()
            fixture.defaults.set(!currentPreference, forKey: "Quartz.updates.automaticChecks")
            fixture.defaults.set(currentPreference, forKey: "SUEnableAutomaticChecks")

            QuartzUpdateController.migrateAutomaticCheckPreference(defaults: fixture.defaults)
            QuartzUpdateController.migrateAutomaticCheckPreference(defaults: fixture.defaults)

            XCTAssertEqual(fixture.defaults.bool(forKey: "SUEnableAutomaticChecks"), currentPreference)
            XCTAssertEqual(fixture.makeController().automaticallyChecksForUpdates, currentPreference)
        }
    }

    func testAutomaticChecksDefaultToEnabledAndOptOutSurvivesRelaunch() {
        let fixture = UpdateControllerFixture()
        let controller = fixture.makeController()
        XCTAssertTrue(controller.automaticallyChecksForUpdates)

        controller.automaticallyChecksForUpdates = false
        XCTAssertFalse(fixture.makeController().automaticallyChecksForUpdates)

        controller.automaticallyChecksForUpdates = true
        XCTAssertTrue(fixture.makeController().automaticallyChecksForUpdates)
    }

    func testUnconfiguredBundleStartsSilentlyAndExplainsManualChecks() {
        let fixture = UpdateControllerFixture()
        let controller = fixture.makeController()
        XCTAssertFalse(controller.isConfigured)
        controller.start()
        controller.start()
        XCTAssertFalse(controller.hasStarted)
        XCTAssertTrue(fixture.messages.isEmpty)
        XCTAssertFalse(fixture.states.contains(.checking))

        controller.checkForUpdates()
        XCTAssertFalse(controller.hasStarted)
        XCTAssertEqual(fixture.messages.count, 1)
        XCTAssertTrue(fixture.messages[0].text.contains("packaged Quartz.app"))
        XCTAssertFalse(fixture.states.contains(.checking), "A build without signed update configuration must not start a check.")
        XCTAssertTrue(fixture.openedURLs.isEmpty)
        XCTAssertEqual(fixture.relaunchPreparations, 0)
    }

    func testUpdateFeedsRequireHTTPSExceptExplicitLoopbackTesting() {
        for url in [
            "https://updates.example.org/quartz/appcast.xml",
            "https://github.com/QuartzBrowser/Quartz/releases/latest/download/appcast.xml",
            "http://localhost:8123/appcast.xml",
            "http://127.0.0.1:8123/appcast.xml",
            "http://[::1]:8123/appcast.xml"
        ] {
            XCTAssertTrue(QuartzUpdateController.isValidFeedURL(URL(string: url)!), url)
        }
        for url in [
            "http://updates.example.org/appcast.xml",
            "http://localhost.evil.example/appcast.xml",
            "http://127.0.0.1.evil.example/appcast.xml",
            "https://user:password@updates.example.org/appcast.xml",
            "http://localhost@updates.example.org/appcast.xml",
            "file:///tmp/appcast.xml",
            "javascript:alert(1)",
            "/appcast.xml"
        ] {
            XCTAssertFalse(QuartzUpdateController.isValidFeedURL(URL(string: url)!), url)
        }
    }

    func testPackagedBuildRejectsMissingOrMalformedSigningKeysBeforeStartingUpdater() throws {
        let keys: [String?] = [nil, "", "not base64", Data(repeating: 1, count: 31).base64EncodedString(), Data(repeating: 1, count: 33).base64EncodedString()]
        for key in keys {
            let bundle = try UpdateTestBundle(publicKey: key)
            let fixture = UpdateControllerFixture()
            let controller = fixture.makeController(bundle: bundle.bundle)
            XCTAssertFalse(controller.isConfigured)
            controller.start()
            controller.checkForUpdates()

            XCTAssertFalse(controller.hasStarted)
            XCTAssertFalse(fixture.states.contains(.checking))
            XCTAssertEqual(fixture.messages.count, 1)
            XCTAssertTrue(fixture.messages[0].text.contains("signing"))
        }
    }

    func testUpdateButtonExplainsUnconfiguredBundleEvenAfterOptOut() {
        let fixture = UpdateControllerFixture()
        let controller = fixture.makeController()
        controller.automaticallyChecksForUpdates = false
        controller.start()
        controller.performPrimaryAction()

        XCTAssertEqual(fixture.messages.count, 1)
        XCTAssertFalse(fixture.messages[0].text.isEmpty)
        XCTAssertFalse(fixture.states.contains(.checking))
        XCTAssertTrue(fixture.openedURLs.isEmpty)
        XCTAssertEqual(fixture.relaunchPreparations, 0)
    }
}

@MainActor
private final class UpdateControllerFixture {
    struct Message {
        let title: String
        let text: String
        let acknowledgement: () -> Void
    }

    private let defaultsName = "QuartzUpdateControllerTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    var states: [QuartzUpdateState] = []
    var messages: [Message] = []
    var openedURLs: [URL] = []
    var relaunchPreparations = 0

    init() {
        defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
    }

    deinit {
        UserDefaults(suiteName: defaultsName)?.removePersistentDomain(forName: defaultsName)
    }

    func makeController(bundle: Bundle = Bundle(for: QuartzUpdateControllerTests.self)) -> QuartzUpdateController {
        QuartzUpdateController(
            bundle: bundle,
            defaults: defaults,
            stateChanged: { [unowned self] in self.states.append($0) },
            presentMessage: { [unowned self] in
                self.messages.append(Message(title: $0, text: $1, acknowledgement: $2))
            },
            openInformationURL: { [unowned self] in self.openedURLs.append($0) },
            prepareForRelaunch: { [unowned self] in self.relaunchPreparations += 1 }
        )
    }
}

private final class UpdateTestBundle {
    private let directory: URL
    let bundle: Bundle

    init(publicKey: String?) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("QuartzUpdateTests-\(UUID().uuidString)", isDirectory: true)
        let app = directory.appendingPathComponent("Quartz.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var metadata: [String: Any] = [
            "CFBundleIdentifier": "org.quartz.update-tests.\(UUID().uuidString)",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "800",
            "CFBundleShortVersionString": "0.8.0",
            "SUFeedURL": "https://updates.example.org/appcast.xml"
        ]
        metadata["SUPublicEDKey"] = publicKey
        let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        bundle = try XCTUnwrap(Bundle(url: app))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
