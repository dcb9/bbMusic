import Foundation

/// Last.fm credentials, stored in a plain JSON file under Application Support.
///
/// A file rather than the Keychain on purpose: this is a single-user tool on the owner's own Mac,
/// and re-authorizing on every launch is worse than the (local, 0600) exposure. The file never
/// leaves this machine and is never committed — `Scripts/seed-lastfm.sh` writes it.
///
/// The previous Keychain entries are migrated on first read so an existing setup keeps working.
enum LastFMCredentialsStore {
    struct Payload: Codable, Sendable {
        var apiKey: String
        var sharedSecret: String
        var sessionKey: String?
        var username: String?
    }

    private static let fileName = "lastfm.json"

    static func fileURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent(fileName)
    }

    static func load(from url: URL) -> LastFMClient.Credentials? {
        if let data = try? Data(contentsOf: url),
           let payload = try? JSONDecoder().decode(Payload.self, from: data),
           !payload.apiKey.isEmpty,
           !payload.sharedSecret.isEmpty {
            return LastFMClient.Credentials(
                apiKey: payload.apiKey,
                sharedSecret: payload.sharedSecret,
                sessionKey: payload.sessionKey,
                username: payload.username
            )
        }
        // One-time migration from the Keychain-based storage.
        guard let legacy = Keychain.loadLastFMCredentials() else { return nil }
        save(legacy, to: url)
        return legacy
    }

    static func save(_ credentials: LastFMClient.Credentials, to url: URL) {
        let payload = Payload(
            apiKey: credentials.apiKey,
            sharedSecret: credentials.sharedSecret,
            sessionKey: credentials.sessionKey,
            username: credentials.username
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
        // Owner-only: the file holds a secret that can sign requests as this application.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Removes only the session, keeping the application identity.
    static func clearSession(at url: URL) {
        guard let existing = load(from: url) else { return }
        var updated = existing
        updated.sessionKey = nil
        updated.username = nil
        save(updated, to: url)
    }
}
