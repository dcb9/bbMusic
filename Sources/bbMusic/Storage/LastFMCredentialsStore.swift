import Foundation

/// Last.fm credentials, stored in a plain JSON file under Application Support.
///
/// This is the only place they live. The app touches no keychain at all: no `SecItem*` calls, no
/// access prompts, nothing to unlock. The file is owner-only (0600), never leaves this machine and is
/// never committed — `Scripts/seed-lastfm.sh` writes it.
///
/// Nothing is migrated from anywhere: an older build kept these in the keychain, and that code path
/// was removed along with the keychain access itself.
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
        return nil
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
