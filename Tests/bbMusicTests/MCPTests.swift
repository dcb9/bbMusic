import XCTest
@testable import bbMusic

/// The MCP tools that change the account.
///
/// These run through `MCPServer`'s tool dispatch against a stub platform, so what is asserted is the
/// contract a model sees — idempotence, refusals, and the exact state written — rather than HTTP.
@MainActor
final class MCPTests: XCTestCase {
    private var model: AppModel!
    private var platform: StubPlatform!
    private var server: MCPServer!
    private var support: URL!
    private var searchAlbums: [Album] = []
    private var searchPlaylists: [SearchPlaylist] = []

    override func setUp() async throws {
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbMusicMCP-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        platform = StubPlatform()
        model = AppModel(platform: platform, supportDirectory: support, sidecarDirectory: support)
        server = MCPServer(model: model)
    }

    override func tearDown() async throws {
        server = nil
        model = nil
        platform = nil
        try? FileManager.default.removeItem(at: support)
    }

    // MARK: - Hearts

    func testLikeTrackSetsTheRequestedState() async {
        let track = Fixture.track("t1")
        model.player.play(tracks: [track], startingAt: 0)

        let result = await call("like_track", ["track_id": "t1", "liked": true])

        XCTAssertFalse(isError(result), "点赞应成功：\(text(result))")
        XCTAssertTrue(model.isLiked(track))
        XCTAssertEqual(platform.likedWrites.last?.liked, true)
    }

    func testLikeTrackCanRemoveTheHeart() async {
        let track = Fixture.track("t1")
        model.player.play(tracks: [track], startingAt: 0)
        await model.setLiked(true, track: track)

        let result = await call("like_track", ["track_id": "t1", "liked": false])

        XCTAssertFalse(isError(result))
        XCTAssertFalse(model.isLiked(track))
        XCTAssertEqual(platform.likedWrites.last?.liked, false)
    }

    /// A model retrying "like this" must not un-like it. The tool states a target state, so the
    /// second call is a no-op rather than a second write.
    func testLikingTwiceDoesNotFlipBack() async {
        let track = Fixture.track("t1")
        model.player.play(tracks: [track], startingAt: 0)

        _ = await call("like_track", ["track_id": "t1", "liked": true])
        let writesAfterFirst = platform.likedWrites.count
        let second = await call("like_track", ["track_id": "t1", "liked": true])

        XCTAssertFalse(isError(second))
        XCTAssertTrue(model.isLiked(track))
        XCTAssertEqual(platform.likedWrites.count, writesAfterFirst, "已喜欢时不应再写一次")
        XCTAssertTrue(text(second).contains("已经是喜欢状态"), "幂等时应如实说明：\(text(second))")
    }

    /// An id from an earlier session must still work: a model cannot be expected to re-search first.
    func testLikeTrackResolvesAnIdTheAppNoLongerHolds() async {
        let track = Fixture.track("remembered", title: "记住的歌")
        platform.knownTracks["remembered"] = track

        let result = await call("like_track", ["track_id": "remembered", "liked": true])

        XCTAssertFalse(isError(result), text(result))
        XCTAssertEqual(platform.likedWrites.last?.id, "remembered")
        XCTAssertTrue(model.isLiked(track))
    }

    func testLikeUnknownTrackIsRefused() async {
        let result = await call("like_track", ["track_id": "nope"])
        XCTAssertTrue(isError(result))
        XCTAssertTrue(platform.likedWrites.isEmpty)
    }

    // MARK: - Albums

    func testCollectAndUncollectAlbum() async {
        let album = Fixture.album("al1")
        await seedSearchAlbums([album])

        let collected = await call("collect_album", ["album_id": "al1"])
        XCTAssertFalse(isError(collected), text(collected))
        XCTAssertTrue(platform.albumWrites.contains { $0.id == "al1" && $0.subscribed })
        XCTAssertTrue(model.albums.contains { $0.id == "al1" })

        let removed = await call("uncollect_album", ["album_id": "al1"])
        XCTAssertFalse(isError(removed), text(removed))
        XCTAssertTrue(platform.albumWrites.contains { $0.id == "al1" && !$0.subscribed })
        XCTAssertFalse(model.albums.contains { $0.id == "al1" })
    }

    func testCollectingAnAlreadySavedAlbumWritesNothing() async {
        let album = Fixture.album("al1")
        await seedSearchAlbums([album])
        platform.savedAlbums = [album]
        await model.loadLibrary()

        let result = await call("collect_album", ["album_id": "al1"])

        XCTAssertFalse(isError(result))
        XCTAssertTrue(platform.albumWrites.isEmpty, "已在收藏里不应重复写")
    }

