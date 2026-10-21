import Foundation

/// A minimal MCP (Model Context Protocol) server exposed over HTTP for local LLM clients.
///
/// Scope is deliberate: read, search, and *playback control*. It can search the catalogue and start
/// or steer playback, but it cannot modify the account — no playlist edits, no hearting, no Last.fm
/// writes. A model that misreads an instruction can therefore annoy you, never change your library.
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
    ]

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
            let known = model.player.queue.first { $0.id == trackID }
                ?? model.libraryTracks.first { $0.id == trackID }
                ?? model.results.first { $0.id == trackID }
            if let known {
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
                  let track = model.player.queue.first(where: { $0.id == id }) ?? model.results.first(where: { $0.id == id })
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
                  let track = model.player.queue.first(where: { $0.id == id }) ?? model.results.first(where: { $0.id == id })
            else {
                return Self.toolResult("找不到曲目，请先搜索", isError: true)
            }
            let lyrics = (try? await model.platform.lyrics(for: track)) ?? .empty
            let text = lyrics.isEmpty
                ? "这首歌没有歌词"
                : lyrics.lines.map { $0.text }.joined(separator: "\n")
            return Self.toolResult(text)

        default:
            return Self.toolResult("未知工具 \(name)", isError: true)
        }
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
