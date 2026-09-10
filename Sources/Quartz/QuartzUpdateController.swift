import Foundation

enum QuartzUpdateCheckResult: Equatable {
    case available(QuartzUpdateRelease)
    case upToDate(String)
    case unavailableVersion
    case failed
}

/// Coordinates periodic checks and remembers announcements across launches.
@MainActor
final class QuartzUpdateController {
    static let checkInterval: TimeInterval = 60 * 60
    private static let automaticChecksKey = "Quartz.updates.automaticChecks"
    private static let lastCheckKey = "Quartz.updates.lastCheck"
    private static let lastAnnouncedVersionKey = "Quartz.updates.lastAnnouncedVersion"

    private let currentVersion: String?
    private let defaults: UserDefaults
    private let now: () -> Date
    private let fetchUpdate: (String) async throws -> QuartzUpdateRelease?
    private let notify: (QuartzUpdateRelease) async -> Bool
    private let present: (QuartzUpdateCheckResult) -> Bool
    private let checkingChanged: (Bool) -> Void
    private var timer: Timer?
    private var automaticTask: Task<Void, Never>?
    private var isChecking = false
    private var manualCheckRequested = false
    private var stopped = false

    var automaticallyChecksForUpdates: Bool {
        get { defaults.object(forKey: Self.automaticChecksKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.automaticChecksKey) }
    }

    init(
        currentVersion: String?,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        fetchUpdate: @escaping (String) async throws -> QuartzUpdateRelease? = {
            try await QuartzUpdateClient().latestUpdate(currentVersion: $0)
        },
        notify: @escaping (QuartzUpdateRelease) async -> Bool,
        present: @escaping (QuartzUpdateCheckResult) -> Bool,
        checkingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.now = now
        self.fetchUpdate = fetchUpdate
        self.notify = notify
        self.present = present
        self.checkingChanged = checkingChanged
    }

    func start() {
        guard timer == nil else { return }
        stopped = false
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkAutomatically() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        checkAutomatically()
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        automaticTask?.cancel()
        automaticTask = nil
    }

    func checkAutomatically() {
        guard !stopped, automaticTask == nil else { return }
        automaticTask = Task { [weak self] in
            guard let self else { return }
            await self.check()
            self.automaticTask = nil
        }
    }

    func check(manually: Bool = false) async {
        guard !stopped else { return }
        if isChecking {
            // A manual request during a background check should receive its result.
            manualCheckRequested = manualCheckRequested || manually
            return
        }
        guard manually || automaticallyChecksForUpdates else { return }
        guard let currentVersion, !currentVersion.isEmpty else {
            if manually { _ = present(.unavailableVersion) }
            return
        }

        let date = now()
        if !manually, let lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date {
            let elapsed = date.timeIntervalSince(lastCheck)
            // A clock change must not disable checks indefinitely.
            guard elapsed < 0 || elapsed >= Self.checkInterval else { return }
        }

        isChecking = true
        manualCheckRequested = manually
        checkingChanged(true)
        defaults.set(date, forKey: Self.lastCheckKey)
        defer {
            isChecking = false
            manualCheckRequested = false
            checkingChanged(false)
        }

        do {
            let release = try await fetchUpdate(currentVersion)
            guard !stopped, !Task.isCancelled else { return }
            if manualCheckRequested {
                if let release {
                    if present(.available(release)) { remember(release) }
                } else {
                    _ = present(.upToDate(currentVersion))
                }
                return
            }
            guard automaticallyChecksForUpdates, let release,
                  defaults.string(forKey: Self.lastAnnouncedVersionKey) != release.version
            else { return }

            let delivered = await notify(release)
            guard !stopped, !Task.isCancelled else { return }
            if manualCheckRequested {
                if present(.available(release)) || delivered { remember(release) }
                return
            }
            guard automaticallyChecksForUpdates else { return }
            if delivered || present(.available(release)) {
                remember(release)
            }
        } catch {
            if !stopped, !Task.isCancelled, manualCheckRequested {
                _ = present(.failed)
            }
        }
    }

    private func remember(_ release: QuartzUpdateRelease) {
        defaults.set(release.version, forKey: Self.lastAnnouncedVersionKey)
    }
}
