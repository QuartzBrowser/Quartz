import Foundation
import LocalAuthentication
import Security

struct FacetAPIKeyStore {
    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Quartz.Facet.OpenRouter",
            kSecAttrAccount as String: "api-key"
        ]
    }

    func load() throws -> String? {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true

        var query = itemQuery
        query[kSecUseAuthenticationContext as String] = authenticationContext
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw FacetAPIKeyStoreError.keychain(operation: "read", status: status)
        }
        guard let data = result as? Data,
              let apiKey = String(data: data, encoding: .utf8)
        else {
            throw FacetAPIKeyStoreError.invalidStoredKey
        }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw FacetAPIKeyStoreError.invalidStoredKey
        }
        return trimmedKey
    }

    func save(_ apiKey: String) throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw FacetAPIKeyStoreError.emptyKey
        }

        let attributes = [kSecValueData as String: Data(trimmedKey.utf8)]
        let query = itemQuery
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = attributes[kSecValueData as String]
            newItem[kSecAttrLabel as String] = "Facet OpenRouter API key"
            status = SecItemAdd(newItem as CFDictionary, nil)

            // Another Quartz process may have added the item after the update.
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }

        guard status == errSecSuccess else {
            throw FacetAPIKeyStoreError.keychain(operation: "save", status: status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(itemQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FacetAPIKeyStoreError.keychain(operation: "remove", status: status)
        }
    }
}

private enum FacetAPIKeyStoreError: LocalizedError {
    case emptyKey
    case invalidStoredKey
    case keychain(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            return "Enter an OpenRouter API key before saving."
        case .invalidStoredKey:
            return "The saved OpenRouter API key could not be read. Save a replacement key or remove it."
        case let .keychain(operation, status):
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
            return "Could not \(operation) the OpenRouter API key in Keychain: \(reason) (\(status))."
        }
    }
}
