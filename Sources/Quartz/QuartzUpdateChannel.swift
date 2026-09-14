import Foundation

/// Stable releases use Sparkle's default (unlabelled) channel. Beta is additive,
/// so testers also receive compatible stable releases with a newer build number.
enum QuartzUpdateChannel: String, CaseIterable {
    case stable
    case beta

    static let preferenceKey = "Quartz.updates.channel"

    static func selected(in defaults: UserDefaults) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .stable
    }

    var title: String { self == .stable ? "Stable" : "Beta" }
    var sparkleChannels: Set<String> { self == .beta ? ["beta"] : [] }

    func allows(_ appcastChannel: String?) -> Bool {
        guard let appcastChannel, !appcastChannel.isEmpty else { return true }
        return sparkleChannels.contains(appcastChannel)
    }

    var explanation: String {
        switch self {
        case .stable:
            "Quartz will receive the next compatible stable release newer than your installed version. Changing channels does not downgrade the installed app."
        case .beta:
            "Quartz will offer beta releases as well as newer stable releases. Beta releases may have unfinished features or bugs. Updates still require Update & Restart."
        }
    }
}

enum QuartzReleaseIdentity {
    static func displayVersion(in bundle: Bundle) -> String {
        for key in ["QuartzReleaseVersion", "CFBundleShortVersionString", "CFBundleVersion"] {
            if let value = bundle.object(forInfoDictionaryKey: key) as? String, !value.isEmpty {
                return value
            }
        }
        return "Development"
    }
}
