import Foundation

/// Experimental features are opt-in and shared by windows using the same defaults suite.
@MainActor
final class QuartzFeatureFlags {
    static let didChangeNotification = Notification.Name("QuartzFeatureFlagsDidChange")
    static let webMCPDefaultsKey = "quartz.flags.webmcp.enabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isWebMCPEnabled: Bool {
        defaults.bool(forKey: Self.webMCPDefaultsKey)
    }

    func setWebMCPEnabled(_ enabled: Bool) {
        guard enabled != isWebMCPEnabled else { return }
        defaults.set(enabled, forKey: Self.webMCPDefaultsKey)
        // Observers revoke access before the action that changed the flag returns.
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
