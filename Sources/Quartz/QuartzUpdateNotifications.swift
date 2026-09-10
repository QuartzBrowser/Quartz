import AppKit
import UserNotifications

struct QuartzNotificationAuthorization: Sendable {
    let needsAuthorization: Bool
    let canDeliver: Bool

    init(status: UNAuthorizationStatus, alertSetting: UNNotificationSetting, notificationCenterSetting: UNNotificationSetting) {
        needsAuthorization = status == .notDetermined
        canDeliver = (status == .authorized || status == .provisional)
            && (alertSetting == .enabled || notificationCenterSetting == .enabled)
    }
}

@MainActor
final class QuartzUpdateNotifications: NSObject, UNUserNotificationCenterDelegate {
    private static let identifier = "Quartz.updateAvailable"
    private let center: UNUserNotificationCenter?
    private let openRelease: (URL) -> Void

    init(bundle: Bundle = .main, openRelease: @escaping (URL) -> Void) {
        self.openRelease = openRelease
        // UNUserNotificationCenter requires an app bundle; `swift run` has none.
        if bundle.bundleURL.pathExtension == "app", bundle.bundleIdentifier != nil {
            center = UNUserNotificationCenter.current()
        } else {
            center = nil
        }
        super.init()
        center?.delegate = self
    }

    func deliver(_ release: QuartzUpdateRelease, shouldDeliver: () -> Bool) async -> Bool {
        guard let center, !Task.isCancelled, shouldDeliver() else { return false }
        do {
            var settings = await Self.authorizationSettings(for: center)
            if settings.needsAuthorization {
                // Ask in context, only once an update actually exists.
                guard try await Self.requestAuthorization(for: center) else { return false }
                settings = await Self.authorizationSettings(for: center)
            }
            guard !Task.isCancelled, shouldDeliver(), settings.canDeliver
            else { return false }

            let content = UNMutableNotificationContent()
            content.title = "Quartz Update Available"
            content.body = "Quartz \(release.version) has been released. Click to view the release."
            content.userInfo = ["releaseURL": release.url.absoluteString]
            // Replace an older notice instead of accumulating stale updates.
            center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
            try await Self.submit(
                UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil),
                to: center
            )
            return true
        } catch {
            return false
        }
    }

    private static func authorizationSettings(for center: UNUserNotificationCenter) async -> QuartzNotificationAuthorization {
        await withCheckedContinuation { continuation in
            // Older SDKs do not mark UNNotificationSettings as Sendable. Read it on
            // the callback's queue and send only immutable values back to the main actor.
            center.getNotificationSettings { @Sendable settings in
                continuation.resume(returning: QuartzNotificationAuthorization(
                    status: settings.authorizationStatus,
                    alertSetting: settings.alertSetting,
                    notificationCenterSetting: settings.notificationCenterSetting
                ))
            }
        }
    }

    private static func requestAuthorization(for center: UNUserNotificationCenter) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: [.alert]) { @Sendable granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private static func submit(_ request: UNNotificationRequest, to center: UNUserNotificationCenter) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { @Sendable error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           response.notification.request.identifier == "Quartz.updateAvailable",
           let value = response.notification.request.content.userInfo["releaseURL"] as? String,
           let url = Self.releaseURL(from: value) {
            Task { @MainActor [weak self] in self?.openRelease(url) }
        }
        completionHandler()
    }

    /// Revalidate persisted notification data before opening it after a relaunch.
    nonisolated static func releaseURL(from value: String) -> URL? {
        guard let url = URL(string: value),
              url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/QuartzBrowser/Quartz/releases/tag/"),
              url.pathComponents.count == 6,
              let canonicalURL = QuartzUpdateClient.releasePageURL(for: url.lastPathComponent),
              canonicalURL.absoluteString == url.absoluteString
        else { return nil }
        return url
    }
}
