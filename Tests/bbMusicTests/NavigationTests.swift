import XCTest
@testable import bbMusic

/// Navigation contracts: what the content area shows and where 返回 goes are the same fact, and no
/// page can inherit another page's data.
@MainActor
final class NavigationTests: XCTestCase {
    private var model: AppModel!
    private var platform: StubPlatform!
    private var support: URL!

    override func setUp() async throws {
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbMusicTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        platform = StubPlatform()
        model = AppModel(platform: platform, supportDirectory: support, sidecarDirectory: support)
        // Select a section without a sidecar: the section switch is what the stack hangs off.
        await model.selectSection(.liked)
    }

    override func tearDown() async throws {
        model = nil
        platform = nil
        try? FileManager.default.removeItem(at: support)
    }

    // MARK: - Opening a page never moves the sidebar

    func testArtistFromLibraryKeepsSection() async {
        platform.artistSongs = [Fixture.track("s1", artistID: "a1")]
        await model.openArtist(id: "a1", name: "歌手")

        XCTAssertEqual(model.section, .liked, "从「我喜欢」点歌手，侧边栏必须留在「我喜欢」")
        XCTAssertEqual(model.searchArtistDetail?.id, "a1")
    }

    /// The profile endpoint reports no counts, so the page must take them from the listings — the
    /// earlier code read `songNum`/`albumNum` off the profile and showed 0 for every artist.
    func testArtistCountsComeFromTheListings() async {
        platform.artistSongs = [Fixture.track("s1", artistID: "a1")]
        platform.artistAlbums = [Fixture.album("al1")]
        platform.artistSongTotal = 1011
        platform.artistAlbumTotal = 43

        await model.openArtist(id: "a1", name: "歌手")

        XCTAssertEqual(model.searchArtistDetail?.songCount, 1011, "歌曲数应是列表接口报的总量")
        XCTAssertEqual(model.searchArtistDetail?.albumCount, 43, "专辑数应是列表接口报的总量")
    }

    func testAlbumFromLibraryKeepsSection() async {
        platform.albumTracks["al1"] = [Fixture.track("t1", albumID: "al1")]
        await model.openAlbum(id: "al1", name: "专辑", artist: "歌手")

        XCTAssertEqual(model.section, .liked)
        XCTAssertEqual(model.currentAlbum?.id, "al1")
    }

    // MARK: - 返回 is layered and lands where the user came from

    func testBackWalksTheStackOnePageAtATime() async {
        platform.albumTracks["al1"] = [Fixture.track("t1", albumID: "al1")]
        platform.artistSongs = [Fixture.track("s1", artistID: "a1")]

        await model.openArtist(id: "a1", name: "歌手")
        await model.openAlbum(id: "al1", name: "专辑", artist: "歌手")

        XCTAssertEqual(model.currentAlbum?.id, "al1", "专辑页应在栈顶")

        model.goBack()
        XCTAssertEqual(model.searchArtistDetail?.id, "a1", "第一次返回应回到歌手页")
        XCTAssertEqual(model.section, .liked)

        model.goBack()
        XCTAssertNil(model.route, "第二次返回应回到列表")
        XCTAssertEqual(model.section, .liked)
    }

    func testBackOnTheBottomPageDoesNothing() async {
        XCTAssertFalse(model.routes.canGoBack)
        model.goBack()
        XCTAssertEqual(model.section, .liked, "没有来路时返回不能把用户带到别处")
        XCTAssertNil(model.route)
    }

    func testBackRestoresThePageBelowWithoutRefetching() async {
        platform.playlistTracks["p1"] = [Fixture.track("p1t1"), Fixture.track("p1t2")]
        platform.albumTracks["al1"] = [Fixture.track("al1t1")]

        await model.open(Fixture.playlist("p1"))
        await model.openAlbum(id: "al1", name: "专辑", artist: "歌手")
        model.goBack()

        XCTAssertEqual(model.libraryTracks.map(\.id), ["p1t1", "p1t2"], "返回应恢复歌单自己的曲目")
    }

    // MARK: - A page only ever describes itself

    func testSectionSwitchDropsDetailPagesSoNoStaleDataSurvives() async {
        platform.playlistTracks["search1"] = [Fixture.track("x")]
        await model.open(Fixture.searchPlaylist("search1", name: "别人的歌单"))
        XCTAssertEqual(model.currentSearchPlaylist?.id, "search1")

        // Switching to the user's own playlists must not leave the search playlist's collect button
        // (or its hidden album column) behind.
        await model.selectSection(.playlists)
        XCTAssertNil(model.currentSearchPlaylist)
        XCTAssertNil(model.currentPlaylistName)
        XCTAssertFalse(model.routes.canGoBack)
    }

