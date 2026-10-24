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
    /// Where the session token is kept so the app can re-attach to the sidecar's persisted login
    /// after a restart. The sidecar owns the credentials; this is only the key that unlocks them.
    private let tokenURL: URL?
    private var sessionToken: String?

    init(baseURLProvider: @escaping @MainActor () -> URL?, tokenURL: URL? = nil) {
        self.baseURLProvider = baseURLProvider
        self.tokenURL = tokenURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
        if let tokenURL,
           let stored = try? String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            self.sessionToken = stored
        }
    }

    /// Remembers the token handed out when a QR login completes.
    ///
    /// The sidecar sets it as an HttpOnly cookie, which a URLSession without a cookie store would
    /// silently drop — and without it every authenticated call answers 401 even though the login
    /// succeeded.
    private func adoptSessionToken(_ token: String) {
        sessionToken = token
        guard let tokenURL else { return }
        try? token.write(to: tokenURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
    }

    private func clearSessionToken() {
        sessionToken = nil
        if let tokenURL { try? FileManager.default.removeItem(at: tokenURL) }
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
        let (data, response) = try await getWithResponse(
            "/login/qr/check",
            query: [.init(name: "key", value: challenge.unikey)]
        )
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = root["code"] as? Int
        else {
            throw PlatformError("登录状态响应异常")
        }
        // 803 carries the session token in a Set-Cookie header; everything after login depends on
        // holding on to it.
        if code == 803,
           let token = Self.sessionToken(from: response),
           !token.isEmpty {
            adoptSessionToken(token)
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
        clearSessionToken()
    }

    // MARK: - Catalog

    func search(_ query: String) async throws -> [Track] {
        try await search(query, kind: .song, page: 1).songs
    }

    func search(_ query: String, kind: SearchKind, page: Int = 1) async throws -> SearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SearchResults(kind: kind) }
        let pageSize = 50
        let data = try await get("/search", query: [
            .init(name: "keyword", value: trimmed),
            .init(name: "type", value: kind.rawValue),
            .init(name: "page", value: String(page)),
            .init(name: "limit", value: String(pageSize)),
        ])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlatformError("搜索响应不是 JSON")
        }
        // A missing `items` array is a real upstream failure, not an empty search: say so instead of
        // rendering "no results" for what is actually an error.
        guard let items = root["items"] as? [[String: Any]] else {
            let code = root["code"] as? Int ?? -1
            let message = (root["message"] as? String) ?? "上游没有返回结果列表"
            throw PlatformError("搜索失败（code \(code)）：\(message)")
        }

        let total = (root["total"] as? Int) ?? 0
        let reportedPage = (root["page"] as? Int) ?? page
        var results = SearchResults(kind: kind)
        results.totalAvailable = total
        // `more` is the upstream's own answer; the page arithmetic is a fallback for when it lies.
        let more = (root["more"] as? Bool) ?? (reportedPage * pageSize < total)
        results.nextPage = more && !items.isEmpty ? reportedPage + 1 : nil
        switch kind {
        case .song:
            results.songs = items.compactMap(Self.track(from:))
        case .album:
            results.albums = items.compactMap(Self.searchAlbum(from:))
        case .playlist:
            results.playlists = items.compactMap(Self.searchPlaylist(from:))
        case .singer:
            results.artists = items.compactMap(Self.artist(from:))
        }
        return results
    }

    /// Everything the platform knows about a playlist, from the same endpoint that serves its tracks.
    ///
    /// The legacy payload carries far more than a name: description, owner, tags, play and comment
    /// counts, creation time. The page shows what came back and drops the rest.
    func playlistDetails(_ playlist: Playlist) async throws -> PlaylistDetails {
        try await playlistDetails(disstid: playlist.id, fallbackName: playlist.name)
    }

    func playlistDetails(_ playlist: SearchPlaylist) async throws -> PlaylistDetails {
        try await playlistDetails(disstid: playlist.id, fallbackName: playlist.name)
    }

    private func playlistDetails(disstid: String, fallbackName: String) async throws -> PlaylistDetails {
        let data = try await get("/getSongListDetail", query: [
            .init(name: "disstid", value: disstid),
            .init(name: "song_begin", value: "0"),
            .init(name: "song_num", value: "1"),
        ])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return PlaylistDetails(name: fallbackName)
        }
        let payload = (root["response"] as? [String: Any]) ?? root
        guard let head = (payload["cdlist"] as? [[String: Any]])?.first else {
            return PlaylistDetails(name: fallbackName)
        }
        var created: Date?
        if let raw = head["ctime"] as? Int, raw > 0 {
            created = Date(timeIntervalSince1970: TimeInterval(raw))
        }
        return PlaylistDetails(
            name: Self.text(head["dissname"]) ?? fallbackName,
            creator: Self.text(head["nickname"]) ?? Self.text(head["nick"]),
            summary: Self.text(head["desc"]),
            trackCount: (head["total_song_num"] as? Int) ?? (head["songnum"] as? Int),
            playCount: head["visitnum"] as? Int,
            commentCount: head["cmtnum"] as? Int,
            createdAt: created,
            tags: ((head["tags"] as? [[String: Any]]) ?? [])
                .compactMap { Self.text($0["name"]) ?? Self.text($0["tag"]) },
            artworkURL: Self.text(head["logo"]).flatMap(Self.secureImageURL)
        )
    }

    func tracks(inSearchPlaylist playlist: SearchPlaylist) async throws -> [Track] {
        let data = try await get("/getSongListDetail", query: [
            .init(name: "disstid", value: playlist.id),
            .init(name: "song_begin", value: "0"),
            .init(name: "song_num", value: "1000"),
        ])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        // The legacy endpoint nests the tracks two levels down, inside `cdlist[0]`; there is no
        // top-level `songlist`, so looking for one silently yields an empty playlist.
        let payload = (root["response"] as? [String: Any]) ?? root
        var songs: [[String: Any]] = []
        if let discs = payload["cdlist"] as? [[String: Any]] {
            for disc in discs {
                songs.append(contentsOf: (disc["songlist"] as? [[String: Any]]) ?? [])
            }
        }
        if songs.isEmpty {
            songs = (payload["songlist"] as? [[String: Any]])
                ?? ((payload["data"] as? [String: Any])?["songlist"] as? [[String: Any]])
                ?? []
        }
        return songs.compactMap(Self.track(from:))
    }

    func songs(by artist: Artist) async throws -> ArtistSongs {
        // The route reads `mid`, not `singermid`; the latter silently fails validation.
        let data = try await get("/singer/songs", query: [
            .init(name: "mid", value: artist.id),
            .init(name: "page", value: "1"),
            .init(name: "limit", value: "100"),
        ])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ArtistSongs(tracks: [], total: nil)
        }
        let items = (root["songs"] as? [[String: Any]])
            ?? (root["items"] as? [[String: Any]])
            ?? ((root["data"] as? [String: Any])?["list"] as? [[String: Any]])
            ?? []
        // `total` is the artist's real song count (the page itself holds 30). This is the only place
        // the number is available — `/singer/detail` does not report counts at all.
        return ArtistSongs(tracks: items.compactMap(Self.track(from:)), total: root["total"] as? Int)
    }

    /// The profile: a name, a picture and a biography.
    ///
    /// Deliberately leaves the counts alone — this endpoint does not report them (verified: the
    /// payload is `mid/name/id/pic/desc/wiki/foreignName/birthday`), so the counts come from the
    /// song and album listings instead.
    func artistDetail(_ artist: Artist) async throws -> Artist {
        let data = try await get("/singer/detail", query: [.init(name: "mid", value: artist.id)])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let singer = root["singer"] as? [String: Any]
        else { return artist }
        return Artist(
            id: artist.id,
            name: (singer["name"] as? String) ?? artist.name,
            songCount: artist.songCount,
            albumCount: artist.albumCount,
            artworkURL: (singer["pic"] as? String).flatMap(Self.secureImageURL) ?? artist.artworkURL,
            bio: (singer["desc"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func albums(by artist: Artist) async throws -> ArtistAlbums {
        // Despite the `/:singermid?/:limit?/:page?` path template, the handler reads *query*
        // parameters — passing them in the path returns `no singermid`.
        let data = try await get("/getSingerAlbum", query: [
            .init(name: "singermid", value: artist.id),
            .init(name: "limit", value: "50"),
            .init(name: "page", value: "0"),
        ])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let payload = response["singer"] as? [String: Any],
              let inner = payload["data"] as? [String: Any],
              let list = inner["albumList"] as? [[String: Any]]
        else { return ArtistAlbums(albums: [], total: nil) }
        let albums = list.compactMap { entry -> Album? in
            guard let mid = entry["albumMid"] as? String, !mid.isEmpty else { return nil }
            var year: Int?
            if let raw = entry["publishDate"] as? String, let value = Int(raw.prefix(4)), value > 1000 {
                year = value
            }
            return Album(
                id: mid,
                name: (entry["albumName"] as? String) ?? "未知专辑",
                artist: (entry["singerName"] as? String) ?? artist.name,
                trackCount: (entry["totalNum"] as? Int) ?? 0,
                artworkURL: URL(string: "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(mid).jpg"),
                year: year
            )
        }
        // `total` is the artist's real album count; `albumList` holds only this page.
        return ArtistAlbums(albums: albums, total: inner["total"] as? Int)
    }

    func dailySongs() async throws -> [Track] {
        let data = try await get("/user/daily-songs", query: [])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let songs = root["songs"] as? [[String: Any]]
        else { return [] }
        return songs.compactMap(Self.track(from:))
    }

    func toplists() async throws -> [Toplist] {
        let data = try await get("/recommend/toplists", query: [])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = root["groups"] as? [[String: Any]]
        else { return [] }
        var result: [Toplist] = []
        for group in groups {
            let groupName = (group["name"] as? String) ?? ""
            for entry in (group["toplists"] as? [[String: Any]]) ?? [] {
                guard let id = entry["id"] as? Int else { continue }
                result.append(Toplist(
                    id: String(id),
                    title: (entry["title"] as? String) ?? "未命名榜",
                    intro: (entry["intro"] as? String) ?? "",
                    trackCount: (entry["total"] as? Int) ?? 0,
                    updateTime: entry["updateTime"] as? String,
                    artworkURL: (entry["cover"] as? String).flatMap(Self.secureImageURL),
                    group: groupName
                ))
            }
        }
        return result
    }

    func toplistTracks(_ toplist: Toplist, offset: Int = 0) async throws -> (tracks: [Track], total: Int) {
        // The chart endpoint pages by track offset and returns 20 at a time regardless of `limit`.
        let data = try await get("/recommend/toplist", query: [
            .init(name: "id", value: toplist.id),
            .init(name: "offset", value: String(offset)),
        ])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], 0) }
        let songs = (root["songs"] as? [[String: Any]]) ?? []
        let total = ((root["toplist"] as? [String: Any])?["total"] as? Int) ?? toplist.trackCount
        return (songs.compactMap(Self.track(from:)), total)
    }

    // MARK: - Writes

    func setLiked(_ liked: Bool, track: Track) async throws {
        // The API wants both the numeric id and the mid; `id` comes back as 0 in some listings, so
        // resolve it from the song detail endpoint first.
        let numericID = try await songNumericID(for: track)
        let body: [String: Any] = [
            "song": ["id": numericID, "mid": track.id, "type": 0],
            "liked": liked,
        ]
        try await postJSON("/user/song/like", body: body)
    }

    func setSubscribed(_ subscribed: Bool, album: Album) async throws {
        try await postJSON("/user/album/subscribe", body: ["id": album.id, "subscribed": subscribed])
    }

    func setSubscribed(_ subscribed: Bool, playlist: SearchPlaylist) async throws {
        guard let tid = Int(playlist.id) else {
            throw PlatformError("歌单 id 不是数字，无法收藏")
        }
        try await postJSON("/user/playlist/subscribe", body: ["tid": tid, "subscribed": subscribed])
    }

    private func songNumericID(for track: Track) async throws -> Int {
        let body: [String: Any] = ["songs": [["mid": track.id]]]
        let data = try await postJSON("/song/batch", body: body)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]],
              let first = results.first,
              let song = first["song"] as? [String: Any],
              let id = song["id"] as? Int, id > 0
        else {
            throw PlatformError("无法解析歌曲 id，暂时不能改红心")
        }
        return id
    }

    @discardableResult
    private func postJSON(_ path: String, body: [String: Any]) async throws -> Data {
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            throw PlatformError("请求体无效")
        }
        let data = try await post(path, body: payload)
        // A write that reports an error in a 200 body must not be treated as success.
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = root["code"] as? Int, code >= 400 {
            let message = (root["message"] as? String) ?? "操作失败（code \(code)）"
            throw PlatformError(message)
        }
        return data
    }

    func streamSource(for track: Track, quality: AudioQuality) async throws -> StreamSource {
        let fullData = try await get("/getMusicPlay/\(track.id)",
                                     query: [.init(name: "quality", value: quality.apiValue)])
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

    /// QQ Music hands out `http://` URLs for both audio and artwork. Images are loaded through
    /// URLSession, so ATS blocks the plain-http ones exactly like it blocks audio — upgrade them.
    private static func secureImageURL(_ raw: String) -> URL? {
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("http://") {
            return URL(string: "https://" + raw.dropFirst("http://".count))
        }
        return URL(string: raw)
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

    /// One track's metadata by id.
    ///
    /// `/song/batch` is the endpoint that takes mids and answers full track records, and the adapter
    /// already relies on it for the numeric id a heart needs. Reading the same response means an id
    /// from a previous session still resolves to a real track, with the metadata a write requires.
    func track(withID id: String) async throws -> Track {
        let body: [String: Any] = ["songs": [["mid": id]]]
        let data = try await postJSON("/song/batch", body: body)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]],
              let first = results.first,
              let song = first["song"] as? [String: Any],
              let track = Self.track(from: song)
        else {
            throw PlatformError("找不到曲目 \(id)")
        }
        return track
    }

    /// Company, release date, genre, language and blurb for the detail page.
    ///
    /// `/getSongInfo` answers a rich `info` dictionary keyed by field name; every value is a list of
    /// `{ value }` entries. Only the fields the page shows are read, and a missing one stays nil so
    /// the page drops that row instead of inventing it.
    func trackDetail(for track: Track) async throws -> TrackDetail {
        let data = try await get("/getSongInfo", query: [.init(name: "songmid", value: track.id)])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let songinfo = response["songinfo"] as? [String: Any],
              let payload = songinfo["data"] as? [String: Any],
              let info = payload["info"] as? [String: Any]
        else { return TrackDetail() }

        func value(_ key: String) -> String? {
            guard let field = info[key] as? [String: Any],
                  let contents = field["content"] as? [[String: Any]]
            else { return nil }
            let text = contents
                .compactMap { ($0["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " / ")
            return text.isEmpty ? nil : text
        }

        return TrackDetail(
            company: value("company"),
            releaseDate: value("pub_time"),
            genre: value("genre"),
            language: value("lan"),
            intro: value("intro")
        )
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

    /// Which qualities exist for a track.
    ///
    /// `/getMusicPlay` answers "no link" for a quality the account cannot use, but it does not say
    /// which ones it *could* serve. `/song/batch` reports the actual file size for every quality,
    /// and a non-zero size means that file exists — that is what lets the UI list real options
    /// instead of six guesses.
    func availableQualities(for track: Track) async throws -> [AvailableQuality] {
        let body: [String: Any] = ["songs": [["mid": track.id]]]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return [] }
        let data = try await post("/song/batch", body: payload)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]],
              let first = results.first,
              let song = first["song"] as? [String: Any],
              let file = song["file"] as? [String: Any]
        else { return [] }

        // Size field -> quality. Only qualities this app can request are listed.
        let mapping: [(String, AudioQuality)] = [
            ("size_flac", .flac),
            ("size_ape", .ape),
            ("size_320mp3", .mp3_320),
            ("size_128mp3", .mp3_128),
            ("size_192aac", .aac),
            ("size_96aac", .aac),
        ]
        var seen = Set<AudioQuality>()
        var available: [AvailableQuality] = []
        for (field, quality) in mapping {
            guard let size = file[field] as? Int, size > 0, !seen.contains(quality) else { continue }
            seen.insert(quality)
            available.append(AvailableQuality(quality: quality, byteSize: size))
        }
        return available.sorted { $0.quality.rank > $1.quality.rank }
    }

    // MARK: - Library

    func likedSongs() async throws -> [Track] {
        var collected: [Track] = []
        var offset = 0
        // Paged: the endpoint returns a window, not the whole library.
        while collected.count < 2000 {
            let data = try await get("/user/liked-songs", query: [
                .init(name: "offset", value: String(offset)),
                .init(name: "limit", value: "100"),
            ])
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let songs = root["songs"] as? [[String: Any]],
                  !songs.isEmpty
            else { break }
            let page = songs.compactMap(Self.track(from:))
            collected.append(contentsOf: page)
            if songs.count < 100 { break }
            offset += songs.count
        }
        return collected
    }

    func playlists() async throws -> [Playlist] {
        let data = try await get("/user/playlist", query: [])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["playlist"] as? [[String: Any]]
        else { return [] }
        return raw.compactMap { entry in
            guard let tid = entry["tid"] as? Int else { return nil }
            let dirId = entry["dirId"] as? Int
            // The same endpoint returns two shapes: the user's own playlists use `dirName` /
            // `songNum` / `picUrl`, while playlists collected from other users use `name` /
            // `songnum` / `logo`. Reading only the first shape made every collected playlist show
            // up as an unnamed one.
            let ownName = (entry["dirName"] as? String)?.trimmingCharacters(in: .whitespaces)
            let collectedName = (entry["name"] as? String)?.trimmingCharacters(in: .whitespaces)
            let isCollected = (ownName ?? "").isEmpty && !(collectedName ?? "").isEmpty
            let rawName = isCollected ? (collectedName ?? "") : (ownName ?? "")
            let count = (entry["songNum"] as? Int)
                ?? (entry["songnum"] as? Int)
                ?? 0
            // Cover: whatever the API gives. Nothing is invented when it gives none — a playlist
            // whose tracks are delisted has no artwork and no artwork source either.
            let cover = (entry["picUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (entry["logo"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (entry["bigpicUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // dirId 201 is QQ Music's fixed "我喜欢的音乐" folder.
            let isLiked = dirId == 201 || rawName == "我喜欢"
            let resolvedName = rawName.isEmpty ? (isLiked ? "我喜欢" : "未命名歌单") : rawName
            return Playlist(
                id: String(tid),
                name: resolvedName,
                trackCount: count,
                isLikedSongs: isLiked,
                isCollected: isCollected,
                artworkURL: cover.flatMap(Self.secureImageURL),
                creator: Self.text(entry["nickname"]) ?? Self.text(entry["nick"]),
                summary: Self.text(entry["desc"]),
                playCount: entry["visitnum"] as? Int,
                createdAt: (entry["ctime"] as? Int).flatMap { raw -> Date? in
                    raw > 0 ? Date(timeIntervalSince1970: TimeInterval(raw)) : nil
                }
            )
        }
        // 我喜欢 first, then the user's own order.
        .sorted { lhs, rhs in
            if lhs.isLikedSongs != rhs.isLikedSongs { return lhs.isLikedSongs }
            return false
        }
    }

    func tracks(in playlist: Playlist) async throws -> [Track] {
        if playlist.isLikedSongs {
            return try await likedSongs()
        }
        let data = try await get("/user/playlist-detail", query: [
            .init(name: "tid", value: playlist.id),
        ])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let songs = root["songs"] as? [[String: Any]]
        else { return [] }
        return songs.compactMap(Self.track(from:))
    }

    /// Album tracks plus the structured classical credits QQ Music ships with an album.
    ///
    /// The endpoint is `/getAlbumInfo?albummid=…` — the route's `:albummid?` segment is optional, so
    /// passing it as a path component returns `no albummid` instead of the album.
    ///
    /// The album's own name, artist and year come back with the tracks: a row's album label only
    /// carries an id and a name, and an album opened from there must not stay a half-empty stub that
    /// then gets written into the user's collection.
    func albumTracks(_ album: Album) async throws -> AlbumContents {
        let data = try await get("/getAlbumInfo", query: [.init(name: "albummid", value: album.id)])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let payload = response["data"] as? [String: Any]
        else {
            throw PlatformError("专辑信息响应异常")
        }
        let raw = (payload["list"] as? [[String: Any]]) ?? []
        guard !raw.isEmpty else {
            return AlbumContents(tracks: [], details: nil, name: nil, artist: nil, year: nil)
        }

        // `classic_list` groups runs of tracks by composer/work and names the disc they start on.
        let classics = (payload["classic_list"] as? [[String: Any]]) ?? []
        var credits: [(startIndex: Int, composer: String?, work: String?, disc: String?)] = []
        for entry in classics {
            let index = (entry["index"] as? [Int])?.first ?? 0
            var composer: String?
            var work: String?
            for desc in (entry["desc"] as? [[String: Any]]) ?? [] {
                switch desc["type"] as? String {
                case "author": composer = desc["name"] as? String
                case "collection": work = desc["name"] as? String
                default: break
                }
            }
            credits.append((index, composer, work, entry["CD"] as? String))
        }
        credits.sort { $0.startIndex < $1.startIndex }

        let tracks = raw.enumerated().compactMap { offset, item -> Track? in
            guard var track = Self.track(from: item) else { return nil }
            // The most recent credit block at or before this track applies to it.
            let credit = credits.last { $0.startIndex <= offset }
            track.composer = credit?.composer
            track.work = credit?.work
            track.disc = credit?.disc
            return track
        }
        let details = AlbumClassicalDetails(
            composer: credits.compactMap(\.composer).first,
            work: credits.compactMap(\.work).first,
            discCount: Set(credits.compactMap(\.disc)).count
        )
        let releaseDate = (payload["aDate"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return AlbumContents(
            tracks: tracks,
            details: details,
            name: (payload["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            artist: Self.albumArtist(from: payload),
            year: releaseDate.flatMap { Int($0.prefix(4)) }.flatMap { $0 > 1000 ? $0 : nil },
            releaseDate: releaseDate,
            company: Self.text(payload["company"]),
            genre: Self.text(payload["genre"]),
            language: Self.text(payload["lan"]),
            summary: Self.text(payload["desc"]),
            artistID: Self.text(payload["singermid"])
        )
    }

    /// A trimmed non-empty string, or nil. Every optional field the pages show goes through this, so a
    /// blank string from the API becomes an absent row rather than an empty one.
    private static func text(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The album's performing artist, which the album endpoint spells as either a list of singers or
    /// a single `singername` string.
    private static func albumArtist(from payload: [String: Any]) -> String? {
        let singers = (payload["singername"] as? String)
            ?? ((payload["singer"] as? [[String: Any]])?
                .compactMap { $0["name"] as? String }
                .joined(separator: " / "))
        guard let singers, !singers.isEmpty else { return nil }
        return singers
    }

    func albums() async throws -> [Album] {
        var collected: [Album] = []
        var offset = 0
        while collected.count < 500 {
            let data = try await get("/user/albums", query: [
                .init(name: "offset", value: String(offset)),
                .init(name: "limit", value: "50"),
            ])
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = root["albums"] as? [[String: Any]],
                  !raw.isEmpty
            else { break }
            collected.append(contentsOf: raw.compactMap(Self.album(from:)))
            if raw.count < 50 { break }
            offset += raw.count
        }
        return collected
    }

    private static func album(from entry: [String: Any]) -> Album? {
        guard let albumMid = entry["albummid"] as? String, !albumMid.isEmpty else { return nil }
        let name = (entry["albumname"] as? String) ?? "未知专辑"
        let singers = (entry["singer"] as? [[String: Any]]) ?? []
        let artist = singers.compactMap { $0["name"] as? String }.joined(separator: " / ")
        let count = (entry["songnum"] as? Int) ?? (entry["song_num"] as? Int) ?? 0
        return Album(
            id: albumMid,
            name: name,
            artist: artist.isEmpty ? ((entry["singername"] as? String) ?? "未知艺术家") : artist,
            trackCount: count,
            artworkURL: URL(string: "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(albumMid).jpg")
        )
    }

    // MARK: - Response mapping

    private static func track(from item: [String: Any]) -> Track? {
        guard let mid = (item["mid"] as? String) ?? (item["songmid"] as? String) else { return nil }
        let title = (item["title"] as? String) ?? (item["name"] as? String) ?? (item["songname"] as? String) ?? "未知曲目"
        let singers = (item["singer"] as? [[String: Any]]) ?? []
        let artist = singers.compactMap { ($0["name"] as? String) ?? ($0["title"] as? String) }
            .joined(separator: " / ")
        // Two shapes carry the same information. Search results nest it in `album`, while the album
        // endpoint flattens it into `albummid` / `albumname` on the track itself — reading only the
        // nested form left every track on an album page with no album id, which broke both the album
        // column and the "queue this song's album" path.
        let albumDict = item["album"] as? [String: Any]
        let album = (albumDict?["name"] as? String)
            ?? (item["albumname"] as? String)
            ?? ""
        let albumMid = (albumDict?["mid"] as? String) ?? (item["albummid"] as? String)
        let interval = (item["interval"] as? Double) ?? Double(item["interval"] as? Int ?? 0)

        var artwork: URL?
        if let albumMid, !albumMid.isEmpty {
            artwork = URL(string: "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(albumMid).jpg")
        }

        // `pay.pay_play == 1` means the track is playable by the current account; without a
        // session that still resolves to false, which is what we want to show.
        let pay = item["pay"] as? [String: Any]
        let isPlayable = (pay?["pay_play"] as? Int ?? 0) == 0

        // `time_public` is "1990-01-01"; only the year is meaningful for filtering.
        var year: Int?
        if let raw = (item["time_public"] as? String) ?? (albumDict?["time_public"] as? String),
           let value = Int(raw.prefix(4)), value > 1000 {
            year = value
        }
        // Classical results put the composer in `desc` as "作曲: <name>".
        var composerCredit: String?
        if let desc = item["desc"] as? String {
            for prefix in ["作曲:", "作曲："] where desc.hasPrefix(prefix) {
                let name = desc.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { composerCredit = name }
            }
        }

        let artistID = singers.compactMap { $0["mid"] as? String }.first { !$0.isEmpty }
        let albumID = albumMid.flatMap { $0.isEmpty ? nil : $0 }

        return Track(
            id: mid,
            title: title,
            artist: artist.isEmpty ? "未知歌手" : artist,
            album: album,
            duration: interval,
            artworkURL: artwork,
            isPlayable: isPlayable,
            composer: nil,
            work: nil,
            disc: nil,
            artistID: artistID,
            albumID: albumID,
            year: year,
            composerCredit: composerCredit
        )
    }

    private static func searchAlbum(from item: [String: Any]) -> Album? {
        guard let mid = item["albummid"] as? String, !mid.isEmpty else { return nil }
        let name = (item["name"] as? String) ?? "未知专辑"
        // `singer` here is a plain string, unlike the album list endpoint's array.
        let artist = (item["singer"] as? String)
            ?? ((item["singer"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: " / "))
            ?? "未知艺术家"
        let count = (item["song_num"] as? Int) ?? 0
        var year: Int?
        if let raw = item["publish_date"] as? String, let value = Int(raw.prefix(4)), value > 1000 {
            year = value
        }
        return Album(
            id: mid,
            name: name,
            artist: artist,
            trackCount: count,
            artworkURL: URL(string: "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(mid).jpg"),
            year: year
        )
    }

    private static func searchPlaylist(from item: [String: Any]) -> SearchPlaylist? {
        let id = (item["dissid"] as? String) ?? (item["dissid"] as? Int).map(String.init)
        guard let id, !id.isEmpty else { return nil }
        let name = (item["dissname"] as? String) ?? "未命名歌单"
        let creator = (item["nickname"] as? String) ?? ""
        let count = (item["songnum"] as? Int) ?? 0
        let listens = (item["listennum"] as? Int) ?? 0
        var artwork: URL?
        if let logo = item["logo"] as? String {
            artwork = Self.secureImageURL(logo)
        }
        return SearchPlaylist(
            id: id, name: name, creator: creator,
            trackCount: count, artworkURL: artwork, listenCount: listens
        )
    }

    private static func artist(from item: [String: Any]) -> Artist? {
        guard let mid = item["singerMID"] as? String, !mid.isEmpty else { return nil }
        let name = (item["singerName"] as? String) ?? "未知歌手"
        let songs = (item["songNum"] as? Int) ?? 0
        let albums = (item["albumNum"] as? Int) ?? 0
        var artwork: URL?
        if let pic = item["singerPic"] as? String {
            artwork = Self.secureImageURL(pic)
        }
        return Artist(id: mid, name: name, songCount: songs, albumCount: albums, artworkURL: artwork)
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

    /// `qqmusic_session=<token>` from the response's Set-Cookie header.
    private static func sessionToken(from response: HTTPURLResponse) -> String? {
        let cookies = response.value(forHTTPHeaderField: "Set-Cookie") ?? ""
        for entry in cookies.split(separator: ",") {
            for part in entry.split(separator: ";") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("qqmusic_session=") else { continue }
                let value = trimmed.dropFirst("qqmusic_session=".count)
                if !value.isEmpty { return String(value) }
            }
        }
        return nil
    }

    private func post(_ path: String, body: Data) async throws -> Data {
        guard let baseURL = await baseURLProvider() else {
            throw PlatformError("QQ 音乐服务未就绪")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        if let sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: "X-QQ-Session")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlatformError("服务响应异常")
        }
        if http.statusCode >= 400 {
            throw PlatformError("服务返回 \(http.statusCode)")
        }
        return data
    }

    private func get(_ path: String, query: [Query]) async throws -> Data {
        let (data, _) = try await getWithResponse(path, query: query)
        return data
    }

    private func getWithResponse(_ path: String, query: [Query]) async throws -> (Data, HTTPURLResponse) {
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
        return (data, http)
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