    // MARK: - Playlists

    func testCollectAndUncollectPlaylistFoundBySearch() async {
        let playlist = Fixture.searchPlaylist("p1", name: "别人的歌单")
        await seedSearchPlaylists([playlist])

        let collected = await call("collect_playlist", ["playlist_id": "p1"])
        XCTAssertFalse(isError(collected), text(collected))
        XCTAssertTrue(platform.playlistWrites.contains { $0.id == "p1" && $0.subscribed })

        platform.savedPlaylists = [Fixture.playlist("p1", name: "别人的歌单")]
        await model.loadLibrary()
        let removed = await call("uncollect_playlist", ["playlist_id": "p1"])
        XCTAssertFalse(isError(removed), text(removed))
        XCTAssertTrue(platform.playlistWrites.contains { $0.id == "p1" && !$0.subscribed })
    }

    func testCollectUnknownPlaylistIsRefused() async {
        let result = await call("collect_playlist", ["playlist_id": "nope"])
        XCTAssertTrue(isError(result))
        XCTAssertTrue(platform.playlistWrites.isEmpty)
    }

    func testTheLikedSongsPlaylistIsNotCollectable() async {
        platform.savedPlaylists = [
            Playlist(id: "201", name: "我喜欢", trackCount: 10, isLikedSongs: true)
        ]
        await model.loadLibrary()

        let result = await call("collect_playlist", ["playlist_id": "201"])
        XCTAssertFalse(isError(result))
        XCTAssertTrue(platform.playlistWrites.isEmpty, "账号自带歌单不需要收藏")
    }

    // MARK: - Discovery

    func testDailyRecommendationCanBeListedAndPlayed() async {
        let daily = (1...5).map { Fixture.track("d\($0)") }
        platform.sectionTracks = daily

        let listed = await call("daily_recommendation", [:])
        XCTAssertFalse(isError(listed))
        XCTAssertTrue(text(listed).contains("d1"))

        let played = await call("daily_recommendation", ["play": true])
        XCTAssertFalse(isError(played), text(played))
        XCTAssertEqual(model.player.queue.map(\.id), daily.map(\.id))
        XCTAssertEqual(model.section, .daily, "播放每日推荐时界面应切过去")
    }

    func testToplistsListsThenPlaysTheChosenOne() async {
        let chart = Fixture.toplist("101", title: "内地榜")
        platform.charts = [chart]
        platform.toplistPages[0] = (tracks: (0..<20).map { Fixture.track("c\($0)") }, total: 100)

        let listed = await call("toplists", [:])
        XCTAssertFalse(isError(listed))
        XCTAssertTrue(text(listed).contains("内地榜"))

        let played = await call("toplists", ["play": true, "toplist_id": "101"])
        XCTAssertFalse(isError(played), text(played))
        XCTAssertEqual(model.player.queue.count, 20)
        XCTAssertEqual(model.section, .charts)
        XCTAssertEqual(model.currentToplist?.id, "101")
    }

    func testPlayingAToplistWithoutAnIdIsRefused() async {
        platform.charts = [Fixture.toplist("101")]
        let result = await call("toplists", ["play": true])
        XCTAssertTrue(isError(result))
        XCTAssertTrue(model.player.queue.isEmpty)
    }

    // MARK: - Helpers

    /// Puts albums into the search results the way a real search would, so the tools can resolve them.
    /// Seeds results through a real search. The query is cleared first because `searchKind`'s
    /// observer fires its own search when the query is already set — that one would land afterwards
    /// and overwrite these results with a search of the previous kind.
    private func seedSearchAlbums(_ albums: [Album]) async {
        platform.searchAlbums = albums
        model.query = ""
        model.searchKind = .album
        model.query = "seed"
        await model.runSearch()
    }

    private func seedSearchPlaylists(_ playlists: [SearchPlaylist]) async {
        platform.searchPlaylists = playlists
        model.query = ""
        model.searchKind = .playlist
        model.query = "seed"
        await model.runSearch()
    }

    private func call(_ name: String, _ arguments: [String: Any]) async -> [String: Any] {
        await server.debugCallTool(name, arguments: arguments)
    }

    private func isError(_ result: [String: Any]) -> Bool {
        (result["isError"] as? Bool) ?? false
    }

    private func text(_ result: [String: Any]) -> String {
        let content = result["content"] as? [[String: Any]] ?? []
        return content.compactMap { $0["text"] as? String }.joined()
    }
}
