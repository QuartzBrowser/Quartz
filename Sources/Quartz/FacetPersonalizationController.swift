import AppKit

/// One history, generation request, and daily clock shared by all browser windows.
@MainActor
final class FacetPersonalizationController: NSObject {
    let history: FacetHistoryStore
    let sparks: FacetCuriositySparkService
    private let configuration: () -> FacetConfiguration
    private let apiKey: () throws -> String?
    private var observers: [UUID: () -> Void] = [:]
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var hasAPIKey = false

    init(
        defaults: UserDefaults = .standard,
        sparks: FacetCuriositySparkService? = nil,
        configuration: @escaping () -> FacetConfiguration = { FacetPanelView.savedConfiguration() },
        apiKey: @escaping () throws -> String? = {
            let stored = try FacetAPIKeyStore().load()
            let environment = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stored ?? environment.flatMap { $0.isEmpty ? nil : $0 }
        }
    ) {
        history = FacetHistoryStore(defaults: defaults)
        self.sparks = sparks ?? FacetCuriositySparkService(defaults: defaults)
        self.configuration = configuration
        self.apiKey = apiKey
        super.init()
        self.sparks.onChange = { [weak self] in self?.publish() }
    }

    func observe(_ changed: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = changed
        if timer == nil {
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            NotificationCenter.default.addObserver(self, selector: #selector(clockChanged), name: NSApplication.didBecomeActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(clockChanged), name: .NSCalendarDayChanged, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(clockChanged), name: .NSSystemTimeZoneDidChange, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(clockChanged), name: NSWorkspace.didWakeNotification, object: nil)
        }
        refresh()
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
        if observers.isEmpty { stop() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
        sparks.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func clockChanged(_ notification: Notification) {
        refresh()
    }

    func appendExchange(userPrompt: String, assistantReply: String) {
        history.appendExchange(userPrompt: userPrompt, assistantReply: assistantReply)
        refresh()
    }

    func clearHistory() {
        refreshTask?.cancel()
        refreshTask = nil
        history.clear()
        sparks.clear()
        publish()
    }

    func settingsChanged() {
        refreshTask?.cancel()
        refreshTask = nil
        sparks.invalidateRetry()
        refresh()
    }

    func refresh() {
        guard refreshTask == nil else { return }
        // Nothing to personalize yet; avoid even reading Keychain on first launch.
        guard !history.messages.isEmpty else { publish(); return }
        let key = try? apiKey()
        hasAPIKey = key?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let settings = configuration()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.sparks.refreshIfNeeded(history: self.history.messages, configuration: settings, apiKey: key)
            guard !Task.isCancelled else { return }
            self.refreshTask = nil
            self.publish()
        }
    }

    var status: String {
        if history.messages.isEmpty { return "Chat with Facet to personalize your daily sparks." }
        if sparks.isGenerating { return "Facet is finding today’s sparks for you…" }
        if !hasAPIKey { return "Add an OpenRouter key in Facet for personalized daily sparks." }
        if sparks.lastError != nil {
            return sparks.sparks.isEmpty
                ? "Facet couldn’t create today’s sparks. It will try again shortly."
                : "Facet couldn’t refresh. Your saved sparks are still here."
        }
        if let generatedAt = sparks.generatedAt, Calendar.current.isDateInToday(generatedAt) {
            return "Made for you today by Facet · Inspired by your chats"
        }
        return sparks.sparks.isEmpty
            ? "Facet is preparing your personalized daily sparks."
            : "Made for you by Facet · Inspired by your chats"
    }

    private func publish() {
        for changed in Array(observers.values) { changed() }
    }
}
