import AppKit
import UserNotifications

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
            var settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                // Ask in context, only once an update actually exists.
                guard try await center.requestAuthorization(options: [.alert]) else { return false }
                settings = await center.notificationSettings()
            }
            guard !Task.isCancelled, shouldDeliver(),
                  settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
                  settings.alertSetting == .enabled || settings.notificationCenterSetting == .enabled
            else { return false }

            let content = UNMutableNotificationContent()
            content.title = "Quartz Update Available"
            content.body = "Quartz \(release.version) has been released. Click to view the release."
            content.userInfo = ["releaseURL": release.url.absoluteString]
            // Replace an older notice instead of accumulating stale updates.
            center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
            try await center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
            return true
        } catch {
            return false
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
