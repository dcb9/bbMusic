import Foundation
import Security

/// Keychain-backed storage for Last.fm credentials.
///
/// The API key and shared secret live here rather than in source: the secret is enough to sign
/// requests as this application, so it must not sit in a file that gets committed or in a binary
/// that `strings` can read. A fresh checkout therefore ships placeholder values and stores whatever
/// it is given on first use.
enum Keychain {
    private static let service = "local.bbmusic.lastfm"

    private enum Account: String, CaseIterable {
        case apiKey
        case sharedSecret
        case sessionKey
        case username
    }

    // MARK: - Last.fm credentials

    static func loadLastFMCredentials() -> LastFMClient.Credentials? {
        guard let apiKey = read(.apiKey), !apiKey.isEmpty,
              let secret = read(.sharedSecret), !secret.isEmpty
        else { return nil }
        return LastFMClient.Credentials(
            apiKey: apiKey,
            sharedSecret: secret,
            sessionKey: read(.sessionKey),
            username: read(.username)
        )
    }

    /// Persists the API pair, seeding it with `fallback` when the keychain is empty.
    ///
    /// The pair is what identifies the application to Last.fm, so it is stored once and then left
    /// alone; re-seeding on every launch would silently discard a user's own key.
    @discardableResult
    static func ensureLastFMApp(apiKey fallbackKey: String, sharedSecret fallbackSecret: String) -> LastFMClient.Credentials? {
        if let existing = loadLastFMCredentials() { return existing }
        guard !fallbackKey.isEmpty, !fallbackSecret.isEmpty else { return nil }
        write(.apiKey, fallbackKey)
        write(.sharedSecret, fallbackSecret)
        return loadLastFMCredentials()
    }

    static func saveSession(key: String, username: String) {
        write(.sessionKey, key)
        write(.username, username)
    }

    static func clearSession() {
        delete(.sessionKey)
        delete(.username)
    }

    // MARK: - Primitives

    private static func read(_ account: Account) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ account: Account, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        let data = Data(value.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = base
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    private static func delete(_ account: Account) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
