import Foundation

/// Top-level app state: the sidecar, the platform, the player, and whatever the current pane is
/// showing. Views read from here; nothing in a view fetches on its own.
@MainActor
final class AppModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case search
        case daily
        case charts
        case liked
        case playlists
        case albums

        var id: String { rawValue }

        var title: String {
            switch self {
            case .search: return "搜索"
            case .daily: return "每日推荐"
            case .charts: return "排行榜"
            case .liked: return "我喜欢"
            case .playlists: return "歌单"
            case .albums: return "专辑"
            }
        }

        var symbol: String {
            switch self {
            case .search: return "magnifyingglass"
            case .daily: return "sun.max"
            case .charts: return "list.number"
            case .liked: return "heart"
            case .playlists: return "music.note.list"
            case .albums: return "square.stack"
            }
        }
    }

    enum Pane {
        case list
        case lyrics
    }

    @Published var section: Section = .search
    @Published var pane: Pane = .list
    @Published var query = ""
    @Published private(set) var results: [Track] = []
    @Published private(set) var isSearching = false
    @Published private(set) var searchError: String?
    @Published private(set) var connection: PlatformConnectionState = .unknown
    @Published private(set) var sidecarState: SidecarManager.State = .idle
    @Published var showLoginSheet = false
    @Published var showLastFMPanel = false
    /// Library contents. Loaded once the account is connected.
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var albums: [Album] = []
    @Published private(set) var libraryTracks: [Track] = []
    @Published private(set) var selectedPlaylist: Playlist?
    @Published private(set) var selectedAlbum: Album?
    @Published private(set) var isLoadingLibrary = false
    @Published private(set) var libraryError: String?
    /// Classical credits for the album currently open, when the platform supplied them.
    @Published private(set) var albumDetails: AlbumClassicalDetails?
    /// Row selection is separate from playback: clicking selects, double-clicking plays.
    @Published var selectedTrackID: String?

    let player: Player
    let scrobbler: Scrobbler
    private(set) lazy var mcp: MCPServer = MCPServer(model: self)
    /// Fixed loopback port so a client config does not change between launches.
    static let mcpPort: UInt16 = 43119
    let platform: QQMusicPlatform
    private let sidecar: SidecarManager
    private var connectionTask: Task<Void, Never>?

    init() {
        let support = Self.supportDirectory()
        let sidecarDirectory = Self.sidecarDirectory()
        let manager = SidecarManager(sidecarDirectory: sidecarDirectory, supportDirectory: support)
        self.sidecar = manager
        self.platform = QQMusicPlatform(
            baseURLProvider: { [weak manager] in
                guard let port = manager?.state.port else { return nil }
                return URL(string: "http://127.0.0.1:\(port)")
            },
            tokenURL: support.appendingPathComponent("qq-session-token")
        )
        self.player = Player(platform: platform)
        self.scrobbler = Scrobbler(
            storeURL: support.appendingPathComponent("scrobble-queue.json"),
            credentialsURL: LastFMCredentialsStore.fileURL(supportDirectory: support)
        )

        // Playback drives the scrobbler; the scrobbler never drives playback.
        player.onTrackStarted = { [weak self] track in
            guard let self else { return }
            self.scrobbler.playerIsPreview = self.player.isPreview
            self.scrobbler.trackStarted(track, isPreview: self.player.isPreview)
        }
        player.onProgress = { [weak self] elapsed in
            self?.scrobbler.updateProgress(elapsed)
        }

        manager.onStateChange = { [weak self] state in
            guard let self else { return }
            self.sidecarState = state
            if state.port != nil {
                Task { await self.refreshConnection() }
            }
        }
    }

    /// Bearer token for the MCP endpoint, generated once per install.
    var mcpToken: String {
        let url = Self.supportDirectory().appendingPathComponent("mcp-token")
        if let existing = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           existing.count >= 32 {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try? token.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }

    func start() {
        // Credentials come from the Keychain only. The application identity is never compiled in:
        // the shared secret is enough to sign requests as this application, so it must not be
        // readable from the source tree or from `strings` on the binary.
        scrobbler.bootstrap()
        sidecar.start()
        // Started with the app: an LLM client connects whenever it likes and the tools work as long
        // as the player is running.
        mcp.start(config: MCPServer.Config(port: Self.mcpPort, token: mcpToken))
    }

    func shutdown() {
        connectionTask?.cancel()
        player.stop()
        scrobbler.trackStopped()
        mcp.stop()
        sidecar.stop()
    }

    /// Shown in settings so the credential file is discoverable.
    var lastFMCredentialsPath: String {
        LastFMCredentialsStore.fileURL(supportDirectory: Self.supportDirectory()).path
    }

    func signOutQQMusic() async {
        try? await platform.signOut()
        connection = .disconnected
        playlists = []
        albums = []
        libraryTracks = []
        selectedPlaylist = nil
        selectedAlbum = nil
    }

    // MARK: - Connection

    func refreshConnection() async {
        guard sidecarState.port != nil else {
            connection = .disconnected
            return
        }
        let state = await platform.connectionState()
        connection = state
        if state.isConnected {
            await loadLibrary()
        } else {
            playlists = []
            albums = []
        }
    }

    // MARK: - Library

    func loadLibrary() async {
        isLoadingLibrary = true
        libraryError = nil
        defer { isLoadingLibrary = false }
        do {
            async let lists = platform.playlists()
            async let saved = platform.albums()
            playlists = try await lists
            albums = try await saved
        } catch {
            libraryError = error.localizedDescription
        }
    }

    /// Loads a section's contents. Errors are reported in `libraryError` rather than thrown, so a
    /// pane can show what went wrong without the app appearing broken.
    func selectSection(_ section: Section) async {
        self.section = section
        pane = .list
        selectedPlaylist = nil
        selectedAlbum = nil
        albumDetails = nil
        libraryError = nil
        guard connection.isConnected else {
            libraryTracks = []
            return
        }
        switch section {
        case .liked:
            await loadTracks { try await platform.likedSongs() }
        case .playlists:
            libraryTracks = []
        case .albums:
            libraryTracks = []
        default:
            libraryTracks = []
        }
    }

    func open(_ playlist: Playlist) async {
        section = .playlists
        pane = .list
        selectedAlbum = nil
        albumDetails = nil
        selectedPlaylist = playlist
        await loadTracks { try await platform.tracks(in: playlist) }
    }

    func open(_ album: Album) async {
        section = .albums
        pane = .list
        selectedPlaylist = nil
        selectedAlbum = album
        albumDetails = nil
        await loadTracks {
            let result = try await platform.albumTracks(album)
            albumDetails = result.details
            return result.tracks
        }
    }

    /// Returns from a playlist/album detail to its list.
    func closeDetail() {
        selectedPlaylist = nil
        selectedAlbum = nil
        albumDetails = nil
        libraryTracks = []
        libraryError = nil
    }

    private func loadTracks(_ fetch: () async throws -> [Track]) async {
        isLoadingLibrary = true
        libraryError = nil
        defer { isLoadingLibrary = false }
        do {
            libraryTracks = try await fetch()
        } catch {
            libraryTracks = []
            libraryError = error.localizedDescription
        }
    }

    // MARK: - Search

    func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            searchError = nil
            return
        }
        isSearching = true
        searchError = nil
        defer { isSearching = false }
        do {
            results = try await platform.search(trimmed)
        } catch {
            results = []
            searchError = error.localizedDescription
        }
    }

    func clearSearch() {
        query = ""
        results = []
        searchError = nil
    }

    /// Sections other than search are not implemented yet; the pane says so instead of pretending
    /// to load.
    func unsupportedMessage(for section: Section) -> String? {
        switch section {
        case .search:
            return nil
        case .daily:
            return "每日推荐还在接入中。"
        case .charts:
            return "排行榜还在接入中。"
        case .liked:
            return connection.isConnected ? nil : "需要先登录 QQ 音乐才能读取「我喜欢」。"
        case .playlists:
            return connection.isConnected ? nil : "需要先登录 QQ 音乐才能读取歌单。"
        case .albums:
            return connection.isConnected ? nil : "需要先登录 QQ 音乐才能读取收藏的专辑。"
        }
    }

    // MARK: - Paths

    private static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("bbMusic", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The sidecar ships inside the bundle; while developing, fall back to the repo checkout.
    private static func sidecarDirectory() -> URL {
        if let resources = Bundle.main.resourceURL?
            .appendingPathComponent("sidecar", isDirectory: true),
           FileManager.default.fileExists(atPath: resources.appendingPathComponent("wrapper.js").path) {
            return resources
        }
        // `swift run` from the repository root.
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("sidecar", isDirectory: true)
        return local
    }
}