    func testChartStateDoesNotLeakIntoOtherSections() async {
        platform.toplistPages[0] = (tracks: (0..<20).map { Fixture.track("c\($0)") }, total: 100)
        await model.selectSection(.charts)
        await model.open(Fixture.toplist("t1"))
        XCTAssertTrue(model.canLoadMoreToplist, "榜单本身应能继续翻页")

        await model.selectSection(.liked)
        XCTAssertFalse(model.canLoadMoreToplist, "换到「我喜欢」后不能再翻榜单页")
        XCTAssertEqual(model.toplistTotal, 0)
    }

    func testTitleComesFromThePageOnScreen() async {
        platform.playlistTracks["search1"] = []
        platform.albumTracks["al1"] = []
        await model.open(Fixture.searchPlaylist("search1", name: "别人的歌单"))
        await model.openAlbum(id: "al1", name: "我的专辑", artist: "歌手")

        // The album page is on top, so nothing about the playlist opened before it may show through.
        XCTAssertEqual(model.currentAlbum?.name, "我的专辑")
        XCTAssertNil(model.currentSearchPlaylist)
        XCTAssertNil(model.currentPlaylistName)
    }

    // MARK: - An album opened from a row becomes a complete album

    func testAlbumOpenedFromRowIsReplacedByTheEndpointsDescription() async {
        platform.albumTracks["al1"] = [Fixture.track("t1", albumID: "al1"), Fixture.track("t2", albumID: "al1")]
        platform.albumMetadata["al1"] = (name: "真实专辑名", artist: "真实歌手", year: 1999)

        await model.openAlbum(id: "al1", name: "行内名字", artist: "行内歌手")

        let album = model.currentAlbum
        XCTAssertEqual(album?.name, "真实专辑名")
        XCTAssertEqual(album?.artist, "真实歌手")
        XCTAssertEqual(album?.trackCount, 2, "收藏进列表的专辑必须带真实曲目数")
        XCTAssertEqual(album?.year, 1999)
    }

    // MARK: - A slow load lands on its own page

    func testLateLoadForAPoppedPageIsDiscarded() async {
        platform.playlistTracks["p1"] = [Fixture.track("p1t1")]
        await model.open(Fixture.playlist("p1"))
        model.goBack()

        // Whatever was in flight for the popped page must not write into the section list.
        XCTAssertTrue(model.libraryTracks.isEmpty)
        XCTAssertNil(model.route)
    }

    // MARK: - Song detail page

    func testTrackDetailTogglesAndClosesWithTheSameGesture() async {
        model.player.play(tracks: [Fixture.track("t1")], startingAt: 0)
        XCTAssertEqual(model.pane, .list)

        model.toggleTrackDetail()
        XCTAssertEqual(model.pane, .trackDetail, "点播放条左侧应打开详情页")

        model.toggleTrackDetail()
        XCTAssertEqual(model.pane, .list, "再点一次应收起详情页")
    }

    func testTrackDetailDoesNothingWithoutATrack() {
        model.toggleTrackDetail()
        XCTAssertEqual(model.pane, .list, "没有在播的歌时不应进入一个空详情页")
    }

    func testLyricsButtonToggles() async {
        model.player.play(tracks: [Fixture.track("t1")], startingAt: 0)
        model.toggleLyrics()
        XCTAssertEqual(model.pane, .lyrics)
        model.toggleLyrics()
        XCTAssertEqual(model.pane, .list, "「词」是开关，第二次点击回列表")
    }

    func testDetailAndLyricsAreExclusive() async {
        model.player.play(tracks: [Fixture.track("t1")], startingAt: 0)
        model.toggleLyrics()
        model.toggleTrackDetail()
        XCTAssertEqual(model.pane, .trackDetail, "进详情页应离开歌词页，而不是叠在一起")
        model.toggleLyrics()
        XCTAssertEqual(model.pane, .lyrics)
    }

    func testChartPageIsTheOnlyPageReportingProgress() async {
        platform.toplistPages[0] = (tracks: (0..<20).map { Fixture.track("c\($0)") }, total: 100)
        await model.selectSection(.charts)
        await model.open(Fixture.toplist("t1"))
        XCTAssertTrue(model.isChartPage)
        XCTAssertTrue(model.canLoadMoreToplist)

        await model.open(Fixture.playlist("p1"))
        XCTAssertFalse(model.isChartPage, "非榜单页不显示进度")
    }

