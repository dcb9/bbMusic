import Foundation

/// A minimal MCP (Model Context Protocol) server exposed over HTTP for local LLM clients.
///
/// Scope: read, search, playback control, and **collection management** — hearts and album/playlist
/// collection. That last part is a real account change, so it is deliberately narrow: the three
/// things a listener would ask for ("like this", "save this album", "save this playlist") and their
/// exact inverses. Everything a model could get wrong destructively — editing playlist contents,
/// renaming, deleting, anything touching Last.fm — stays out.
///
/// Every write states its target state rather than toggling, so a retried call cannot flip the value
/// back. Already being in the requested state is reported as success, matching the platform adapter.
///
/// Security: the endpoint binds to loopback only and requires a bearer token that is generated per
/// install and stored beside the other local state. Any local process could otherwise drive the
/// player, and an LLM client is exactly the kind of thing that will happily call whatever it can
/// reach.
@MainActor
final class MCPServer {
    struct Config {
        var port: UInt16
        var token: String
    }

    private var listener: MCPSocketServer?
    private let model: AppModel
    private(set) var isRunning = false
    private(set) var port: UInt16 = 0
    private(set) var token: String = ""

    init(model: AppModel) {
        self.model = model
    }

    // MARK: - Lifecycle

    func start(config: Config) {
        guard !isRunning else { return }
        token = config.token
        port = config.port
        let server = MCPSocketServer(port: config.port, token: config.token) { [weak self] request in
            await self?.handle(request) ?? .error(status: 500, message: "server unavailable")
        }
        do {
            try server.start()
            listener = server
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    func stop() {
        listener?.stop()
        listener = nil
        isRunning = false
    }

    // MARK: - JSON-RPC

    private func handle(_ request: MCPRequest) async -> MCPResponse {
        guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return .error(status: 400, message: "invalid JSON")
        }
        let id = body["id"]
        guard let method = body["method"] as? String else {
            return .jsonRPC(id: id, error: "missing method")
        }

        switch method {
        case "initialize":
            return .jsonRPC(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "bbmusic", "version": "0.1.0"],
            ])
        case "tools/list":
            return .jsonRPC(id: id, result: ["tools": Self.toolDefinitions])
        case "tools/call":
            let params = body["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let result = await callTool(name, arguments: arguments)
            return .jsonRPC(id: id, result: result)
        case "notifications/initialized":
            return .empty
        default:
            return .jsonRPC(id: id, error: "unknown method \(method)")
        }
    }

    // MARK: - Tools

