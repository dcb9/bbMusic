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
    /// Bumped by every search. A run whose generation is stale discards its results instead of
    /// overwriting a newer search — pressing Enter twice used to interleave two runs and leave the
    /// result set inconsistent (mixed pages, zeroed total).
    private var searchGeneration = 0
    /// Song results, kept for code paths that only deal in tracks (player, queue, MCP).
    var results: [Track] { searchResults.songs }

    /// Whether search has drilled into an album, a found playlist, or an artist.
    var hasSearchDetail: Bool {
        selectedAlbum != nil || searchPlaylistDetail != nil || searchArtistDetail != nil
    }

    enum ArtistTab: String, CaseIterable, Identifiable {
        case songs, albums
        var id: String { rawValue }
        var label: String {
            switch self {
            case .songs: return "热门歌曲"
            case .albums: return "专辑"
            }
        }
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
    /// Artist detail content.
    @Published private(set) var artistSongs: [Track] = []
    @Published private(set) var artistAlbums: [Album] = []
    @Published var artistTab: ArtistTab = .songs
    /// Daily recommendation and charts.
    @Published private(set) var dailyTracks: [Track] = []
    @Published private(set) var toplists: [Toplist] = []
    @Published private(set) var selectedToplist: Toplist?
    /// Optimistic like state, keyed by track id. Writes are applied here first so the heart
    /// responds instantly; a failed write reverts it and reports why.
    @Published private(set) var likeStates: [String: Bool] = [:]
    @Published private(set) var writeError: String?
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
            primeLikes(from: libraryTracks)
        case .playlists:
            libraryTracks = []
        case .daily:
            await loadTracks { try await platform.dailySongs() }
        case .albums:
            libraryTracks = []
        case .charts:
            libraryTracks = []
            await loadToplists()
        case .search:
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

    private func loadToplists() async {
        isLoadingLibrary = true
        libraryError = nil
        defer { isLoadingLibrary = false }
        do {
            toplists = try await platform.toplists()
        } catch {
            libraryError = error.localizedDescription
        }
    }

    func open(_ toplist: Toplist) async {
        selectedToplist = toplist
        await loadTracks { try await platform.toplistTracks(toplist) }
    }

    /// Opens the album of the currently playing/selected track from a row's album label.
    func openAlbum(id: String, name: String) async {
        await openAlbum(Album(id: id, name: name, artist: "", trackCount: 0, artworkURL: nil, year: nil))
    }

    /// Opens an artist page from a row's artist label. The counts and bio arrive with the detail.
    func openArtist(id: String, name: String) async {
        await open(Artist(id: id, name: name, songCount: 0, albumCount: 0, artworkURL: nil))
    }

    /// Returns from a playlist/album detail to its list.
    func closeDetail() {
        selectedToplist = nil
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
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        searchError = nil
        searchProgress = nil
        isLoadingMore = false
        clearFilters()
        defer {
            if generation == searchGeneration {
                isSearching = false
                searchProgress = nil
            }
        }
        do {
            // One batch = 100 results. The upstream only ever returns 20 per request, so a batch is
            // five requests; the next batch waits for the user to ask for it.
            searchResults = SearchResults(kind: searchKind)
            try await fetchBatch(
                trimmed, kind: searchKind, fromPage: 1,
                into: SearchResults(kind: searchKind), generation: generation
            )
            // The upstream intermittently answers an empty first page; retrying once turns a
            // transient hiccup into a normal result instead of showing "没有找到".
            if searchResults.isEmpty, generation == searchGeneration {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                try await fetchBatch(
                    trimmed, kind: searchKind, fromPage: 1,
                    into: SearchResults(kind: searchKind), generation: generation
                )
            }
        } catch {
            guard generation == searchGeneration else { return }
            searchError = error.localizedDescription
        }
    }

    /// Loads the next batch of results. No-op when everything has already been fetched, or when a
    /// batch is already in flight — the scroll sentinel can fire repeatedly while one loads.
    func loadMoreResults() async {
        guard let next = searchResults.nextPage, !isLoadingMore else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let generation = searchGeneration
        isLoadingMore = true
        defer { if generation == searchGeneration { isLoadingMore = false } }
        do {
            try await fetchBatch(
                trimmed, kind: searchKind, fromPage: next,
                into: searchResults, generation: generation
            )
        } catch {
            guard generation == searchGeneration else { return }
            searchError = error.localizedDescription
        }
    }

    /// Pages the upstream until one batch (`searchBatchSize`) is collected or results run out.
    /// Pages the upstream one page at a time and **publishes each page as it arrives**.
    ///
    /// The caller does not wait for a whole batch: the first 20 results are on screen while the
    /// next page is still in flight. `isSearching` therefore means "a page is loading", not
    /// "nothing to show yet".
    private func fetchBatch(
        _ keyword: String,
        kind: SearchKind,
        fromPage: Int,
        into existing: SearchResults,
        generation: Int
    ) async throws {
        var merged = existing
        var page: Int? = fromPage
        var collected = 0
        // The upstream intermittently serves a hollow page — 0 items, total 0, more false — and
        // then resumes normally on the following page (observed at pages 3-4 and 10-12 of one
        // query). Treating that as the end of the results silently truncated every search to
        // whatever happened to load before the hiccup.
        var consecutiveEmpty = 0
        while let current = page, collected < Self.searchBatchSize {
            if generation != searchGeneration { break }
            let chunk = try await platform.search(keyword, kind: kind, page: current)
            guard generation == searchGeneration else { return }
            if chunk.isEmpty {
                consecutiveEmpty += 1
                if consecutiveEmpty > Self.maxConsecutiveEmptyPages {
                    // We ran into a wall of hollow pages. Only call it exhausted when there is
                    // genuinely nothing left; otherwise keep the position so a later scroll can
                    // retry, instead of stranding the user partway through a result set.
                    page = merged.count >= merged.totalAvailable ? nil : current
                    break
                }
                // Skip the hollow page and try the next one.
                page = current + 1
                continue
            }
            consecutiveEmpty = 0
            merged.songs += chunk.songs
            merged.albums += chunk.albums
            merged.playlists += chunk.playlists
            merged.artists += chunk.artists
            merged.totalAvailable = max(merged.totalAvailable, chunk.totalAvailable)
            collected += chunk.count
            page = chunk.nextPage

            // Publish immediately: the user sees this page while the next one loads.
            var visible = merged
            visible.nextPage = page
            searchResults = visible
            searchProgress = (merged.count, merged.totalAvailable)
        }
        if generation == searchGeneration {
            var settled = merged
            settled.nextPage = page
            searchResults = settled
        }
    }

    /// Results per batch: 100, which is five upstream pages.
    static let searchBatchSize = 100

    /// How many hollow pages in a row mean the results really are exhausted. The upstream has been
    /// seen to return two in a row before resuming, so the limit is deliberately above that.
    static let maxConsecutiveEmptyPages = 4

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

    /// An artist's detail page: profile, top songs and albums.
    func open(_ artist: Artist) async {
        section = .search
        pane = .list
        selectedPlaylist = nil
        selectedAlbum = nil
        albumDetails = nil
        searchPlaylistDetail = nil
        searchArtistDetail = artist
        artistTab = .songs
        artistSongs = []
        artistAlbums = []
        libraryTracks = []
        libraryError = nil
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        do {
            async let detail = platform.artistDetail(artist)
            async let songs = platform.songs(by: artist)
            async let albums = platform.albums(by: artist)
            searchArtistDetail = try await detail
            artistSongs = try await songs
            artistAlbums = try await albums
            libraryTracks = artistSongs
        } catch {
            libraryError = error.localizedDescription
        }
    }

    // MARK: - Writes

    /// Toggles 我喜欢 for a track. Optimistic: the heart flips immediately, and flips back with a
    /// visible message if QQ Music rejects the change.
    func toggleLike(_ track: Track) async {
        let current = likeStates[track.id] ?? false
        let desired = !current
        likeStates[track.id] = desired
        writeError = nil
        do {
            try await platform.setLiked(desired, track: track)
        } catch {
            likeStates[track.id] = current
            writeError = "红心更新失败：\(error.localizedDescription)"
        }
    }

    func isLiked(_ track: Track) -> Bool {
        likeStates[track.id] ?? false
    }

    /// Marks every track already in 我喜欢, so hearts render correctly without a per-row request.
    func primeLikes(from tracks: [Track]) {
        for track in tracks { likeStates[track.id] = true }
    }

    func clearWriteError() { writeError = nil }

    /// Collects or uncollects an album from search results.
    func toggleSubscription(_ album: Album) async {
        writeError = nil
        do {
            try await platform.setSubscribed(true, album: album)
            if !albums.contains(where: { $0.id == album.id }) {
                albums.insert(album, at: 0)
            }
        } catch {
            writeError = "收藏专辑失败：\(error.localizedDescription)"
        }
    }

    /// Collects a playlist found by search.
    func toggleSubscription(_ playlist: SearchPlaylist) async {
        writeError = nil
        do {
            try await platform.setSubscribed(true, playlist: playlist)
            await loadLibrary()
        } catch {
            writeError = "收藏歌单失败：\(error.localizedDescription)"
        }
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
        artistSongs = []
        artistAlbums = []
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
        case .daily:
            return connection.isConnected ? nil : "需要先登录 QQ 音乐才能读取每日推荐。"
        case .charts:
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