    // MARK: - Song detail links

    func testTappingOneArtistOfACombinedCreditSearchesForThatName() async {
        platform.artistSearchResults = [Fixture.artist("a2", name: "杨瑞代")]
        model.player.play(tracks: [Fixture.track("t1", artistID: "a1")], startingAt: 0)

        await model.searchArtist(named: "杨瑞代")

        XCTAssertEqual(model.section, .search, "点歌手应进入搜索页")
        XCTAssertEqual(model.searchKind, .singer, "搜索类型应切到歌手")
        XCTAssertEqual(model.query, "杨瑞代", "关键词应自动填成被点的那位")
        XCTAssertEqual(platform.searches.last?.query, "杨瑞代", "应该真的按这个名字搜过")
        XCTAssertEqual(platform.searches.last?.kind, .singer)
        XCTAssertEqual(model.searchResults.artists.first?.name, "杨瑞代")
    }

    func testSearchingAnArtistLeavesAnyDetailPage() async {
        platform.playlistTracks["p1"] = [Fixture.track("x")]
        await model.open(Fixture.playlist("p1"))
        XCTAssertNotNil(model.route)

        await model.searchArtist(named: "周杰伦")
        XCTAssertNil(model.route, "点歌手应离开原来的详情页")
    }

    func testTappingTheAlbumOpensIt() async {
        platform.albumTracks["al1"] = [Fixture.track("t1", albumID: "al1")]
        let track = Fixture.track("t1", albumID: "al1")
        model.player.play(tracks: [track], startingAt: 0)
        model.toggleTrackDetail()
        XCTAssertEqual(model.pane, .trackDetail)

        await model.openAlbum(of: track)

        XCTAssertEqual(model.pane, .list, "详情页要让开，否则专辑页看不见")
        XCTAssertEqual(model.currentAlbum?.id, "al1")
    }

    func testAlbumWithoutAnIDIsNotOpened() async {
        let track = Fixture.track("t1")
        await model.openAlbum(of: track)
        XCTAssertNil(model.route, "没有专辑 id 时不跳转，也不留空页面")
    }

    // MARK: - Queue opened from a non-list pane

    func testQueueFromTheSongDetailPageHasNoBackButton() {
        model.player.play(tracks: [Fixture.track("t1")], startingAt: 0)
        model.toggleTrackDetail()
        model.toggleQueue()

        XCTAssertTrue(model.showQueue)
        XCTAssertEqual(model.queueReturnPane, .trackDetail, "队列要知道自己是从哪来的")

        model.toggleQueue()
        XCTAssertFalse(model.showQueue)
        XCTAssertEqual(model.pane, .trackDetail, "再点队列按钮应回到歌曲详情")
    }

    func testQueueFromTheListKeepsItsBackButton() {
        model.player.play(tracks: [Fixture.track("t1")], startingAt: 0)
        model.toggleQueue()

        XCTAssertTrue(model.showQueue)
        XCTAssertNil(model.queueReturnPane, "从列表打开时应有返回按钮")

        model.closeQueue()
        XCTAssertEqual(model.pane, .list)
    }

    // MARK: - Chart header

    func testChartHeaderReportsTheFullSize() async {
        platform.toplistPages[0] = (tracks: (0..<20).map { Fixture.track("c\($0)") }, total: 100)
        await model.selectSection(.charts)
        await model.open(Fixture.toplist("t1", count: 100))

        // The header states the chart's size; how much is loaded belongs to the progress line.
        XCTAssertEqual(model.toplistTotal, 100)
        XCTAssertEqual(model.libraryTracks.count, 20)
        XCTAssertTrue(model.isChartPage)
    }

    func testLeavingAChartRestoresTheTrackCountHeader() async {
        platform.toplistPages[0] = (tracks: (0..<20).map { Fixture.track("c\($0)") }, total: 100)
        await model.selectSection(.charts)
        await model.open(Fixture.toplist("t1", count: 100))
        await model.open(Fixture.playlist("p1"))
        XCTAssertFalse(model.isChartPage, "离开榜单后标题应回到曲目数")
    }

    // MARK: - The sidebar is a way home

    func testSelectingTheSameSectionReturnsToItsTopPage() async {
        platform.artistSongs = [Fixture.track("s1", artistID: "a1")]
        await model.openArtist(id: "a1", name: "歌手")
        XCTAssertNotNil(model.route)

        await model.selectSection(.liked)
        XCTAssertNil(model.route, "点侧边栏应回到这一栏的首页")
    }
}
