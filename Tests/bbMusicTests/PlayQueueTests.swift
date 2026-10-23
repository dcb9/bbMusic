import XCTest
@testable import bbMusic

/// What a double-click queues.
///
/// Search results are unrelated songs, so playing one from there queues its album; every other
/// entry point keeps queuing the list it is shown in.
@MainActor
final class PlayQueueTests: XCTestCase {
    private var model: AppModel!
    private var platform: StubPlatform!
    private var support: URL!

    override func setUp() async throws {
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbMusicTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        platform = StubPlatform()
        model = AppModel(platform: platform, supportDirectory: support, sidecarDirectory: support)
    }

    override func tearDown() async throws {
        model = nil
        platform = nil
        try? FileManager.default.removeItem(at: support)
    }

    func testPlayingASearchResultQueuesItsWholeAlbumInAlbumOrder() async {
        let album = (1...5).map { Fixture.track("a\($0)", albumID: "al1", album: "专辑") }
        platform.albumTracks["al1"] = album

        // The user plays the middle song of the album from a search result list.
        await model.playFromSearch(album[2])

        XCTAssertEqual(model.player.queue.map(\.id), album.map(\.id), "队列应是整张专辑")
        XCTAssertEqual(model.player.currentIndex, 2, "当前歌应停在它在专辑里的位置")
        XCTAssertEqual(model.player.currentTrack?.id, "a3")
    }

    func testPlayingTheLastSongLeavesTheEarlierSongsInFrontOfIt() async {
        let album = (1...4).map { Fixture.track("a\($0)", albumID: "al1") }
        platform.albumTracks["al1"] = album

        await model.playFromSearch(album[3])

        XCTAssertEqual(model.player.queue.count, 4)
        XCTAssertEqual(model.player.queue.map(\.id), ["a1", "a2", "a3", "a4"], "前面的歌都要在队列里")
        XCTAssertEqual(model.player.currentIndex, 3, "当前播最后一首")
    }

    func testSearchQueueIsNotTheResultList() async {
        let album = [Fixture.track("a1", albumID: "al1"), Fixture.track("a2", albumID: "al1")]
        platform.albumTracks["al1"] = album
        await model.playFromSearch(album[0])

        XCTAssertEqual(model.player.queue.map(\.id), ["a1", "a2"])
        XCTAssertFalse(model.player.queue.contains { $0.id == "zzz" }, "搜索结果里的其它歌不应进队列")
    }

    // MARK: - Fallbacks: only this song

    func testSongWithoutAnAlbumPlaysAlone() async {
        let track = Fixture.track("lonely")
        await model.playFromSearch(track)

        XCTAssertEqual(model.player.queue.map(\.id), ["lonely"])
        XCTAssertNotNil(model.player.notice, "降级要让用户知道原因")
    }

    func testAlbumThatFailsToLoadPlaysOnlyTheSong() async {
        let track = Fixture.track("a1", albumID: "broken")
        platform.failingAlbums = ["broken"]

        await model.playFromSearch(track)

        XCTAssertEqual(model.player.queue.map(\.id), ["a1"])
        XCTAssertNotNil(model.player.notice)
    }

    func testAlbumThatDoesNotContainTheSongPlaysOnlyTheSong() async {
        let track = Fixture.track("missing", albumID: "al1")
        platform.albumTracks["al1"] = [Fixture.track("a1", albumID: "al1")]

        await model.playFromSearch(track)

        XCTAssertEqual(model.player.queue.map(\.id), ["missing"])
        XCTAssertNotNil(model.player.notice)
    }

    // MARK: - Every other list keeps queueing itself

    func testPlayingFromAPlaylistQueuesThePlaylist() async {
        let tracks = (1...3).map { Fixture.track("p\($0)") }
        platform.playlistTracks["pl1"] = tracks
        await model.open(Fixture.playlist("pl1"))
        XCTAssertEqual(model.libraryTracks.count, 3)

        model.player.play(tracks: model.libraryTracks, startingAt: 1)
        XCTAssertEqual(model.player.queue.map(\.id), ["p1", "p2", "p3"])
        XCTAssertEqual(model.player.currentIndex, 1)
    }
}
