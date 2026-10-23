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

    /// What fills the content area. These are exclusive: the list, the lyrics and the song's own
    /// page occupy the same place, so showing one is leaving the others.
    enum Pane: Equatable {
        case list
        case lyrics
        case trackDetail
    }

    @Published var section: Section = .search
    @Published var pane: Pane = .list
    /// The play queue is a transient overlay opened from the player bar, not a sidebar destination.
    @Published var showQueue = false
    /// The pane the queue was opened from. The queue's 返回 is only offered when there is somewhere
    /// to go back to — opened from the lyrics or the song detail page, the same button closes it.
    @Published private(set) var queueReturnPane: Pane?
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

    /// The detail pages above the section list. `routes.current` is what the content area shows and
    /// `routes.pop()` is where 返回 goes, so the two can never disagree.
    @Published private(set) var routes = RouteStack()

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
    /// The tracks of the current section (我喜欢, 每日推荐), before any detail page is opened.
    @Published private(set) var sectionTracks: [Track] = []
    @Published private(set) var sectionError: String?
    @Published private(set) var isLoadingLibrary = false
    /// The tracks on screen: the open detail page's own list, or the section's.
    var libraryTracks: [Track] { routes.current?.tracks ?? sectionTracks }
    var libraryError: String? { routes.current?.error ?? sectionError }
    /// Artist detail content. Lives on the stack entry so going back restores it without a request.
    @Published var artistTab: ArtistTab = .songs
    /// Daily recommendation and charts.
    @Published private(set) var toplists: [Toplist] = []
    /// Optimistic like state, keyed by track id. Writes are applied here first so the heart
    /// responds instantly; a failed write reverts it and reports why.
    @Published private(set) var likeStates: [String: Bool] = [:]
    @Published private(set) var writeError: String?
    /// Short-lived confirmation for a successful write ("已收藏到 QQ 音乐").
    @Published private(set) var writeSuccess: String?
    /// Row selection is separate from playback: clicking selects, double-clicking plays.
    @Published var selectedTrackID: String?
    /// Extra facts for the song detail page, fetched when the page opens.
    @Published private(set) var trackDetail: TrackDetail?
    private var trackDetailTask: Task<Void, Never>?

    let player: Player
    let scrobbler: Scrobbler
    private(set) lazy var mcp: MCPServer = MCPServer(model: self)
    /// Fixed loopback port so a client config does not change between launches.
    static let mcpPort: UInt16 = 43119
    let platform: MusicPlatform
    /// Where local state lives. Injected so tests never touch the real one.
    let supportDirectory: URL
    private let sidecar: SidecarManager
    private var connectionTask: Task<Void, Never>?

    /// QR sign-in is a QQ Music flow, not a `MusicPlatform` capability: a platform without it simply
    /// has no sign-in sheet to show.
    var qrLogin: QQMusicPlatform? { platform as? QQMusicPlatform }

    init(
        platform: MusicPlatform? = nil,
        supportDirectory: URL? = nil,
        sidecarDirectory: URL? = nil
    ) {
        let supportDirectory = supportDirectory ?? Self.defaultSupportDirectory()
        let sidecarDirectory = sidecarDirectory ?? Self.defaultSidecarDirectory()
        self.supportDirectory = supportDirectory
        let manager = SidecarManager(sidecarDirectory: sidecarDirectory, supportDirectory: supportDirectory)
        self.sidecar = manager
        self.platform = platform ?? QQMusicPlatform(
            baseURLProvider: { [weak manager] in
                guard let port = manager?.state.port else { return nil }
                return URL(string: "http://127.0.0.1:\(port)")
            },
            tokenURL: supportDirectory.appendingPathComponent("qq-session-token")
        )
        self.player = Player(platform: self.platform)
        self.scrobbler = Scrobbler(
            storeURL: supportDirectory.appendingPathComponent("scrobble-queue.json"),
            credentialsURL: LastFMCredentialsStore.fileURL(supportDirectory: supportDirectory)
        )

        // Playback drives the scrobbler; the scrobbler never drives playback.
        player.onTrackStarted = { [weak self] track in
            guard let self else { return }
            self.scrobbler.playerIsPreview = self.player.isPreview
            self.scrobbler.trackStarted(track, isPreview: self.player.isPreview)
            // The detail page follows the song, so a new track replaces its facts.
            if self.pane == .trackDetail { self.loadTrackDetail() }
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
        let url = supportDirectory.appendingPathComponent("mcp-token")
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

    /// Opens or closes the queue. Opening from the lyrics or the song detail page records where it
    /// came from, so the queue can close back to it instead of showing a 返回 that leads nowhere.
    func toggleQueue() {
        if showQueue {
            closeQueue()
        } else {
            queueReturnPane = pane == .list ? nil : pane
            showQueue = true
        }
    }

    /// Closes the queue and returns to the pane it was opened from.
    func closeQueue() {
        showQueue = false
        if let previous = queueReturnPane {
            pane = previous
            queueReturnPane = nil
        }
    }

    /// Opens or closes the song detail page for whatever is playing. One entry point for the player
    /// bar and the keyboard shortcut, so both toggle rather than only opening.
    func toggleTrackDetail() {
        guard player.currentTrack != nil else { return }
        if pane == .trackDetail, !showQueue {
            pane = .list
            return
        }
        // The queue is an overlay on top of the pages; asking for a page puts it away.
        showQueue = false
        queueReturnPane = nil
        pane = .trackDetail
        loadTrackDetail()
    }

    /// Opens or closes the lyrics page. Same toggle shape as the detail page, so the 「词」 button can
    /// be a switch instead of a one-way door.
    func toggleLyrics() {
        guard player.currentTrack != nil else { return }
        if pane == .lyrics, !showQueue {
            pane = .list
            return
        }
        showQueue = false
        queueReturnPane = nil
        pane = .lyrics
    }

    /// Fetches the detail rows for the current track. A failure is not reported: the page simply
    /// shows the rows it has, because these facts are decoration next to playback.
    func loadTrackDetail() {
        trackDetailTask?.cancel()
        trackDetail = nil
        guard let track = player.currentTrack else { return }
        trackDetailTask = Task { [weak self] in
            guard let self else { return }
            let detail = try? await self.platform.trackDetail(for: track)
            guard !Task.isCancelled, self.player.currentTrack?.id == track.id else { return }
            self.trackDetail = detail
        }
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
        LastFMCredentialsStore.fileURL(supportDirectory: supportDirectory).path
    }

    func signOutQQMusic() async {
        try? await platform.signOut()
        connection = .disconnected
        playlists = []
        albums = []
        sectionTracks = []
        clearRoutes()
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
        sectionError = nil
        defer { isLoadingLibrary = false }
        do {
            async let lists = platform.playlists()
            async let saved = platform.albums()
            playlists = try await lists
            albums = try await saved
        } catch {
            sectionError = error.localizedDescription
        }
    }

    // MARK: - Navigation
    //
    // A section list is the floor; every detail page sits on the route stack. Opening a page never
    // changes `section`, so the sidebar keeps pointing at where the user started, and 返回 pops
    // exactly one page — the same one that is on screen.

    /// The page currently on screen, if any.
    var route: Route? { routes.current?.route }

    /// Switches the sidebar destination. Any detail pages belong to the place the user just left, so
    /// the stack is dropped — including when the destination is already the current one, which makes
    /// the sidebar act as "back to the top of this section".
    ///
    /// The previous section's tracks are cleared *before* awaiting: `libraryTracks` falls through to
    /// them whenever no detail page is open, so leaving them in place showed one section's rows under
    /// another section's title for the length of a request.
    func selectSection(_ section: Section) async {
        self.section = section
        pane = .list
        showQueue = false
        queueReturnPane = nil
        clearRoutes()
        sectionTracks = []
        sectionError = nil
        guard connection.isConnected else { return }
        switch section {
        case .liked:
            await loadSectionTracks { try await platform.likedSongs() }
            primeLikes(from: sectionTracks)
        case .daily:
            await loadSectionTracks { try await platform.dailySongs() }
        case .charts:
            await loadToplists()
        case .playlists, .albums, .search:
            break
        }
    }

    /// Goes back one detail page. On the bottom page there is nothing to go back to, so this does
    /// nothing rather than navigating somewhere the user did not ask for.
    func goBack() {
        routes.pop()
    }

    /// Drops every detail page, returning the content area to the section list.
    func clearRoutes() {
        routes.removeAll()
    }

    /// Pushes a page and loads it. The result lands on the page that asked for it even if the user
    /// has since opened something else on top — a slow response must never write into a page it did
    /// not come from, and a page the user popped just discards its result.
    private func push(_ route: Route, load: @escaping (Route, Int) async -> Void) async {
        pane = .list
        showQueue = false
        let token = routes.push(route)
        await load(route, token)
    }

    /// Applies a load result to the page that started it, and nowhere else.
    private func updateRoute(_ token: Int, _ body: (inout RouteEntry) -> Void) {
        routes.update(token: token, body)
    }

    func open(_ playlist: Playlist) async {
        await push(.playlist(playlist)) { route, token in
            await self.load(route: route, token: token) {
                try await self.platform.tracks(in: playlist)
            }
        }
    }

    func open(_ album: Album) async {
        await push(.album(album)) { route, token in
            await self.loadAlbum(route: route, album: album, token: token)
        }
    }

    /// Opens the album behind a row's album label.
    ///
    /// The row only carries an id and a name. The artist is taken from the row so the page header is
    /// not blank while it loads, and the album is **replaced by the one the album endpoint describes**
    /// once the tracks arrive — collecting it from here must not put a half-empty album in the
    /// user's collection.
    func openAlbum(id: String, name: String, artist: String) async {
        let stub = Album(id: id, name: name, artist: artist, trackCount: 0, artworkURL: nil, year: nil)
        await push(.album(stub)) { route, token in
            await self.loadAlbum(route: route, album: stub, token: token)
        }
    }

    /// Opens an artist page from a row's artist label. The counts and bio arrive with the detail.
    func openArtist(id: String, name: String) async {
        await open(Artist(id: id, name: name, songCount: 0, albumCount: 0, artworkURL: nil))
    }

    private func loadToplists() async {
        isLoadingLibrary = true
        sectionError = nil
        defer { isLoadingLibrary = false }
        do {
            toplists = try await platform.toplists()
        } catch {
            sectionError = error.localizedDescription
        }
    }

    /// Opens a chart. Charts page by track offset, so the first page shows immediately and more
    /// arrives when the list is scrolled to the end.
    func open(_ toplist: Toplist) async {
        await push(.toplist(toplist)) { _, token in
            do {
                let page = try await self.platform.toplistTracks(toplist, offset: 0)
                self.updateRoute(token) { entry in
                    entry.tracks = page.tracks
                    entry.toplistTotal = page.total
                    entry.error = nil
                }
            } catch {
                self.updateRoute(token) { entry in
                    entry.tracks = []
                    entry.toplistTotal = toplist.trackCount
                    entry.error = error.localizedDescription
                }
            }
        }
    }

    /// Loads the next chart page when the list reaches its end.
    func loadMoreToplistTracks() async {
        guard case .toplist(let toplist)? = route,
              let token = routes.current?.token,
              !isLoadingMore
        else { return }
        let offset = libraryTracks.count
        guard offset < toplistTotal else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await platform.toplistTracks(toplist, offset: offset)
            let existing = Set(libraryTracks.map(\.id))
            updateRoute(token) { entry in
                entry.tracks += page.tracks.filter { !existing.contains($0.id) }
                entry.toplistTotal = page.total
            }
        } catch {
            updateRoute(token) { $0.error = error.localizedDescription }
        }
    }

    /// How many tracks the open chart claims to have.
    var toplistTotal: Int { routes.current?.toplistTotal ?? 0 }

    /// Whether a chart is open. A chart is the only page that reports load progress.
    var isChartPage: Bool {
        if case .toplist? = route { return true }
        return false
    }

    /// Whether the open chart has more tracks to fetch. A chart is the only page that pages, so this
    /// is false everywhere else — the earlier version keyed it off "a chart was opened at some
    /// point", which appended chart tracks to whatever list was on screen next.
    var canLoadMoreToplist: Bool {
        guard case .toplist? = route else { return false }
        return libraryTracks.count < toplistTotal
    }

    /// The album behind the open album page, once it is known.
    var albumDetails: AlbumClassicalDetails? { routes.current?.albumDetails }

    /// The profile of the open artist page.
    var searchArtistDetail: Artist? {
        guard case .artist? = route else { return nil }
        return routes.current?.artist
    }

    var artistSongs: [Track] { routes.current?.artistSongs ?? [] }
    var artistAlbums: [Album] { routes.current?.artistAlbums ?? [] }

    /// The playlist behind the open playlist page, whichever kind it is.
    var currentPlaylistName: String? {
        switch route {
        case .playlist(let playlist): return playlist.name
        case .searchPlaylist(let playlist): return playlist.name
        default: return nil
        }
    }

    /// The album behind the open album page.
    var currentAlbum: Album? {
        if case .album(let album)? = route { return album }
        return nil
    }

    /// Whether the open page is a playlist found by search — the one kind that offers "collect".
    var currentSearchPlaylist: SearchPlaylist? {
        if case .searchPlaylist(let playlist)? = route { return playlist }
        return nil
    }

    private func loadSectionTracks(_ fetch: () async throws -> [Track]) async {
        isLoadingLibrary = true
        sectionError = nil
        defer { isLoadingLibrary = false }
        do {
            sectionTracks = try await fetch()
        } catch {
            sectionTracks = []
            sectionError = error.localizedDescription
        }
    }

    private func load(route: Route, token: Int, _ fetch: () async throws -> [Track]) async {
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        do {
            let tracks = try await fetch()
            updateRoute(token) { entry in
                entry.tracks = tracks
                entry.error = nil
            }
        } catch {
            updateRoute(token) { entry in
                entry.tracks = []
                entry.error = error.localizedDescription
            }
        }
    }

    /// Album contents plus the credits that come with them, and the album's own description, which
    /// replaces the id-and-name stub the row supplied.
    private func loadAlbum(route: Route, album: Album, token: Int) async {
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        do {
            let result = try await platform.albumTracks(album)
            // The endpoint's own description replaces the id-and-name stub, so collecting from this
            // page writes a complete album into the user's collection.
            let resolved = Album(
                id: album.id,
                name: result.name ?? album.name,
                artist: result.artist ?? album.artist,
                trackCount: result.tracks.count,
                artworkURL: album.artworkURL,
                year: result.year ?? album.year
            )
            updateRoute(token) { entry in
                entry.route = .album(resolved)
                entry.tracks = result.tracks
                entry.albumDetails = result.details
                entry.error = nil
            }
        } catch {
            updateRoute(token) { entry in
                entry.tracks = []
                entry.error = error.localizedDescription
            }
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
        await push(.searchPlaylist(playlist)) { route, token in
            await self.load(route: route, token: token) {
                try await self.platform.tracks(inSearchPlaylist: playlist)
            }
        }
    }

    /// An artist's detail page: profile, top songs and albums.
    ///
    /// The three requests are awaited separately: a profile that fails must not also blank out the
    /// song list that came back fine.
    func open(_ artist: Artist) async {
        await push(.artist(artist)) { _, token in
            self.artistTab = .songs
            self.isLoadingLibrary = true
            defer { self.isLoadingLibrary = false }
            async let detail = self.platform.artistDetail(artist)
            async let songs = self.platform.songs(by: artist)
            async let albums = self.platform.albums(by: artist)
            let profile = try? await detail
            let songList = (try? await songs) ?? ArtistSongs(tracks: [], total: nil)
            let albumList = (try? await albums) ?? ArtistAlbums(albums: [], total: nil)
            self.updateRoute(token) { entry in
                let base = profile ?? artist
                // The profile endpoint has no counts; the listings do. Take them from there so the
                // page states how many songs and albums the artist actually has, not how many fit
                // in one page (and not the 0 a row-started route was seeded with).
                let resolved = Artist(
                    id: base.id,
                    name: base.name,
                    songCount: songList.total ?? base.songCount,
                    albumCount: albumList.total ?? base.albumCount,
                    artworkURL: base.artworkURL,
                    bio: base.bio
                )
                entry.route = .artist(resolved)
                entry.artist = resolved
                entry.artistSongs = songList.tracks
                entry.artistAlbums = albumList.albums
                entry.tracks = songList.tracks
                entry.error = songList.tracks.isEmpty && albumList.albums.isEmpty
                    ? "这个歌手的歌曲与专辑都没能取到"
                    : nil
            }
        }
    }

    /// Searches for an artist by name and shows the singer results.
    ///
    /// A combined credit line ("A / B / C") only carries a usable mid for the first artist, so the
    /// rest cannot be opened as artist pages without guessing. Searching the name instead gives the
    /// user the singer they clicked — the search response names the real artists, mid included.
    func searchArtist(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        pane = .list
        showQueue = false
        clearRoutes()
        section = .search
        // Empty the query first: `searchKind`'s observer fires a search when the query is already
        // non-empty, which would run the new kind against the previous keyword.
        query = ""
        searchKind = .singer
        query = trimmed
        await runSearch()
    }

    /// Opens the album behind the current track. The song detail page fills the content area, so it
    /// has to step aside first — otherwise the album would load underneath a page nobody can see.
    func openAlbum(of track: Track) async {
        guard let albumID = track.albumID else { return }
        pane = .list
        await openAlbum(id: albumID, name: track.album, artist: track.artist)
    }

    /// Plays a row from the search results.
    ///
    /// Search results are a flat list of unrelated songs, so queuing "the rest of the list" means
    /// queuing a random assortment. When the row knows its album, the album's own track order becomes
    /// the queue and the current song keeps its real position in it. When it does not — no album id,
    /// the album cannot be fetched, or the album does not contain this song — only this song is
    /// queued, which is the honest answer rather than a queue the user did not ask for.
    func playFromSearch(_ track: Track) async {
        playGeneration += 1
        let generation = playGeneration
        selectedTrackID = track.id
        guard let albumID = track.albumID else {
            playSingleFromSearch(track, reason: "这首歌没有专辑信息，只播这一首")
            return
        }
        let album = Album(
            id: albumID, name: track.album, artist: track.artist,
            trackCount: 0, artworkURL: track.artworkURL, year: nil
        )
        let albumTracks: [Track]
        do {
            albumTracks = try await platform.albumTracks(album).tracks
        } catch {
            guard generation == playGeneration else { return }
            playSingleFromSearch(track, reason: "专辑曲目取不到，只播这一首")
            return
        }
        // Double-clicking a second song while the first album was still loading must not be undone by
        // the slower request finishing last.
        guard generation == playGeneration else { return }
        guard let index = albumTracks.firstIndex(where: { $0.id == track.id }) else {
            playSingleFromSearch(track, reason: "专辑里没有找到这首歌，只播这一首")
            return
        }
        player.play(tracks: albumTracks, startingAt: index)
    }

    /// Bumped by every search-result play, so a slow album lookup cannot replace a newer choice.
    private var playGeneration = 0

    private func playSingleFromSearch(_ track: Track, reason: String) {
        selectedTrackID = track.id
        player.play(tracks: [track], startingAt: 0)
        player.showNotice(reason)
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
            flash(desired ? "已加入我喜欢 · \(track.title)" : "已从我喜欢移除 · \(track.title)")
        } catch {
            likeStates[track.id] = current
            writeError = "红心更新失败：\(error.localizedDescription)"
        }
    }

    /// Shows a confirmation for a couple of seconds, then clears it.
    private func flash(_ message: String) {
        writeSuccess = message
        successTask?.cancel()
        successTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.writeSuccess = nil
        }
    }

    private var successTask: Task<Void, Never>?

    func isLiked(_ track: Track) -> Bool {
        likeStates[track.id] ?? false
    }

    /// Marks every track already in 我喜欢, so hearts render correctly without a per-row request.
    func primeLikes(from tracks: [Track]) {
        for track in tracks { likeStates[track.id] = true }
    }

    func clearWriteError() { writeError = nil }

    /// Collects an album. Already-collected albums are reported rather than silently re-sent.
    func toggleSubscription(_ album: Album) async {
        writeError = nil
        if albums.contains(where: { $0.id == album.id }) {
            flash("这张专辑已经在收藏里")
            return
        }
        do {
            try await platform.setSubscribed(true, album: album)
            albums.insert(album, at: 0)
            flash("已收藏专辑 · \(album.name)")
        } catch {
            writeError = "收藏专辑失败：\(error.localizedDescription)"
        }
    }

    /// Collects a playlist found by search.
    func toggleSubscription(_ playlist: SearchPlaylist) async {
        writeError = nil
        // Match on id, not on name: two different playlists can share a title, and matching by name
        // reported "already collected" for a playlist the user had never seen.
        if playlists.contains(where: { $0.id == playlist.id }) {
            flash("这个歌单已经在收藏里")
            return
        }
        do {
            try await platform.setSubscribed(true, playlist: playlist)
            await loadLibrary()
            flash("已收藏歌单 · \(playlist.name)")
        } catch {
            writeError = "收藏歌单失败：\(error.localizedDescription)"
        }
    }

    /// Whether an album is already in the user's collection.
    func isCollected(_ album: Album) -> Bool {
        albums.contains { $0.id == album.id }
    }

    /// Drops the detail pages and the search results behind them.
    func clearSearch() {
        query = ""
        searchResults = SearchResults()
        searchError = nil
        clearRoutes()
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

    nonisolated static func defaultSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("bbMusic", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The sidecar ships inside the bundle; while developing, fall back to the repo checkout.
    nonisolated static func defaultSidecarDirectory() -> URL {
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
