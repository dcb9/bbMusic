import XCTest
@testable import bbMusic

/// What a single click on a row costs, and what the double-click disambiguation window is.
///
/// The user-visible symptom is "single click does not keep up". Two independent causes are possible:
/// the double-tap gesture waiting out `NSEvent.doubleClickInterval`, and the row list being rebuilt
/// on every published change to the player (which ticks four times a second while music plays). These
/// tests pin the measurable half of that: the state change itself, and the window the gesture waits.
@MainActor
final class ClickLatencyTests: XCTestCase {
    private var model: AppModel!
    private var platform: StubPlatform!
    private var support: URL!

    override func setUp() async throws {
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbMusicClick-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        platform = StubPlatform()
        model = AppModel(platform: platform, supportDirectory: support, sidecarDirectory: support)
    }

    override func tearDown() async throws {
        model = nil
        platform = nil
        try? FileManager.default.removeItem(at: support)
    }

    /// The window that made a single click wait: any `TapGesture` sharing a view with a double-click
    /// gesture cannot report a single click before this expires. The rows no longer have a
    /// double-click gesture at all, which is why nothing waits for it any more.
    func testDoubleClickWindowIsTheReasonNotToUseTapGestures() {
        XCTAssertEqual(NSEvent.doubleClickInterval, 0.5, accuracy: 0.001)
    }

    /// Looking at a song is not playing it: the detail page must describe the clicked row without
    /// touching playback or the queue.
    func testShowDetailDescribesTheRowWithoutPlayingIt() async {
        let tracks = (0..<5).map { Fixture.track("t\($0)") }
        model.player.play(tracks: tracks, startingAt: 0)
        model.pane = .list

        model.showDetail(for: tracks[3])

        XCTAssertEqual(model.pane, .trackDetail)
        XCTAssertEqual(model.trackOnDetailPage?.id, "t3", "详情应描述被点的那首")
        XCTAssertEqual(model.player.currentTrack?.id, "t0", "打开详情不应改变正在播放的歌")
        XCTAssertEqual(model.player.queue.map(\.id), tracks.map(\.id), "打开详情不应重排队列")
        // `isPlaying` needs a real stream (there is none in a unit test), so the queue and current
        // track above are what prove playback was left alone.
    }

    func testClosingDetailReturnsToTheListAndForgetsThePick() async {
        let tracks = (0..<5).map { Fixture.track("t\($0)") }
        model.player.play(tracks: tracks, startingAt: 2)
        model.showDetail(for: tracks[4])

        model.closeTrackDetail()

        XCTAssertEqual(model.pane, .list, "返回应回到列表")
        XCTAssertEqual(model.trackOnDetailPage?.id, "t2", "再次进入应回到当前播放的那首")
    }

    /// The player-bar entry follows playback, so it keeps describing whatever is playing.
    func testPlayerBarDetailFollowsPlayback() async {
        let tracks = (0..<3).map { Fixture.track("t\($0)") }
        model.player.play(tracks: tracks, startingAt: 1)

        model.toggleTrackDetail()
        XCTAssertEqual(model.pane, .trackDetail)
        XCTAssertEqual(model.trackOnDetailPage?.id, "t1")
    }

    /// Selecting a row is pure state: no network, no disk, no view rebuild of the list contents.
    func testSelectingARowIsImmediate() async {
        let tracks = (0..<100).map { Fixture.track("t\($0)") }
        model.player.play(tracks: tracks, startingAt: 0)

        let start = DispatchTime.now().uptimeNanoseconds
        model.selectedTrackID = "t42"
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        XCTAssertEqual(model.selectedTrackID, "t42")
        XCTAssertLessThan(elapsed, 1.0, "选择本身应当是常数级的赋值")
    }

    /// While music plays the player publishes a position four times a second. The list must not depend
    /// on that value, or every tick rebuilds every visible row — which is what made clicks feel behind.
    func testPlayerTicksDoNotChangeListRelevantState() async {
        let tracks = (0..<5).map { Fixture.track("t\($0)") }
        model.player.play(tracks: tracks, startingAt: 2)

        let currentID = model.player.currentTrack?.id
        let playing = model.player.isPlaying
        let queue = model.player.queue.map(\.id)

        // Simulate a burst of position ticks, as the 4 Hz observer produces.
        for tick in 1...20 {
            model.player.setCurrentTimeForTesting(Double(tick) * 0.25)
        }

        XCTAssertEqual(model.player.currentTrack?.id, currentID, "进度变化不应改变当前曲目")
        XCTAssertEqual(model.player.isPlaying, playing)
        XCTAssertEqual(model.player.queue.map(\.id), queue, "进度变化不应重建队列")
    }
}
