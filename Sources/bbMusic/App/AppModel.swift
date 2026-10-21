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

        var id: String { rawValue }

        var title: String {
            switch self {
            case .search: return "搜索"
            case .daily: return "每日推荐"
            case .charts: return "排行榜"
            case .liked: return "我喜欢"
            case .playlists: return "歌单"
            }
        }

        var symbol: String {
            switch self {
            case .search: return "magnifyingglass"
            case .daily: return "sun.max"
            case .charts: return "list.number"
            case .liked: return "heart"
            case .playlists: return "music.note.list"
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

    let player: Player
    let platform: QQMusicPlatform
    private let sidecar: SidecarManager
    private var connectionTask: Task<Void, Never>?

    init() {
        let support = Self.supportDirectory()
        let sidecarDirectory = Self.sidecarDirectory()
        let manager = SidecarManager(sidecarDirectory: sidecarDirectory, supportDirectory: support)
        self.sidecar = manager
        self.platform = QQMusicPlatform { [weak manager] in
            guard let port = manager?.state.port else { return nil }
            return URL(string: "http://127.0.0.1:\(port)")
        }
        self.player = Player(platform: platform)

        manager.onStateChange = { [weak self] state in
            guard let self else { return }
            self.sidecarState = state
            if state.port != nil {
                Task { await self.refreshConnection() }
            }
        }
    }

    func start() {
        sidecar.start()
    }

    func shutdown() {
        connectionTask?.cancel()
        player.stop()
        sidecar.stop()
    }

    // MARK: - Connection

    func refreshConnection() async {
        guard sidecarState.port != nil else {
            connection = .disconnected
            return
        }
        let state = await platform.connectionState()
        connection = state
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
            return "每日推荐还在接入中。这一轮先跑通搜索与播放。"
        case .charts:
            return "排行榜还在接入中。这一轮先跑通搜索与播放。"
        case .liked:
            return connection.isConnected
                ? "「我喜欢」还在接入中。这一轮先跑通搜索与播放。"
                : "需要先登录 QQ 音乐才能读取「我喜欢」。"
        case .playlists:
            return connection.isConnected
                ? "歌单列表还在接入中。这一轮先跑通搜索与播放。"
                : "需要先登录 QQ 音乐才能读取歌单。"
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
