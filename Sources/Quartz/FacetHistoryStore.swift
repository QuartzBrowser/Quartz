import Foundation

/// Completed Facet conversations retained locally for Curiosity Spark personalization.
/// Callers supply original prompts and replies, never assembled page context or errors.
@MainActor
final class FacetHistoryStore {
    static let storageKey = "Facet.personalization.history.v1"
    static let maximumExchangeCount = 100
    static let maximumMessageCharacters = 4_000

    private let defaults: UserDefaults
    private var exchanges: [Exchange]
    private(set) var messages: [FacetChatMessage]

    private struct Exchange: Codable {
        let userPrompt: String
        let assistantReply: String

        var messages: [FacetChatMessage] {
            [FacetChatMessage(role: "user", content: userPrompt),
             FacetChatMessage(role: "assistant", content: assistantReply)]
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([Exchange].self, from: $0) } ?? []
        exchanges = Array(saved.compactMap {
            Self.normalizedExchange(userPrompt: $0.userPrompt, assistantReply: $0.assistantReply)
        }.suffix(Self.maximumExchangeCount))
        messages = exchanges.flatMap(\.messages)
        persist()
    }

    func appendExchange(userPrompt: String, assistantReply: String) {
        guard let exchange = Self.normalizedExchange(userPrompt: userPrompt, assistantReply: assistantReply) else {
            return
        }
        exchanges.append(exchange)
        exchanges = Array(exchanges.suffix(Self.maximumExchangeCount))
        messages = exchanges.flatMap(\.messages)
        persist()
    }

    func clear() {
        exchanges.removeAll()
        messages.removeAll()
        defaults.removeObject(forKey: Self.storageKey)
    }

    private static func normalizedExchange(userPrompt: String, assistantReply: String) -> Exchange? {
        let prompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = assistantReply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !reply.isEmpty else { return nil }
        return Exchange(
            userPrompt: String(prompt.prefix(maximumMessageCharacters)),
            assistantReply: String(reply.prefix(maximumMessageCharacters))
        )
    }

    private func persist() {
        guard !exchanges.isEmpty else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(exchanges) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
