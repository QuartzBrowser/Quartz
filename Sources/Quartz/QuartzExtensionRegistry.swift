import Foundation

struct QuartzExtensionRecord: Codable, Equatable {
    let path: String
    var displayName: String
    var isEnabled: Bool
    var contextIdentifier: String? = nil
    var approvedPermissions: Set<String> = []
    var approvedMatchPatterns: Set<String> = []
}

struct QuartzExtensionRegistry {
    private let defaults: UserDefaults
    private let recordsKey = "QuartzExtensionRecords"
    private let legacyPathsKey = "QuartzInstalledExtensionPaths"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func read() -> [QuartzExtensionRecord] {
        if let data = defaults.data(forKey: recordsKey),
           let records = try? JSONDecoder().decode([QuartzExtensionRecord].self, from: data) {
            return records
        }
        // Existing installations require consent once before their first load after migration.
        return Array(Set(defaults.stringArray(forKey: legacyPathsKey) ?? [])).sorted().map {
            QuartzExtensionRecord(path: $0, displayName: URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent, isEnabled: true)
        }
    }

    func write(_ records: [QuartzExtensionRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: recordsKey)
        defaults.set(records.map(\.path), forKey: legacyPathsKey)
    }

    /// Only direct children of Quartz's copied storage may be removed. Symlink targets outside it are never owned.
    static func ownedRemovalURL(for path: String, storageDirectory: URL) -> URL? {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let directory = storageDirectory.standardizedFileURL
        guard candidate.deletingLastPathComponent().path == directory.path,
              candidate.resolvingSymlinksInPath().deletingLastPathComponent().path
                == directory.resolvingSymlinksInPath().path else { return nil }
        return candidate
    }
}
