import XCTest
@testable import bbMusic

/// What the detail page's 播放 button queues.
///
/// The detail page can be opened from several lists, and "play this" has to keep meaning what the row's
/// ▶ meant on the list it came from. Otherwise looking at a song from an album page and pressing 播放
/// would quietly replace the album with a single track.
@MainActor
final class DetailPagePlayTests: XCTestCase {
    private var model: AppModel!
    private var platform: StubPlatform!
    private var support: URL!

    override func setUp() async throws {
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbMusicDetailPlay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        platform = StubPlatform()
        model = AppModel(platform: platform, supportDirectory: support, sidecarDirectory: support)
    }

    override func tearDown() async throws {
        model = nil
        platform = nil
        try? FileManager.default.removeItem(at: support)
    }

    /// From an album page: the whole album becomes the queue, with the song at its own position —
    /// exactly what the row's ▶ does.
    func testPlayingFromAnAlbumPageQueuesTheAlbum() async {
        let album = (1...4).map { Fixture.track("a\($0)", albumID: "al1") }
        platform.albumTracks["al1"] = album
        await model.open(Fixture.album("al1"))
        XCTAssertEqual(model.libraryTracks.count, 4)

        await model.playFromDetailPage(album[2])

        XCTAssertEqual(model.player.queue.map(\.id), album.map(\.id), "整张专辑入队")
        XCTAssertEqual(model.player.currentTrack?.id, "a3", "从被点的那首开始")
        XCTAssertEqual(model.selectedTrackID, "a3")
    }

    /// From a playlist page: the playlist becomes the queue, not the song alone.
    func testPlayingFromAPlaylistPageQueuesThePlaylist() async {
        let tracks = (1...3).map { Fixture.track("p\($0)") }
        platform.playlistTracks["pl1"] = tracks
        await model.open(Fixture.playlist("pl1"))

        await model.playFromDetailPage(tracks[1])

        XCTAssertEqual(model.player.queue.map(\.id), ["p1", "p2", "p3"])
        XCTAssertEqual(model.player.currentTrack?.id, "p2")
    }

    /// From a search result: the song's album becomes the queue, because search results are unrelated
    /// songs. This is the rule the search list already follows.
    func testPlayingFromASearchResultQueuesItsAlbum() async {
        let album = (1...3).map { Fixture.track("s\($0)", albumID: "al9") }
        platform.albumTracks["al9"] = album
        platform.searchSongs = album
        model.section = .search
        model.searchKind = .song
        model.query = "x"
        await model.runSearch()
        XCTAssertEqual(model.results.count, 3, "搜索页应拿到三首结果")
        let target = album[1]

        await model.playFromDetailPage(target)

        XCTAssertEqual(model.player.queue.map(\.id), ["s1", "s2", "s3"], "搜索结果播一首 = 整张专辑")
        XCTAssertEqual(model.player.currentTrack?.id, "s2")
    }

    /// From the player bar — nothing on screen says which list the song came from — only that song is
    /// queued, rather than guessing a list.
    func testPlayingASongWithNoListOnScreenQueuesOnlyIt() async {
        let orphan = Fixture.track("orphan")
        model.section = .liked

        await model.playFromDetailPage(orphan)

        XCTAssertEqual(model.player.queue.map(\.id), ["orphan"])
    }

    /// An album page's 播放 starts at the first track, not wherever the user last clicked.
    func testPlayWholeListStartsAtTheFirstTrack() async {
        let album = (1...4).map { Fixture.track("a\($0)", albumID: "al1") }
        platform.albumTracks["al1"] = album
        await model.open(Fixture.album("al1"))
        model.selectedTrackID = "a4"

        model.playWholeList()

        XCTAssertEqual(model.player.queue.map(\.id), album.map(\.id))
        XCTAssertEqual(model.player.currentTrack?.id, "a1", "从第 1 首开始")
        XCTAssertEqual(model.selectedTrackID, "a1")
    }

    /// Nothing to play: leave the queue alone rather than clearing it.
    func testPlayWholeListOnAnEmptyPageDoesNothing() async {
        model.player.play(tracks: [Fixture.track("keep")], startingAt: 0)
        let before = model.player.queue.map(\.id)

        model.playWholeList()

        XCTAssertEqual(model.player.queue.map(\.id), before, "空列表不应清掉正在播的队列")
    }
}
