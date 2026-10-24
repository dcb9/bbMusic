import SwiftUI
import XCTest
@testable import bbMusic

/// The queue survives a restart: it comes back, on the same row, **paused**.
@MainActor
final class QueuePersistenceTests: XCTestCase {
    private var support: URL!
    private var platform: StubPlatform!

    override func setUp() async throws {
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbMusicQueue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        platform = StubPlatform()
    }

    override func tearDown() async throws {
        platform = nil
        try? FileManager.default.removeItem(at: support)
    }

    private func makeModel() -> AppModel {
        AppModel(platform: platform, supportDirectory: support, sidecarDirectory: support)
    }

    func testQueueAndPositionSurviveARestart() async {
        let tracks = (0..<4).map { Fixture.track("t\($0)") }
        let first = makeModel()
        first.player.play(tracks: tracks, startingAt: 2)
        first.player.setCurrentTimeForTesting(42)
        first.saveQueueNow()

        let reopened = makeModel()
        reopened.start()

        XCTAssertEqual(reopened.player.queue.map(\.id), tracks.map(\.id), "队列应恢复")
        XCTAssertEqual(reopened.player.currentTrack?.id, "t2", "应定位到上次播放的那首")
        XCTAssertEqual(reopened.player.currentTime, 42, accuracy: 0.01, "应记住位置")
    }

    /// The whole point: reopening the app must not make noise.
    func testRestoredQueueDoesNotPlay() async {
        let tracks = (0..<3).map { Fixture.track("t\($0)") }
        let first = makeModel()
        first.player.play(tracks: tracks, startingAt: 1)
        first.saveQueueNow()

        let reopened = makeModel()
        reopened.start()

        XCTAssertFalse(reopened.player.isPlaying, "启动不应自动播放")
        XCTAssertFalse(reopened.player.isBuffering, "启动不应开始取流")
    }

    /// The row is selected so the list shows where playback will resume.
    func testRestoreSelectsTheRow() async {
        let tracks = (0..<3).map { Fixture.track("t\($0)") }
        let first = makeModel()
        first.player.play(tracks: tracks, startingAt: 1)
        first.saveQueueNow()

        let reopened = makeModel()
        reopened.start()

        XCTAssertEqual(reopened.selectedTrackID, "t1")
    }

    func testEmptyQueueClearsTheSnapshot() async {
        let tracks = [Fixture.track("t0")]
        let first = makeModel()
        first.player.play(tracks: tracks, startingAt: 0)
        first.saveQueueNow()
        first.player.clearQueue()
        first.saveQueueNow()

        let reopened = makeModel()
        reopened.start()
        XCTAssertTrue(reopened.player.queue.isEmpty, "空队列不应恢复出东西")
    }

    func testSnapshotRecordsRepeatModeAndVolume() async {
        let first = makeModel()
        first.player.play(tracks: [Fixture.track("t0")], startingAt: 0)
        first.player.repeatMode = .one
        first.player.volume = 0.35
        first.saveQueueNow()

        let reopened = makeModel()
        reopened.start()
        XCTAssertEqual(reopened.player.repeatMode, .one)
        XCTAssertEqual(reopened.player.volume, 0.35, accuracy: 0.001)
    }
}

/// Collection buttons work in both directions from a detail page.
@MainActor
final class CollectionToggleTests: XCTestCase {
    private var support: URL!
    private var platform: StubPlatform!
    private var model: AppModel!

    override func setUp() async throws {
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbMusicColl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        platform = StubPlatform()
        model = AppModel(platform: platform, supportDirectory: support, sidecarDirectory: support)
    }

    override func tearDown() async throws {
        model = nil
        platform = nil
        try? FileManager.default.removeItem(at: support)
    }

    func testAlbumCollectionTogglesBothWays() async {
        let album = Fixture.album("al1")
        XCTAssertFalse(model.isCollected(album))

        await model.toggleCollected(album)
        XCTAssertTrue(model.isCollected(album), "第一次应收藏")
        XCTAssertTrue(platform.albumWrites.contains { $0.id == "al1" && $0.subscribed })

        await model.toggleCollected(album)
        XCTAssertFalse(model.isCollected(album), "第二次应取消收藏")
        XCTAssertTrue(platform.albumWrites.contains { $0.id == "al1" && !$0.subscribed })
    }

    func testPlaylistCollectionTogglesBothWays() async {
        let playlist = Fixture.playlist("p1")
        platform.savedPlaylists = [playlist]
        await model.loadLibrary()

        await model.toggleCollected(playlist)
        XCTAssertTrue(platform.playlistWrites.contains { $0.id == "p1" && !$0.subscribed },
                      "已在收藏里的歌单，第一次点击应取消收藏")
    }

    func testTheLikedSongsPlaylistIsNeverCollectable() async {
        let liked = Playlist(id: "201", name: "我喜欢", trackCount: 5, isLikedSongs: true)
        platform.savedPlaylists = [liked]
        await model.loadLibrary()

        XCTAssertFalse(model.isCollected(liked), "账号自带的歌单不算「收藏」")
    }
}

/// The row action's hover state is the only cue that says which of the three icons a click will hit.
///
/// The wash itself now comes from the window's shared `hoverFeedback` (covered by
/// `HoverTipPlacementTests` and `HoverTipTests`), so what belongs here is the row action's own
/// contract: a resting colour that keeps a set heart on the accent.
@MainActor
final class RowActionHoverTests: XCTestCase {
    /// A heart that is already set is drawn in the accent even with no pointer on it; the hover only
    /// takes it back to the same accent. The neutral resting colour belongs to the unset heart.
    func testASetHeartRestsOnTheAccent() {
        let accent = Color(hex: 0x2E6B4F)
        let set = RowActionButton(
            symbol: "heart.fill", help: "取消红心", tint: .secondary.opacity(0.5),
            activeTint: accent, action: {}
        )
        let unset = RowActionButton(symbol: "heart", help: "加入我喜欢", action: {})

        XCTAssertNotNil(set.activeTint, "已红心的按钮以强调色为静止色")
        XCTAssertEqual(set.activeTint, accent)
        XCTAssertNil(unset.activeTint, "未红心时用中性色")
    }
}
