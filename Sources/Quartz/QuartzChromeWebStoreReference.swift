import Foundation

enum QuartzChromeWebStoreReference {
    static func extensionID(from reference: String) -> String? {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if isExtensionID(reference) { return reference.lowercased() }
        guard !reference.contains(where: { $0.isWhitespace }),
              let url = URL(string: reference) else { return nil }
        return extensionID(fromURL: url)
    }

    static func extensionID(fromURL url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil, components.port == nil,
              let host = components.host?.lowercased() else { return nil }

        let prefix: String
        switch host {
        case "chromewebstore.google.com": prefix = "/detail/"
        case "chrome.google.com": prefix = "/webstore/detail/"
        default: return nil
        }
        let path = components.percentEncodedPath
        guard path.hasPrefix(prefix), !path.contains("%"), !path.contains("\\") else { return nil }
        var remainder = String(path.dropFirst(prefix.count))
        if remainder.hasSuffix("/") { remainder.removeLast() }
        let parts = remainder.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty }),
              let identifier = parts.last, isExtensionID(String(identifier)) else { return nil }
        if parts.count == 2 {
            guard parts[0].unicodeScalars.allSatisfy({
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0)
            }) else { return nil }
        }
        return identifier.lowercased()
    }

    private static func isExtensionID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 32 && bytes.allSatisfy { (65...80).contains($0) || (97...112).contains($0) }
    }
}
