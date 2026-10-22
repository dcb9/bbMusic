import Foundation

/// Top-level app state: the sidecar, the platform, the player, and whatever the current pane is
/// showing. Views read from here; nothing in a view fetches on its own.
@MainActor
final class AppModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case search
        case liked
        case playlists
        case albums

        var id: String { rawValue }

        var title: String {
            switch self {
            case .search: return "搜索"
            case .liked: return "我喜欢"
            case .playlists: return "歌单"
            case .albums: return "专辑"
            }
        }

        var symbol: String {
            switch self {
            case .search: return "magnifyingglass"
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
    /// The play queue is a transient overlay opened from the player bar, not a sidebar destination.
    @Published var showQueue = false
    @Published var query = ""
    @Published var searchKind: SearchKind = .song {
        didSet {
            guard oldValue != searchKind, !query.isEmpty else { return }
            Task { await runSearch() }
        }
    }
    @Published private(set) var searchResults = SearchResults()
    /// Local filters applied on top of what the API returned.
    @Published var filterYear: Int?
    @Published var filterComposer: String?
    @Published var filterPerformer: String?
    @Published var filterAlbum: String?
    /// Progress while paging through every result page.
    @Published private(set) var searchProgress: (loaded: Int, total: Int)?
    @Published private(set) var isLoadingMore = false
    /// Song results, kept for code paths that only deal in tracks (player, queue, MCP).
    var results: [Track] { searchResults.songs }

    /// Whether search has drilled into an album, a found playlist, or an artist.
    var hasSearchDetail: Bool {
        selectedAlbum != nil || searchPlaylistDetail != nil || searchArtistDetail != nil
    }
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
    /// Detail views reached from search, which are not part of the user's own library.
    @Published private(set) var searchPlaylistDetail: SearchPlaylist?
    @Published private(set) var searchArtistDetail: Artist?
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
        showQueue = false
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
        // Deliberately does not change `section`: opening a playlist from search results must not
        // also move the sidebar selection, which previously made the playlist appear selected in
        // the sidebar as if the user had navigated there.
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

    /// Runs a search and pages through every result the upstream will give.
    ///
    /// Fetching all pages up front (rather than on scroll) is what makes the local filters honest:
    /// a filter over a partially loaded list silently hides matches that were never fetched.
    func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = SearchResults(kind: searchKind)
            searchError = nil
            return
        }
        isSearching = true
        searchError = nil
        searchProgress = nil
        clearFilters()
        defer {
            isSearching = false
            searchProgress = nil
        }
        do {
            // One batch = 100 results. The upstream only ever returns 20 per request, so a batch is
            // five requests; the next batch waits for the user to ask for it.
            let merged = try await fetchBatch(trimmed, kind: searchKind, fromPage: 1, into: SearchResults(kind: searchKind))
            searchResults = merged
            searchProgress = (merged.count, merged.totalAvailable)
        } catch {
            searchError = error.localizedDescription
        }
    }

    /// Loads the next batch of results. No-op when everything has already been fetched.
    func loadMoreResults() async {
        guard let next = searchResults.nextPage, !isLoadingMore else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let merged = try await fetchBatch(trimmed, kind: searchKind, fromPage: next, into: searchResults)
            searchResults = merged
            searchProgress = (merged.count, merged.totalAvailable)
        } catch {
            searchError = error.localizedDescription
        }
    }

    /// Pages the upstream until one batch (`searchBatchSize`) is collected or results run out.
    private func fetchBatch(
        _ keyword: String,
        kind: SearchKind,
        fromPage: Int,
        into existing: SearchResults
    ) async throws -> SearchResults {
        var merged = existing
        var page: Int? = fromPage
        var collected = 0
        while let current = page, collected < Self.searchBatchSize {
            let chunk = try await platform.search(keyword, kind: kind, page: current)
            merged.songs += chunk.songs
            merged.albums += chunk.albums
            merged.playlists += chunk.playlists
            merged.artists += chunk.artists
            merged.totalAvailable = chunk.totalAvailable
            collected += chunk.count
            page = chunk.nextPage
            searchProgress = (merged.count, merged.totalAvailable)
            // An empty page means the upstream has nothing more regardless of what it claims.
            if chunk.isEmpty { page = nil }
        }
        merged.nextPage = page
        return merged
    }

    /// Results per batch: 100, which is five upstream pages.
    static let searchBatchSize = 100

    /// Whether a "load more" action is available.
    var canLoadMore: Bool { searchResults.nextPage != nil }

    // MARK: - Local filtering

    func clearFilters() {
        filterYear = nil
        filterComposer = nil
        filterPerformer = nil
        filterAlbum = nil
    }

    var hasActiveFilters: Bool {
        filterYear != nil || filterComposer != nil || filterPerformer != nil || filterAlbum != nil
    }

    /// Songs after local filters. Only dimensions the data actually carries are offered.
    var filteredSongs: [Track] {
        searchResults.songs.filter { track in
            if let year = filterYear, track.year != year { return false }
            if let composer = filterComposer, track.composerCredit != composer { return false }
            if let performer = filterPerformer,
               !TrackDisplay.performers(from: track.artist).contains(where: { $0 == performer }) {
                return false
            }
            if let album = filterAlbum, track.album != album { return false }
            return true
        }
    }

    var filteredAlbums: [Album] {
        searchResults.albums.filter { album in
            if let year = filterYear, album.year != year { return false }
            if let performer = filterPerformer, album.artist != performer { return false }
            return true
        }
    }

    /// Filter choices derived from the fetched results — never a fixed list, so nothing is offered
    /// that would match zero rows.
    var availableYears: [Int] {
        let years: [Int]
        switch searchKind {
        case .song: years = searchResults.songs.compactMap(\.year)
        case .album: years = searchResults.albums.compactMap(\.year)
        default: years = []
        }
        return Array(Set(years)).sorted(by: >)
    }

    var availableComposers: [String] {
        Array(Set(searchResults.songs.compactMap(\.composerCredit))).sorted()
    }

    var availablePerformers: [String] {
        let names: [String]
        switch searchKind {
        case .song: names = searchResults.songs.flatMap { TrackDisplay.performers(from: $0.artist) }
        case .album: names = searchResults.albums.map(\.artist)
        default: names = []
        }
        return Array(Set(names)).sorted()
    }

    var availableAlbums: [String] {
        Array(Set(searchResults.songs.map(\.album).filter { !$0.isEmpty })).sorted()
    }

    /// How many rows the current filters leave visible.
    var filteredCount: Int {
        switch searchKind {
        case .song: return filteredSongs.count
        case .album: return filteredAlbums.count
        case .playlist: return searchResults.playlists.count
        case .singer: return searchResults.artists.count
        }
    }

    /// Opens a playlist that came from search (it may belong to another user).
    func open(_ playlist: SearchPlaylist) async {
        section = .search
        pane = .list
        selectedPlaylist = nil
        selectedAlbum = nil
        albumDetails = nil
        searchPlaylistDetail = playlist
        await loadTracks { try await platform.tracks(inSearchPlaylist: playlist) }
    }

    /// An artist's songs.
    func open(_ artist: Artist) async {
        section = .search
        pane = .list
        selectedPlaylist = nil
        selectedAlbum = nil
        albumDetails = nil
        searchArtistDetail = artist
        await loadTracks { try await platform.songs(by: artist) }
    }

    func openAlbum(_ album: Album) async {
        section = .search
        pane = .list
        selectedPlaylist = nil
        searchPlaylistDetail = nil
        searchArtistDetail = nil
        selectedAlbum = album
        albumDetails = nil
        await loadTracks {
            let result = try await platform.albumTracks(album)
            albumDetails = result.details
            return result.tracks
        }
    }

    func clearSearchDetail() {
        selectedAlbum = nil
        searchPlaylistDetail = nil
        searchArtistDetail = nil
        albumDetails = nil
        libraryTracks = []
        libraryError = nil
    }

    func clearSearch() {
        query = ""
        searchResults = SearchResults()
        searchError = nil
        clearSearchDetail()
    }

    /// Sections other than search are not implemented yet; the pane says so instead of pretending
    /// to load.
    func unsupportedMessage(for section: Section) -> String? {
        switch section {
        case .search:
            return nil
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
