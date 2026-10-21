import Foundation

/// QQ Music adapter. The only type in the app that knows QQ Music exists: it speaks the sidecar's
/// HTTP dialect and maps the responses into the shared models.
///
/// Endpoint shapes here were verified against a live sidecar (see `architecture-design.md`); the
/// QQ Music API is a third-party reverse-engineered service, so this file is the blast radius when
/// it changes.
final class QQMusicPlatform: MusicPlatform, @unchecked Sendable {
    let id = "qqmusic"
    let displayName = "QQ 音乐"

    private let session: URLSession
    private let baseURLProvider: @MainActor () -> URL?
    private var sessionToken: String?

    init(baseURLProvider: @escaping @MainActor () -> URL?) {
        self.baseURLProvider = baseURLProvider
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Connection

    func connectionState() async -> PlatformConnectionState {
        do {
            let data = try await get("/login/status", query: [])
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .disconnected
            }
            // The sidecar reports 200 with an empty `data` object when nobody is signed in.
            if let payload = root["data"] as? [String: Any], !payload.isEmpty {
                let name = (payload["nickname"] as? String)
                    ?? (payload["nick"] as? String)
                    ?? "已登录"
                return .connected(displayName: name)
            }
            return .disconnected
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Starts a QR sign-in and returns the challenge for the UI to render and poll.
    func beginQRLogin(channel: QRChannel = .qqmusic) async throws -> QRChallenge {
        let keyData = try await get("/login/qr/key", query: [.init(name: "channel", value: channel.rawValue)])
        guard let keyRoot = try JSONSerialization.jsonObject(with: keyData) as? [String: Any],
              let keyPayload = keyRoot["data"] as? [String: Any],
              let unikey = (keyPayload["unikey"] as? String) ?? (keyPayload["key"] as? String)
        else {
            throw PlatformError("无法获取登录二维码标识")
        }

        let imageData = try await get("/login/qr/create", query: [.init(name: "key", value: unikey)])
        guard let imageRoot = try JSONSerialization.jsonObject(with: imageData) as? [String: Any],
              let imagePayload = imageRoot["data"] as? [String: Any],
              let dataURL = imagePayload["qrimg"] as? String,
              let image = QRChallenge.image(from: dataURL)
        else {
            throw PlatformError("无法生成登录二维码")
        }
        return QRChallenge(unikey: unikey, image: image)
    }

    /// Polls a QR challenge. QQ Music answers with 801/802/803/800 in the `code` field.
    func pollQRLogin(_ challenge: QRChallenge) async throws -> QRStatus {
        let data = try await get("/login/qr/check", query: [.init(name: "key", value: challenge.unikey)])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = root["code"] as? Int
        else {
            throw PlatformError("登录状态响应异常")
        }
        switch code {
        case 801: return .waiting
        case 802: return .scanned
        case 803: return .authorized
        default:
            let hint = (root["failureHint"] as? [String: Any])?["message"] as? String
                ?? (root["message"] as? String)
                ?? "二维码已过期，请重新获取"
            return .failed(hint)
        }
    }

    func cancelQRLogin(_ challenge: QRChallenge) async {
        _ = try? await get("/login/qr/cancel", query: [.init(name: "key", value: challenge.unikey)])
    }

    func signIn() async throws -> PlatformConnectionState {
        await connectionState()
    }

    func signOut() async throws {
        _ = try? await get("/logout", query: [])
        sessionToken = nil
    }

    // MARK: - Catalog

    func search(_ query: String) async throws -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let data = try await get("/search", query: [
            .init(name: "keyword", value: trimmed),
            .init(name: "type", value: "song"),
            .init(name: "page", value: "1"),
            .init(name: "limit", value: "50"),
        ])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]]
        else { return [] }
        return items.compactMap(Self.track(from:))
    }

    func streamSource(for track: Track, quality: AudioQuality) async throws -> StreamSource {
        let requested = quality == .best ? "best" : quality.rawValue
        let fullData = try await get("/getMusicPlay/\(track.id)",
                                     query: [.init(name: "quality", value: requested)])
        let full = Self.playback(from: fullData, mid: track.id)
        if let url = full.url {
            return .url(Self.secureURL(url))
        }

        // A full stream was refused. QQ Music usually still offers a trial clip; fetch it so the
        // user hears something and the UI can label it honestly instead of showing a dead player.
        let previewData = try? await get("/getMusicPlay/\(track.id)", query: [
            .init(name: "quality", value: "128"),
            .init(name: "preview", value: "1"),
        ])
        if let previewData, let url = Self.playback(from: previewData, mid: track.id).url {
            return .preview(Self.secureURL(url))
        }
        throw PlatformError(full.reason ?? "这首歌暂时无法播放")
    }

    /// QQ Music hands out `http://` media URLs. AVFoundation loads media out of process, so the
    /// app's App Transport Security exceptions do not apply to it and a plain-http asset fails with
    /// `-1022` inside any app bundle (verified: the same URL plays from a bare CLI binary and fails
    /// from inside the .app, while its `https` twin plays in both). The CDNs serve TLS fine, so
    /// upgrade the scheme here rather than weakening transport security.
    private static func secureURL(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.scheme = "https"
        return components.url ?? url
    }

    func lyrics(for track: Track) async throws -> Lyrics {
        let data = try await get("/getLyric", query: [
            .init(name: "songmid", value: track.id),
            .init(name: "trans", value: "1"),
        ])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }
        // The legacy endpoint wraps its payload in `response`.
        let payload = (root["response"] as? [String: Any]) ?? root
        let raw = (payload["lyric"] as? String) ?? ""
        let translation = (payload["trans"] as? String) ?? ""
        return LRCParser.parse(lyric: raw, translation: translation)
    }

    // MARK: - Response mapping

    private static func track(from item: [String: Any]) -> Track? {
        guard let mid = (item["mid"] as? String) ?? (item["songmid"] as? String) else { return nil }
        let title = (item["title"] as? String) ?? (item["name"] as? String) ?? (item["songname"] as? String) ?? "未知曲目"
        let singers = (item["singer"] as? [[String: Any]]) ?? []
        let artist = singers.compactMap { ($0["name"] as? String) ?? ($0["title"] as? String) }
            .joined(separator: " / ")
        let albumDict = item["album"] as? [String: Any]
        let album = (albumDict?["name"] as? String) ?? ""
        let albumMid = albumDict?["mid"] as? String
        let interval = (item["interval"] as? Double) ?? Double(item["interval"] as? Int ?? 0)

        var artwork: URL?
        if let albumMid, !albumMid.isEmpty {
            artwork = URL(string: "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(albumMid).jpg")
        }

        // `pay.pay_play == 1` means the track is playable by the current account; without a
        // session that still resolves to false, which is what we want to show.
        let pay = item["pay"] as? [String: Any]
        let isPlayable = (pay?["pay_play"] as? Int ?? 0) == 0

        return Track(
            id: mid,
            title: title,
            artist: artist.isEmpty ? "未知歌手" : artist,
            album: album,
            duration: interval,
            artworkURL: artwork,
            isPlayable: isPlayable
        )
    }

    private static func playback(from data: Data, mid: String) -> (url: URL?, reason: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let playURL = payload["playUrl"] as? [String: Any],
              let entry = playURL[mid] as? [String: Any]
        else { return (nil, nil) }

        if let raw = entry["url"] as? String, !raw.isEmpty, let url = URL(string: raw) {
            return (url, nil)
        }
        let restriction = entry["restriction"] as? [String: Any]
        let hint = (restriction?["hint"] as? [String: Any])?["message"] as? String
        let reason = (entry["error"] as? String) ?? hint ?? "这首歌暂时无法播放"
        return (nil, reason)
    }

    // MARK: - Transport

    private struct Query {
        let name: String
        let value: String
        init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    private func get(_ path: String, query: [Query]) async throws -> Data {
        guard let baseURL = await baseURLProvider() else {
            throw PlatformError("QQ 音乐服务未就绪")
        }
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                             resolvingAgainstBaseURL: false) else {
            throw PlatformError("请求地址无效")
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.name, value: $0.value) }
        }
        guard let url = components.url else { throw PlatformError("请求地址无效") }

        var request = URLRequest(url: url)
        if let sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: "X-QQ-Session")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlatformError("服务响应异常")
        }
        if http.statusCode >= 400 {
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = root["message"] as? String {
                throw PlatformError(message)
            }
            throw PlatformError("服务返回 \(http.statusCode)")
        }
        return data
    }
}

// MARK: - QR login types

enum QRChannel: String, CaseIterable, Sendable {
    case qqmusic, qq, wechat

    var label: String {
        switch self {
        case .qqmusic: return "QQ 音乐 App"
        case .qq: return "手机 QQ"
        case .wechat: return "微信"
        }
    }
}

struct QRChallenge: Sendable {
    let unikey: String
    let image: Data

    /// The sidecar returns the QR as a `data:` URL whose MIME type is not guaranteed to be PNG, so
    /// decode whatever is actually there instead of assuming.
    static func image(from dataURL: String) -> Data? {
        guard let comma = dataURL.firstIndex(of: ",") else { return nil }
        let base64 = String(dataURL[dataURL.index(after: comma)...])
        return Data(base64Encoded: base64)
    }
}

enum QRStatus: Equatable, Sendable {
    case waiting
    case scanned
    case authorized
    case failed(String)
}