    private static let toolDefinitions: [[String: Any]] = [
        [
            "name": "search_music",
            "description": "Search QQ Music for songs by keyword. Returns track ids usable with play_track.",
            "inputSchema": [
                "type": "object",
                "properties": ["query": ["type": "string", "description": "Song, artist, or album name"]],
                "required": ["query"],
            ],
        ],
        [
            "name": "play_track",
            "description": "Play a track by its id (from search_music or a library tool). Optionally play the whole result list as a queue.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "track_id": ["type": "string"],
                    "query": ["type": "string", "description": "Alternative: search this and play the first result"],
                ],
            ],
        ],
        [
            "name": "playback_control",
            "description": "Control playback: play, pause, next, previous, or seek to a position in seconds.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["play", "pause", "next", "previous", "seek"]],
                    "position": ["type": "number", "description": "Seconds, for seek"],
                ],
                "required": ["action"],
            ],
        ],
        [
            "name": "now_playing",
            "description": "What is playing right now, including position, duration, queue and available qualities.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "list_playlists",
            "description": "The user's QQ Music playlists.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "playlist_tracks",
            "description": "Tracks in a playlist, by playlist id from list_playlists.",
            "inputSchema": [
                "type": "object",
                "properties": ["playlist_id": ["type": "string"]],
                "required": ["playlist_id"],
            ],
        ],
        [
            "name": "list_albums",
            "description": "Albums the user has saved.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "liked_songs",
            "description": "The user's liked songs (我喜欢).",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "track_qualities",
            "description": "Which audio qualities exist for a track, with file sizes.",
            "inputSchema": [
                "type": "object",
                "properties": ["track_id": ["type": "string"]],
                "required": ["track_id"],
            ],
        ],
        [
            "name": "lyrics",
            "description": "Timed lyrics for a track.",
            "inputSchema": [
                "type": "object",
                "properties": ["track_id": ["type": "string"]],
                "required": ["track_id"],
            ],
        ],
        [
            "name": "like_track",
            "description": "Add a track to the account's 我喜欢, or remove it. This changes the user's account.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "track_id": ["type": "string", "description": "From search_music or a library tool"],
                    "liked": [
                        "type": "boolean",
                        "description": "true to like (default), false to remove the heart",
                    ],
                ],
                "required": ["track_id"],
            ],
        ],
        [
            "name": "collect_playlist",
            "description": "Save a playlist to the account's collection. This changes the user's account.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "playlist_id": ["type": "string", "description": "From list_playlists or search_music"],
                ],
                "required": ["playlist_id"],
            ],
        ],
        [
            "name": "uncollect_playlist",
            "description": "Remove a saved playlist from the collection. This changes the user's account.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "playlist_id": ["type": "string", "description": "From list_playlists"],
                ],
                "required": ["playlist_id"],
            ],
        ],
        [
            "name": "collect_album",
            "description": "Save an album to the account's collection. This changes the user's account.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "album_id": ["type": "string", "description": "From list_albums or search_music"],
                ],
                "required": ["album_id"],
            ],
        ],
        [
            "name": "uncollect_album",
            "description": "Remove a saved album from the collection. This changes the user's account.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "album_id": ["type": "string", "description": "From list_albums"],
                ],
                "required": ["album_id"],
            ],
        ],
        [
            "name": "daily_recommendation",
            "description": "The account's 30 daily recommendations. Pass play=true to queue and start them.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "play": ["type": "boolean", "description": "Start playing them (default false)"],
                ],
            ],
        ],
        [
            "name": "toplists",
            "description": "The 24 charts. Pass play=true with a toplist_id to queue and start that chart.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "play": ["type": "boolean", "description": "Play the chart named by toplist_id"],
                    "toplist_id": ["type": "string", "description": "A chart id from this same tool"],
                ],
            ],
        ],
    ]

    /// Dispatches a tool call without going through HTTP. The self-test and the unit tests both need
    /// to exercise the tool contract itself; only one of them should have to speak the wire protocol.
    func debugCallTool(_ name: String, arguments: [String: Any]) async -> [String: Any] {
        await callTool(name, arguments: arguments)
    }

    private func callTool(_ name: String, arguments: [String: Any]) async -> [String: Any] {
        switch name {
        case "search_music":
            let query = arguments["query"] as? String ?? ""
            let tracks = (try? await model.platform.search(query)) ?? []
            return Self.toolResult(Self.encodeTracks(tracks), isError: tracks.isEmpty && !query.isEmpty)

        case "play_track":
            if let query = arguments["query"] as? String, !query.isEmpty {
                let tracks = (try? await model.platform.search(query)) ?? []
                guard let first = tracks.first else {
                    return Self.toolResult("没有找到匹配的歌曲", isError: true)
                }
                model.player.play(tracks: tracks, startingAt: 0)
                return Self.toolResult("正在播放 \(first.title) — \(first.artist)")
            }
            guard let trackID = arguments["track_id"] as? String, !trackID.isEmpty else {
                return Self.toolResult("需要 track_id 或 query", isError: true)
            }
            // A bare id has no metadata; look it up so the queue and Now Playing are correct.
            if let known = await Self.findTrack(trackID, model: model) {
                model.player.playNow(known)
                return Self.toolResult("正在播放 \(known.title) — \(known.artist)")
            }
            return Self.toolResult("找不到曲目 \(trackID)，请先用 search_music 搜索", isError: true)

        case "playback_control":
            let action = arguments["action"] as? String ?? ""
            switch action {
            case "play":
                if !model.player.isPlaying { model.player.togglePlayPause() }
            case "pause":
                if model.player.isPlaying { model.player.togglePlayPause() }
            case "next": model.player.next()
            case "previous": model.player.previous()
            case "seek":
                let position = (arguments["position"] as? Double) ?? (arguments["position"] as? Int).map(Double.init) ?? 0
                model.player.seek(to: position)
            default:
                return Self.toolResult("未知操作 \(action)", isError: true)
            }
            return Self.toolResult(Self.nowPlayingText(model))

        case "now_playing":
            return Self.toolResult(Self.nowPlayingText(model))

        case "list_playlists":
            let playlists = model.playlists
            let text = playlists.isEmpty
                ? "没有歌单（可能未登录）"
                : playlists.map { "\($0.name) [\($0.id)] · \($0.trackCount) 首" }.joined(separator: "\n")
            return Self.toolResult(text)

        case "playlist_tracks":
            guard let id = arguments["playlist_id"] as? String,
                  let playlist = model.playlists.first(where: { $0.id == id })
            else {
                return Self.toolResult("找不到歌单，请先用 list_playlists", isError: true)
            }
            let tracks = (try? await model.platform.tracks(in: playlist)) ?? []
            return Self.toolResult(Self.encodeTracks(tracks))

        case "list_albums":
            let albums = model.albums
            let text = albums.isEmpty
                ? "没有收藏的专辑"
                : albums.map { "\($0.name) — \($0.artist) [\($0.id)]" }.joined(separator: "\n")
            return Self.toolResult(text)

        case "liked_songs":
            let tracks = (try? await model.platform.likedSongs()) ?? []
            return Self.toolResult(Self.encodeTracks(tracks))

        case "track_qualities":
            guard let id = arguments["track_id"] as? String,
                  let track = await Self.findTrack(id, model: model)
            else {
                return Self.toolResult("找不到曲目，请先搜索", isError: true)
            }
            let qualities = (try? await model.platform.availableQualities(for: track)) ?? []
            let text = qualities.isEmpty
                ? "没有查到可用音质"
                : qualities.map { "\($0.quality.label) · \($0.sizeText)" }.joined(separator: "\n")
            return Self.toolResult(text)

        case "lyrics":
            guard let id = arguments["track_id"] as? String,
                  let track = await Self.findTrack(id, model: model)
            else {
                return Self.toolResult("找不到曲目，请先搜索", isError: true)
            }
            let lyrics = (try? await model.platform.lyrics(for: track)) ?? .empty
            let text = lyrics.isEmpty
                ? "这首歌没有歌词"
                : lyrics.lines.map { $0.text }.joined(separator: "\n")
            return Self.toolResult(text)

        case "like_track":
            guard let id = arguments["track_id"] as? String, !id.isEmpty else {
                return Self.toolResult("需要 track_id", isError: true)
            }
            guard let track = await Self.findTrack(id, model: model) else {
                return Self.toolResult("找不到曲目 \(id)，请先用 search_music 搜索", isError: true)
            }
            let liked = (arguments["liked"] as? Bool) ?? true
            if model.isLiked(track) == liked {
                // Idempotent: already in the requested state, so nothing was sent.
                return Self.toolResult(
                    "\(track.title) 已经是\(liked ? "喜欢" : "未喜欢")状态，未做改动"
                )
            }
            await model.setLiked(liked, track: track)
            if let failure = model.writeError {
                return Self.toolResult(failure, isError: true)
            }
            return Self.toolResult(
                (liked ? "已加入我喜欢 · " : "已从我喜欢移除 · ") + "\(track.title) — \(track.artist)"
            )

        case "collect_playlist":
            guard let id = arguments["playlist_id"] as? String, !id.isEmpty else {
                return Self.toolResult("需要 playlist_id", isError: true)
            }
            // Only playlists the app already knows about: a bare id carries no name, and saving a
            // guessed one writes the wrong thing into the user's collection.
            if let playlist = model.playlists.first(where: { $0.id == id }) {
                if playlist.isLikedSongs {
                    return Self.toolResult("「\(playlist.name)」是账号自带歌单，无需收藏")
                }
                if model.playlists.contains(where: { $0.id == id }) {
                    await model.toggleSubscription(SearchPlaylist(
                        id: playlist.id, name: playlist.name, creator: "",
                        trackCount: playlist.trackCount, artworkURL: playlist.artworkURL,
                        listenCount: 0
                    ))
                }
                if let failure = model.writeError { return Self.toolResult(failure, isError: true) }
                return Self.toolResult("已在收藏里 · \(playlist.name)")
            }
            if let found = Self.findSearchPlaylist(id, model: model) {
                await model.toggleSubscription(found)
                if let failure = model.writeError { return Self.toolResult(failure, isError: true) }
                return Self.toolResult("已收藏歌单 · \(found.name)")
            }
            return Self.toolResult("找不到歌单 \(id)，请先用 list_playlists 或 search_music", isError: true)

        case "uncollect_playlist":
            guard let id = arguments["playlist_id"] as? String, !id.isEmpty else {
                return Self.toolResult("需要 playlist_id", isError: true)
            }
            guard let playlist = model.playlists.first(where: { $0.id == id }) else {
                return Self.toolResult("收藏里没有歌单 \(id)，请先用 list_playlists", isError: true)
            }
            if playlist.isLikedSongs {
                return Self.toolResult("「\(playlist.name)」是账号自带歌单，不能取消收藏", isError: true)
            }
            await model.uncollect(playlist)
            if let failure = model.writeError { return Self.toolResult(failure, isError: true) }
            return Self.toolResult("已取消收藏歌单 · \(playlist.name)")

        case "collect_album":
            guard let id = arguments["album_id"] as? String, !id.isEmpty else {
                return Self.toolResult("需要 album_id", isError: true)
            }
            guard let album = Self.findAlbum(id, model: model) else {
                return Self.toolResult("找不到专辑 \(id)，请先用 list_albums 或 search_music", isError: true)
            }
            if model.isCollected(album) {
                return Self.toolResult("已在收藏里 · \(album.name)")
            }
            await model.toggleSubscription(album)
            if let failure = model.writeError { return Self.toolResult(failure, isError: true) }
            return Self.toolResult("已收藏专辑 · \(album.name)")

        case "uncollect_album":
            guard let id = arguments["album_id"] as? String, !id.isEmpty else {
                return Self.toolResult("需要 album_id", isError: true)
            }
            guard let album = model.albums.first(where: { $0.id == id }) else {
                return Self.toolResult("收藏里没有专辑 \(id)，请先用 list_albums", isError: true)
            }
            await model.uncollect(album)
            if let failure = model.writeError { return Self.toolResult(failure, isError: true) }
            return Self.toolResult("已取消收藏专辑 · \(album.name)")

        case "daily_recommendation":
            let tracks = await model.loadDailyTracks()
            guard !tracks.isEmpty else {
                return Self.toolResult("没有取到每日推荐（可能未登录）", isError: true)
            }
            if (arguments["play"] as? Bool) == true {
                // Show the page the queue came from, so the user sees what the model just did.
                await model.selectSection(.daily)
                model.player.play(tracks: tracks, startingAt: 0)
                return Self.toolResult("正在播放每日推荐 \(tracks.count) 首，第一首：\(tracks[0].title) — \(tracks[0].artist)")
            }
            return Self.toolResult(Self.encodeTracks(tracks))

        case "toplists":
            let charts = await model.loadToplistsForMCP()
            guard !charts.isEmpty else {
                return Self.toolResult("没有取到排行榜（检查网络或登录状态）", isError: true)
            }
            guard (arguments["play"] as? Bool) == true else {
                let text = charts.map { "\($0.title) [\($0.id)] · \($0.group) · \($0.trackCount) 首" }
                    .joined(separator: "\n")
                return Self.toolResult(text)
            }
            guard let id = arguments["toplist_id"] as? String,
                  let chart = charts.first(where: { $0.id == id })
            else {
                return Self.toolResult("需要 toplist_id（先不带 play 调一次拿到榜单列表）", isError: true)
            }
            await model.selectSection(.charts)
            await model.open(chart)
            let tracks = model.libraryTracks
            guard !tracks.isEmpty else {
                return Self.toolResult("榜单 \(chart.title) 没有取到曲目", isError: true)
            }
            model.player.play(tracks: tracks, startingAt: 0)
            return Self.toolResult("正在播放 \(chart.title) 前 \(tracks.count) 首，第一首：\(tracks[0].title) — \(tracks[0].artist)")

        default:
            return Self.toolResult("未知工具 \(name)", isError: true)
        }
    }

    /// Finds a track by id: from what the app already holds, or by asking the platform.
    ///
    /// The fallback matters because ids outlive a session — a model that saved one from an earlier
    /// conversation must still be able to act on it. A bare id carries no metadata, and a heart write
    /// needs it, so it is resolved rather than guessed at.
    private static func findTrack(_ id: String, model: AppModel) async -> Track? {
        if let known = model.player.queue.first(where: { $0.id == id })
            ?? model.libraryTracks.first(where: { $0.id == id })
            ?? model.results.first(where: { $0.id == id })
            ?? model.dailyTracks.first(where: { $0.id == id }) {
            return known
        }
        return try? await model.platform.track(withID: id)
    }

    private static func findAlbum(_ id: String, model: AppModel) -> Album? {
        if let saved = model.albums.first(where: { $0.id == id }) { return saved }
        if let found = model.searchResults.albums.first(where: { $0.id == id }) { return found }
        if let open = model.currentAlbum, open.id == id { return open }
        return nil
    }

    private static func findSearchPlaylist(_ id: String, model: AppModel) -> SearchPlaylist? {
        model.searchResults.playlists.first { $0.id == id }
    }

    // MARK: - Formatting

    private static func encodeTracks(_ tracks: [Track]) -> String {
        guard !tracks.isEmpty else { return "没有结果" }
        return tracks.enumerated().map { index, track in
            let credit = track.composer.map { " · \($0)" } ?? ""
            return "\(index + 1). \(track.title) — \(track.artist)\(credit) [\(track.id)] \(track.durationText)"
        }.joined(separator: "\n")
    }

    private static func nowPlayingText(_ model: AppModel) -> String {
        guard let track = model.player.currentTrack else { return "当前没有播放" }
        var lines = [
            "正在播放: \(track.title) — \(track.artist)",
            "专辑: \(track.album.isEmpty ? "—" : track.album)",
            String(format: "进度: %.0fs / %.0fs", model.player.currentTime, model.player.duration),
            "状态: \(model.player.isPlaying ? "播放中" : "已暂停")",
        ]
        if let quality = model.player.deliveredQuality {
            lines.append("音质: \(quality.label)")
        }
        if model.player.isPreview { lines.append("注意: 这是 30 秒试听，不是完整曲目") }
        if model.player.queue.count > 1 {
            lines.append("队列: \(model.player.queue.count) 首")
        }
        return lines.joined(separator: "\n")
    }

    private static func toolResult(_ text: String, isError: Bool = false) -> [String: Any] {
        var result: [String: Any] = [
            "content": [["type": "text", "text": text]],
        ]
        if isError { result["isError"] = true }
        return result
    }
}
