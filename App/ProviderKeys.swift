import JammerAssistant

/// Every cloud provider Jämmer can use with the user's own key, by its Keychain slug (PROVIDERS.md, rule 1):
/// the assistant's text providers, and the speech services. One list for the API's key status.
@MainActor
enum ProviderKeys {
    static var slugs: [String] {
        var out = TextProvider.all.map(\.id)
        for s in ["openai", "berget", "elevenlabs"] where !out.contains(s) { out.append(s) }
        return out
    }

    /// Whether each provider has a key saved. Never the key itself.
    static var status: [String: Bool] {
        Dictionary(uniqueKeysWithValues: slugs.map { ($0, Keychain.get($0) != nil) })
    }
}
