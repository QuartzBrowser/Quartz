import UserNotifications
import XCTest
@testable import Quartz

final class QuartzUpdateNotificationsTests: XCTestCase {
    func testOnlyUndeterminedAuthorizationRequestsPermission() {
        let cases: [(UNAuthorizationStatus, Bool)] = [
            (.notDetermined, true), (.denied, false), (.authorized, false), (.provisional, false)
        ]
        for (status, expected) in cases {
            let settings = QuartzNotificationAuthorization(
                status: status,
                alertSetting: .enabled,
                notificationCenterSetting: .enabled
            )
            XCTAssertEqual(settings.needsAuthorization, expected)
        }
    }

    func testDeliveryRequiresAuthorizationAndAnEnabledDestination() {
        let cases: [(UNAuthorizationStatus, UNNotificationSetting, UNNotificationSetting, Bool)] = [
            (.notDetermined, .enabled, .enabled, false),
            (.denied, .enabled, .enabled, false),
            (.authorized, .disabled, .disabled, false),
            (.authorized, .notSupported, .notSupported, false),
            (.authorized, .enabled, .disabled, true),
            (.authorized, .disabled, .enabled, true),
            (.authorized, .enabled, .enabled, true),
            (.provisional, .disabled, .enabled, true),
            (.provisional, .disabled, .disabled, false)
        ]
        for (status, alert, notificationCenter, expected) in cases {
            let settings = QuartzNotificationAuthorization(
                status: status,
                alertSetting: alert,
                notificationCenterSetting: notificationCenter
            )
            XCTAssertEqual(settings.canDeliver, expected)
        }
    }
}
