import Foundation

struct QuartzUpdateRelease: Equatable, Sendable {
    let version: String
    let url: URL
}

enum QuartzUpdateError: LocalizedError, Equatable, Sendable {
    case invalidCurrentVersion
    case invalidResponse
    case httpStatus(Int)
    case connection

    var errorDescription: String? {
        switch self {
        case .invalidCurrentVersion:
            return "Quartz could not read this app's version."
        case .invalidResponse:
            return "GitHub returned unreadable release information. Please try again later."
        case let .httpStatus(status):
            if status == 403 || status == 429 {
                return "GitHub is limiting update checks. Please try again later."
            }
            return "Quartz could not check for updates (HTTP \(status)). Please try again later."
        case .connection:
            return "Quartz could not connect to GitHub. Check your internet connection and try again."
        }
    }
}

final class QuartzUpdateClient: Sendable {
    private let session: URLSession
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/QuartzBrowser/Quartz/releases/latest")!
    private static let releasePageBaseURL = URL(string: "https://github.com/QuartzBrowser/Quartz/releases/tag")!

    init(session: URLSession = QuartzUpdateClient.makeSession()) {
        self.session = session
    }

    static func releasePageURL(for tag: String) -> URL? {
        guard ReleaseVersion(tag) != nil else { return nil }
        return releasePageBaseURL.appendingPathComponent(tag)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }

    func latestUpdate(currentVersion: String) async throws -> QuartzUpdateRelease? {
        try Task.checkCancellation()
        guard let current = ReleaseVersion(currentVersion) else {
            throw QuartzUpdateError.invalidCurrentVersion
        }

        var request = URLRequest(url: Self.latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Quartz/\(current.normalized)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw QuartzUpdateError.connection
        }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw QuartzUpdateError.invalidResponse }
        // A repository without a published release returns 404, not an empty release object.
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else { throw QuartzUpdateError.httpStatus(response.statusCode) }
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
            throw QuartzUpdateError.invalidResponse
        }
        guard !release.draft, !release.prerelease else { return nil }
        guard let version = ReleaseVersion(release.tagName),
              let url = Self.releasePageURL(for: release.tagName) else { throw QuartzUpdateError.invalidResponse }
        guard version.isNewerStableRelease(than: current) else { return nil }

        // Construct the destination from a validated tag, never a server-provided link.
        return QuartzUpdateRelease(
            version: version.normalized,
            url: url
        )
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft, prerelease
        }
    }

    /// SemVer validation also limits release tags to characters safe for a single URL path component.
    private struct ReleaseVersion {
        let normalized: String
        private let core: [Substring]
        private let hasPrerelease: Bool

        init?(_ value: String) {
            let normalized = value.hasPrefix("v") ? String(value.dropFirst()) : value
            let metadataParts = normalized.split(separator: "+", omittingEmptySubsequences: false)
            guard metadataParts.count <= 2 else { return nil }
            if metadataParts.count == 2 {
                guard Self.validIdentifiers(metadataParts[1], requireCanonicalNumbers: false) else { return nil }
            }
            let versionParts = metadataParts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let core = versionParts[0].split(separator: ".", omittingEmptySubsequences: false)
            guard core.count == 3, core.allSatisfy(Self.isCanonicalNumber) else { return nil }
            if versionParts.count == 2 {
                guard Self.validIdentifiers(versionParts[1], requireCanonicalNumbers: true) else { return nil }
            }
            self.normalized = normalized
            self.core = core
            hasPrerelease = versionParts.count == 2
        }

        func isNewerStableRelease(than current: Self) -> Bool {
            guard !hasPrerelease else { return false }
            for (candidate, installed) in zip(core, current.core) where candidate != installed {
                // Compare digit counts before lexicographic order to avoid integer overflow.
                return candidate.count == installed.count ? candidate > installed : candidate.count > installed.count
            }
            // A stable version follows its prereleases. Build metadata never affects precedence.
            return current.hasPrerelease
        }

        private static func validIdentifiers(_ value: Substring, requireCanonicalNumbers: Bool) -> Bool {
            value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { identifier in
                guard !identifier.isEmpty, identifier.utf8.allSatisfy({ byte in
                    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45
                }) else { return false }
                return !requireCanonicalNumbers || !isNumber(identifier) || isCanonicalNumber(identifier)
            }
        }

        private static func isNumber(_ value: Substring) -> Bool {
            !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
        }

        private static func isCanonicalNumber(_ value: Substring) -> Bool {
            isNumber(value) && (value.count == 1 || value.first != "0")
        }
    }
}
