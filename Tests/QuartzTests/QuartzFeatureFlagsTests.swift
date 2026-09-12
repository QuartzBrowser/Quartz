import XCTest
@testable import Quartz

@MainActor
final class QuartzFeatureFlagsTests: XCTestCase {
    func testWebMCPDefaultsToDisabledAndPersistsBothChoices() throws {
        let suite = "QuartzFeatureFlagsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let flags = QuartzFeatureFlags(defaults: defaults)
        XCTAssertFalse(flags.isWebMCPEnabled)

        flags.setWebMCPEnabled(true)
        XCTAssertTrue(flags.isWebMCPEnabled)
        XCTAssertTrue(QuartzFeatureFlags(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))).isWebMCPEnabled)

        flags.setWebMCPEnabled(false)
        XCTAssertFalse(flags.isWebMCPEnabled)
        XCTAssertFalse(QuartzFeatureFlags(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))).isWebMCPEnabled)
    }

    func testExistingInstancesSeeChangesAndDifferentSuitesRemainIndependent() throws {
        let suite = "QuartzFeatureFlagsTests.\(UUID().uuidString)"
        let otherSuite = "QuartzFeatureFlagsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: otherSuite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            otherDefaults.removePersistentDomain(forName: otherSuite)
        }
        let first = QuartzFeatureFlags(defaults: defaults)
        let second = QuartzFeatureFlags(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let independent = QuartzFeatureFlags(defaults: otherDefaults)
        first.setWebMCPEnabled(true)
        XCTAssertTrue(second.isWebMCPEnabled)
        XCTAssertFalse(independent.isWebMCPEnabled)
        second.setWebMCPEnabled(false)
        XCTAssertFalse(first.isWebMCPEnabled)
    }

    func testOnlyRealChangesSynchronouslyNotifyAfterSaving() throws {
        let suite = "QuartzFeatureFlagsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let flags = QuartzFeatureFlags(defaults: defaults)
        let recorder = ChangeRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: QuartzFeatureFlags.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated { recorder.values.append(flags.isWebMCPEnabled) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        flags.setWebMCPEnabled(false)
        XCTAssertEqual(recorder.values, [])
        flags.setWebMCPEnabled(true)
        XCTAssertEqual(recorder.values, [true], "Notifications must complete before changing the flag returns")
        flags.setWebMCPEnabled(true)
        XCTAssertEqual(recorder.values, [true])
        flags.setWebMCPEnabled(false)
        XCTAssertEqual(recorder.values, [true, false])
    }
}

@MainActor
private final class ChangeRecorder {
    var values: [Bool] = []
}
