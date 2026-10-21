import CryptoKit
import Foundation

/// Last.fm Web Services client.
///
/// Only the four calls this app needs: `auth.getToken`, `auth.getSession`,
/// `track.updateNowPlaying`, `track.scrobble`. Everything else Last.fm offers is out of scope, so a
/// dependency would cost more than it saves.
///
/// Every call is signed: parameters sorted by name, `key + value` concatenated, shared secret
/// appended, MD5 of the UTF-8 bytes. Verified against the live API.
struct LastFMClient: Sendable {
    struct Credentials: Sendable, Equatable {
        var apiKey: String
        var sharedSecret: String
        var sessionKey: String?
        var username: String?
    }

    /// Last.fm reports auth progress through its own error codes rather than HTTP semantics.
    enum ClientError: LocalizedError, Sendable {
        case notAuthorizedYet
        case invalidSession
        case api(code: Int, message: String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorizedYet: return "还没有在浏览器里确认授权"
            case .invalidSession: return "Last.fm 会话已失效，请重新授权"
            case .api(_, let message): return message
            case .transport(let message): return message
            }
        }
    }

    private static let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    private let credentials: Credentials
    private let session: URLSession

    init(credentials: Credentials) {
        self.credentials = credentials
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Authentication

    /// Step 1: an unauthorized request token. The user must then visit `authorizationURL(token:)`.
    func requestToken() async throws -> String {
        let data = try await call(
            method: "auth.getToken",
            params: [:],
            httpMethod: "GET",
            signed: true,
            requiresSession: false
        )
        guard let token = (data["token"] as? String), !token.isEmpty else {
            throw ClientError.api(code: -1, message: "Last.fm 没有返回 token")
        }
        return token
    }

    static func authorizationURL(apiKey: String, token: String) -> URL? {
        var components = URLComponents(string: "https://www.last.fm/api/auth/")
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "token", value: token),
        ]
        return components?.url
    }

    /// Step 3: exchange an authorized token for a session key.
    ///
    /// Polling before the user confirms returns `error: 14`, which is a normal intermediate state
    /// rather than a failure, so it gets its own error case.
    func createSession(token: String) async throws -> (sessionKey: String, username: String) {
        let data = try await call(
            method: "auth.getSession",
            params: ["token": token],
            httpMethod: "GET",
            signed: true,
            requiresSession: false
        )
        guard let payload = data["session"] as? [String: Any],
              let key = payload["key"] as? String,
              let name = payload["name"] as? String
        else {
            throw ClientError.api(code: -1, message: "Last.fm 没有返回会话")
        }
        return (key, name)
    }

    // MARK: - Scrobbling

    /// Announces the currently playing track. Never affects charts, so a failure is not retried.
    func updateNowPlaying(_ track: ScrobbleRecord) async throws {
        var params: [String: String] = [
            "artist": track.artist,
            "track": track.title,
        ]
        if !track.album.isEmpty { params["album"] = track.album }
        if track.duration > 0 { params["duration"] = String(Int(track.duration.rounded())) }
        _ = try await call(
            method: "track.updateNowPlaying",
            params: params,
            httpMethod: "POST",
            signed: true,
            requiresSession: true
        )
    }

    /// Submits one or more played tracks. Last.fm accepts up to 50 per batch.
    func scrobble(_ tracks: [ScrobbleRecord]) async throws {
        guard !tracks.isEmpty else { return }
        var params: [String: String] = [:]
        for (index, track) in tracks.prefix(50).enumerated() {
            // Array notation is required for batches; parameter names are sorted ASCII-wise, which
            // the signature below handles generically.
            params["artist[\(index)]"] = track.artist
            params["track[\(index)]"] = track.title
            params["timestamp[\(index)]"] = String(Int(track.startedAt.timeIntervalSince1970))
            if !track.album.isEmpty { params["album[\(index)]"] = track.album }
            if track.duration > 0 { params["duration[\(index)]"] = String(Int(track.duration.rounded())) }
        }
        _ = try await call(
            method: "track.scrobble",
            params: params,
            httpMethod: "POST",
            signed: true,
            requiresSession: true
        )
    }

    // MARK: - Transport

    private func call(
        method: String,
        params: [String: String],
        httpMethod: String,
        signed: Bool,
        requiresSession: Bool
    ) async throws -> [String: Any] {
        var fields = params
        fields["method"] = method
        fields["api_key"] = credentials.apiKey
        fields["format"] = "json"
        if requiresSession {
            guard let key = credentials.sessionKey, !key.isEmpty else {
                throw ClientError.invalidSession
            }
            fields["sk"] = key
        }
        // `api_sig` and `format` are excluded from the signature, per Last.fm's spec.
        if signed {
            fields["api_sig"] = Self.signature(for: fields, secret: credentials.sharedSecret)
        }

        let url: URL
        var request: URLRequest
        if httpMethod == "GET" {
            var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)
            components?.queryItems = fields
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let built = components?.url else {
                throw ClientError.transport("无法构造请求地址")
            }
            url = built
            request = URLRequest(url: url)
        } else {
            url = Self.endpoint
            request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8",
                             forHTTPHeaderField: "Content-Type")
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            let body = fields
                .map { key, value in
                    let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                    let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                    return "\(encodedKey)=\(encodedValue)"
                }
                .joined(separator: "&")
            request.httpBody = Data(body.utf8)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClientError.transport(error.localizedDescription)
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let code = json["error"] as? Int ?? http.statusCode
            let message = json["message"] as? String ?? "Last.fm 返回 \(http.statusCode)"
            switch code {
            case 14: throw ClientError.notAuthorizedYet
            case 9: throw ClientError.invalidSession
            default: throw ClientError.api(code: code, message: message)
            }
        }
        // Last.fm can also report failures inside a 200 body.
        if let code = json["error"] as? Int {
            switch code {
            case 14: throw ClientError.notAuthorizedYet
            case 9: throw ClientError.invalidSession
            default: throw ClientError.api(code: code, message: json["message"] as? String ?? "Last.fm 错误 \(code)")
            }
        }
        return json
    }

    /// `md5(concat(sorted(key + value)) + secret)`, skipping `api_sig` and `format`.
    static func signature(for fields: [String: String], secret: String) -> String {
        let payload = fields
            .filter { $0.key != "api_sig" && $0.key != "format" }
            .sorted { $0.key < $1.key }
            .map { $0.key + $0.value }
            .joined() + secret
        let digest = Insecure.MD5.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// One played track, ready to submit.
struct ScrobbleRecord: Codable, Hashable, Sendable {
    let trackID: String
    let artist: String
    let title: String
    let album: String
    let duration: TimeInterval
    let startedAt: Date

    /// Retry/restart/backfill all dedupe on this pair, so a track is never counted twice.
    var idempotencyKey: String {
        "\(trackID)@\(Int(startedAt.timeIntervalSince1970))"
    }
}
