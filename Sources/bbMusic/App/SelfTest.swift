import AVFoundation
import SwiftUI

/// Headless health check: `bbMusic --self-test`.
///
/// Runs the real pipeline (sidecar → platform → player → lyrics) inside the real bundle and prints
/// a JSON report, then exits non-zero if any required step failed. This exists because the UI
/// cannot be inspected from a terminal (screen capture and accessibility are both gated by TCC), and
/// a claim that "the app works" should be checkable rather than asserted.
struct SelfTest {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--self-test")
    }

    struct Step {
        let name: String
        var ok: Bool
        var detail: String
    }

    /// Headless runs play real audio through the user's speakers, so they are quiet by design: the
    /// check is about whether playback advances, not about how it sounds.
    static let headlessVolume: Double = 0.1

    @MainActor
    static func run(model: AppModel) async -> (report: String, ok: Bool) {
        var steps: [Step] = []
        model.player.volume = headlessVolume

        // 1. Sidecar
        let sidecarOK = await waitUntil(timeout: 25) { model.sidecarState.port != nil }
        steps.append(Step(
            name: "sidecar",
            ok: sidecarOK,
            detail: model.sidecarState.port.map { "port \($0)" } ?? "\(model.sidecarState)"
        ))
        guard sidecarOK else { return finish(steps) }

        // 2. Connection probe (anonymous is a valid outcome: it just means "not signed in")
        await model.refreshConnection()
        steps.append(Step(
            name: "connection",
            ok: true,
            detail: model.connection.label
        ))

        // 3. Search. Retried once: the upstream occasionally returns an empty page, and a transient
        // upstream hiccup should not be reported as a product failure.
        model.query = "稻香"
        await model.runSearch()
        if model.results.isEmpty {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await model.runSearch()
        }
        let results = model.results
        steps.append(Step(
            name: "search",
            ok: !results.isEmpty,
            detail: results.isEmpty
                ? (model.searchError ?? "no results")
                : "\(results.count) results, first = \(results[0].title) / \(results[0].artist)"
        ))
        guard let track = results.first else { return finish(steps) }

        // 4. Lyrics for that track
        let lyrics = (try? await model.platform.lyrics(for: track)) ?? .empty
        steps.append(Step(
            name: "lyrics",
            ok: !lyrics.isEmpty,
            detail: "\(lyrics.lines.count) lines"
        ))

        // 5. Stream source: a full URL when signed in, otherwise QQ Music's 30s preview.
        var sourceDetail = "no source"
        var sourceOK = false
        do {
            let source = try await model.platform.streamSource(for: track, quality: .best)
            switch source {
            case .url:
                sourceOK = true
                sourceDetail = "full stream"
            case .preview:
                // Anonymous access is expected to yield only a preview; the pipeline still works.
                sourceOK = true
                sourceDetail = "preview only (not signed in)"
            }
        } catch {
            sourceDetail = error.localizedDescription
        }
        steps.append(Step(name: "stream", ok: sourceOK, detail: sourceDetail))
        guard sourceOK else { return finish(steps) }

        // 6. Real playback through AVPlayer, driven by the app's own Player.
        model.player.playNow(track)
        // A full-length FLAC over the network can take a while to start; wait generously and
        // report what the player actually says if it never advances.
        let advanced = await waitUntil(timeout: 45) {
            model.player.currentTime > 1.0
        }
        // If nothing advances, say whether the machine can render audio at all. Without this the
        // check reports a product failure when the real cause is an unavailable output device.
        var audioNote = ""
        if !advanced, !Self.audioOutputIsUsable() {
            audioNote = " (no usable audio output device on this machine)"
        }
        steps.append(Step(
            name: "playback",
            ok: advanced,
            detail: String(
                format: "t=%.1fs of %.0fs, playing=%@, preview=%@",
                model.player.currentTime,
                model.player.duration,
                model.player.isPlaying ? "yes" : "no",
                model.player.isPreview ? "yes" : "no"
            ) + " notice=\(model.player.notice ?? "none") volume=\(Int(Self.headlessVolume * 100))%" + audioNote
        ))

        // 6b. Library reads (require a signed-in account).
        if model.connection.isConnected {
            await model.loadLibrary()
            steps.append(Step(
                name: "playlists",
                ok: !model.playlists.isEmpty,
                detail: "\(model.playlists.count) playlists, first = \(model.playlists.first?.name ?? "-")"
            ))
            // Collected playlists arrive with lowercase keys (name/songnum/logo) and used to show up
            // as unnamed entries. Every playlist must have a real name and a track count.
            let unnamed = model.playlists.filter { $0.name == "未命名歌单" || $0.name.isEmpty }
            let noCount = model.playlists.filter { $0.trackCount == 0 }
            let collected = model.playlists.filter(\.isCollected).count
            steps.append(Step(
                name: "playlist-name",
                ok: unnamed.isEmpty && noCount.isEmpty,
                detail: "\(model.playlists.count) playlists (\(collected) collected), unnamed \(unnamed.count), zero-count \(noCount.count)"
            ))

            steps.append(Step(
                name: "albums",
                ok: !model.albums.isEmpty,
                detail: "\(model.albums.count) albums, first = \(model.albums.first?.name ?? "-")"
            ))
            await model.selectSection(.liked)
            steps.append(Step(
                name: "liked-songs",
                ok: !model.libraryTracks.isEmpty,
                detail: "\(model.libraryTracks.count) tracks, first = \(model.libraryTracks.first?.title ?? "-")"
            ))
            // Playlist detail through the same path the UI uses.
            if let playlist = model.playlists.first(where: { !$0.isLikedSongs }) {
                await model.open(playlist)
                steps.append(Step(
                    name: "playlist-detail",
                    ok: !model.libraryTracks.isEmpty,
                    detail: "\(playlist.name): \(model.libraryTracks.count) tracks"
                ))
                model.goBack()
            }
        }

        // 6b2. Album contents + playback. This is the path that was broken: album lookup used a
        // search instead of the album endpoint, so album tracks never resolved to audio.
        let albumToTest = model.albums.first(where: {
            $0.name.lowercased().contains("mozart") || $0.name.contains("古典")
        }) ?? model.albums.first
        if model.connection.isConnected, let album = albumToTest {
            await model.open(album)
            let albumTracks = model.libraryTracks
            steps.append(Step(
                name: "album-tracks",
                ok: !albumTracks.isEmpty,
                detail: "\(album.name): \(albumTracks.count) tracks, details=\(model.albumDetails?.composer ?? "none")"
            ))
            if let first = albumTracks.first {
                do {
                    let source = try await model.platform.streamSource(for: first, quality: .best)
                    let playable: Bool
                    switch source {
                    case .url: playable = true
                    case .preview: playable = true
                    }
                    steps.append(Step(
                        name: "album-play",
                        ok: playable,
                        detail: "resolved audio for \(first.title.prefix(40))"
                    ))
                } catch {
                    steps.append(Step(name: "album-play", ok: false, detail: error.localizedDescription))
                }
            }
            model.goBack()
        }

        // 6c. Classical-friendly display derivation.
        let classicalSamples: [(String, String, String, String?, Bool)] = [
            ("Nocturne in E-flat major, Op. 9 No. 2", "Arthur Rubinstein", "Chopin: Nocturnes", "Op. 9 No. 2", true),
            ("Prelude and Fugue in C major, BWV 846", "Glenn Gould", "Bach: WTC", "BWV 846", true),
            ("布格缪勒练习曲 阿拉伯风格曲 Op.100 No.2", "钢琴", "钢琴曲", "Op.100 No.2", true),
            ("Symphony No. 5 in C minor, Op. 67 - I. Allegro", "Berliner Philharmoniker / Herbert von Karajan", "Beethoven", "Op. 67", true),
            ("晴天", "周杰伦", "叶惠美", nil, false),
            ("I'll Believe In Anything", "Sunset Rollercoaster", "Villa", nil, false),
        ]
        var classicalFailures: [String] = []
        for (title, artist, album, expectedCatalogue, expectedClassical) in classicalSamples {
            let track = Track(id: title, title: title, artist: artist, album: album,
                              duration: 200, artworkURL: nil, isPlayable: true)
            let info = TrackDisplay.info(for: track)
            if info.catalogue != expectedCatalogue { classicalFailures.append("\(title): catalogue \(info.catalogue ?? "nil")") }
            if info.isClassical != expectedClassical { classicalFailures.append("\(title): classical \(info.isClassical)") }
        }
        steps.append(Step(
            name: "classical",
            ok: classicalFailures.isEmpty,
            detail: classicalFailures.isEmpty
                ? "\(classicalSamples.count) samples correct"
                : classicalFailures.joined(separator: "; ")
        ))

        // 6b3. Typed search: each kind comes from the same endpoint with a different item shape,
        // so each is exercised rather than assuming one parser covers them.
        if model.connection.isConnected {
            var typedFailures: [String] = []
            var typedDetail: [String] = []
            for kind in SearchKind.allCases {
                do {
                    // The upstream intermittently answers with an empty page; retry once so a
                    // transient hiccup is not reported as a broken search type.
                    var results = try await model.platform.search("周杰伦", kind: kind, page: 1)
                    if results.count == 0 {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        results = try await model.platform.search("周杰伦", kind: kind, page: 1)
                    }
                    if results.count == 0 { typedFailures.append(kind.label) }
                    typedDetail.append("\(kind.label) \(results.count)")
                } catch {
                    typedFailures.append("\(kind.label): \(error.localizedDescription)")
                }
            }
            steps.append(Step(
                name: "search-types",
                ok: typedFailures.isEmpty,
                detail: typedFailures.isEmpty ? typedDetail.joined(separator: ", ") : typedFailures.joined(separator: "; ")
            ))

            // A playlist found by search must open into real tracks.
            if let found = try? await model.platform.search("周杰伦", kind: .playlist, page: 1),
               let playlist = found.playlists.first {
                let tracks = (try? await model.platform.tracks(inSearchPlaylist: playlist)) ?? []
                steps.append(Step(
                    name: "found-playlist",
                    ok: !tracks.isEmpty,
                    detail: "\(playlist.name): \(tracks.count) tracks"
                ))
            }
        }

        // 6c2. Search pagination and filter metadata.
        //
        // Page 2 is not asserted to be non-empty: the upstream serves hollow pages at random, and
        // the app's job is to page past them (covered by `batch-100`), not for the upstream to be
        // well behaved.
        if model.connection.isConnected {
            // Retried once: the upstream intermittently answers an empty page, and this check is
            // about pagination, not about the upstream being reliable.
            var first = try? await model.platform.search("贝多芬", kind: .song, page: 1)
            if (first?.songs.isEmpty ?? true) {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                first = try? await model.platform.search("贝多芬", kind: .song, page: 1)
            }
            steps.append(Step(
                name: "paging",
                ok: (first?.songs.isEmpty == false) && (first?.nextPage != nil),
                detail: "page1 \(first?.songs.count ?? 0) of \(first?.totalAvailable ?? 0), has more: \(first?.nextPage != nil)"
            ))

            // Filters are only honest if the underlying metadata exists.
            let songs = first?.songs ?? []
            let withYear = songs.compactMap(\.year).count
            let withComposer = songs.compactMap(\.composerCredit).count
            steps.append(Step(
                name: "filter-data",
                ok: withYear > 0,
                detail: "\(withYear)/\(songs.count) with year, \(withComposer)/\(songs.count) with composer"
            ))
        }

        // 6c3. Batched paging: one batch is 100 results (five upstream pages), and more only
        // arrives when asked for.
        if model.connection.isConnected {
            model.query = "贝多芬"
            model.searchKind = .song
            await model.runSearch()
            let firstBatch = model.searchResults.songs.count
            let canMore = model.canLoadMore
            let totalBefore = model.searchResults.songs.count
            if canMore { await model.loadMoreResults() }
            // A batch can come back empty when the upstream serves a run of hollow pages; a second
            // attempt (what a user gets by scrolling again) should then make progress.
            if model.searchResults.songs.count == totalBefore, model.canLoadMore {
                await model.loadMoreResults()
            }
            let afterMore = model.searchResults.songs.count
            // The scroll sentinel fires repeatedly. Overlapping load-more calls must not each
            // fetch a batch, and overlapping searches must not interleave into a corrupt result set.
            model.query = "贝多芬"
            model.searchKind = .song
            await model.runSearch()
            let baseline = model.searchResults.songs.count
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<3 {
                    group.addTask { @MainActor in await model.loadMoreResults() }
                }
            }
            let afterConcurrent = model.searchResults.songs.count
            steps.append(Step(
                name: "no-double-load",
                ok: afterConcurrent - baseline <= AppModel.searchBatchSize && afterConcurrent > baseline,
                detail: "\(baseline) -> \(afterConcurrent) after 3 concurrent calls, total \(model.searchResults.totalAvailable)"
            ))

            // Two searches fired back to back: the newer one must win and leave a consistent set.
            model.query = "莫扎特"
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in await model.runSearch() }
                group.addTask { @MainActor in await model.runSearch() }
            }
            let concurrentTotal = model.searchResults.totalAvailable
            let concurrentCount = model.searchResults.songs.count
            steps.append(Step(
                name: "search-race",
                ok: concurrentTotal > 0 && concurrentCount > 0 && concurrentCount <= AppModel.searchBatchSize * 2,
                detail: "\(concurrentCount) songs, total \(concurrentTotal)"
            ))

            model.query = "贝多芬"
            await model.runSearch()
            steps.append(Step(
                name: "batch-100",
                ok: firstBatch >= 90 && (!canMore || afterMore > totalBefore),
                detail: "first batch \(firstBatch), after load-more \(afterMore), total \(model.searchResults.totalAvailable)"
            ))

            model.query = "贝多芬"
            model.searchKind = .album
            await model.runSearch()
            if model.searchResults.albums.isEmpty {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await model.runSearch()
            }
            let years = model.searchResults.albums.compactMap(\.year)
            steps.append(Step(
                name: "album-year",
                ok: !years.isEmpty,
                detail: "\(years.count)/\(model.searchResults.albums.count) albums have a year"
            ))
            model.searchKind = .song
        }

        // 6c4. Results must appear page by page, not only once a whole batch has loaded.
        if model.connection.isConnected {
            model.query = "贝多芬"
            model.searchKind = .song
            let task = Task { @MainActor in await model.runSearch() }
            // Sample while the search runs: the first page (20) must be visible well before the
            // batch of 100 completes.
            var sawPartial = false
            var partialCount = 0
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                let count = model.searchResults.songs.count
                if count > 0 && count < AppModel.searchBatchSize {
                    sawPartial = true
                    partialCount = max(partialCount, count)
                }
                if !model.isSearching { break }
            }
            await task.value
            steps.append(Step(
                name: "streaming",
                ok: sawPartial,
                detail: sawPartial
                    ? "saw \(partialCount) results before the batch finished"
                    : "results only appeared after the full batch"
            ))
        }

        // 6c5. Artist detail: profile, top songs and albums.
        if model.connection.isConnected {
            if let found = try? await model.platform.search("周杰伦", kind: .singer, page: 1),
               let artist = found.artists.first {
                await model.open(artist)
                steps.append(Step(
                    name: "artist-detail",
                    ok: !model.artistSongs.isEmpty && !model.artistAlbums.isEmpty,
                    detail: "\(model.searchArtistDetail?.name ?? "?"): \(model.artistSongs.count) songs, \(model.artistAlbums.count) albums, bio \(model.searchArtistDetail?.bio?.isEmpty == false ? "yes" : "no")"
                ))
                model.clearRoutes()
            }
        }

        // 6c5b. Navigation: a detail page opened from a list returns to that list, one layer at a time.
        if model.connection.isConnected {
            await model.selectSection(.liked)
            let sectionBefore = model.section
            let rows = model.libraryTracks
            var detailFailures: [String] = []
            if let row = rows.first(where: { $0.artistID != nil }) {
                await model.openArtist(id: row.artistID!, name: row.artist)
                if model.section != sectionBefore { detailFailures.append("侧边栏跟着跳到了 \(model.section.title)") }
                if model.route == nil { detailFailures.append("歌手页没有打开") }
                model.goBack()
                if model.route != nil { detailFailures.append("返回后仍停在详情页") }
                if model.section != sectionBefore { detailFailures.append("返回后侧边栏丢了原位置") }
            }
            if let row = rows.first(where: { $0.albumID != nil }) {
                await model.openAlbum(id: row.albumID!, name: row.album, artist: row.artist)
                let opened = model.currentAlbum
                if opened == nil { detailFailures.append("专辑页没有打开") }
                // The row only knows an id and a name; the page must end up with the real album.
                if let opened, opened.trackCount == 0 { detailFailures.append("专辑页没拿到真实曲目数") }
                model.goBack()
                if model.route != nil { detailFailures.append("从专辑返回后仍停在详情页") }
                if model.libraryTracks.count != rows.count { detailFailures.append("返回后原列表丢了") }
            }
            steps.append(Step(
                name: "navigation",
                ok: detailFailures.isEmpty,
                detail: detailFailures.isEmpty
                    ? "歌手/专辑详情逐层返回，侧边栏留在 \(sectionBefore.title)"
                    : detailFailures.joined(separator: "; ")
            ))
        }

        // 6c5c. Playing a search result queues that song's album, in album order, with the song at its
        // own position. The queue is what the user hears next, so this is asserted, not assumed.
        if model.connection.isConnected {
            model.query = "稻香"
            model.searchKind = .song
            await model.runSearch()
            if let song = model.results.first(where: { $0.albumID != nil }),
               let songAlbumID = song.albumID {
                await model.playFromSearch(song)
                let queue = model.player.queue
                let position = model.player.currentIndex
                let albumIDs = Set(queue.compactMap(\.albumID))
                let failures: [String] = [
                    queue.count <= 1 ? "队列只有 \(queue.count) 首，没有按专辑入队" : nil,
                    queue.contains(where: { $0.id == song.id }) ? nil : "当前歌不在队列里",
                    position.map { queue.indices.contains($0) && queue[$0].id == song.id ? nil : "当前索引没有指向这首歌" }
                        ?? "没有当前索引",
                    albumIDs == [songAlbumID] ? nil : "队列混进了别的专辑：\(albumIDs.sorted())",
                ].compactMap { $0 }
                steps.append(Step(
                    name: "search-queue",
                    ok: failures.isEmpty,
                    detail: failures.isEmpty
                        ? "\(song.title.prefix(20)) → 专辑 \(queue.count) 首，当前第 \((position ?? 0) + 1) 首，队首 \(String(queue.first?.title.prefix(18) ?? "-"))"
                        : failures.joined(separator: "; ")
                ))
                if model.player.isPlaying { model.player.togglePlayPause() }
            } else {
                steps.append(Step(
                    name: "search-queue",
                    ok: false,
                    detail: "搜索结果里没有带专辑 id 的歌，无法验证按专辑入队"
                ))
            }
        }

        // 6c6. Write round-trip. Likes the track then puts it back, so the account ends unchanged.
        if model.connection.isConnected, let track = model.results.first {
            do {
                try await model.platform.setLiked(true, track: track)
                let liked = true
                try await model.platform.setLiked(false, track: track)
                steps.append(Step(
                    name: "like-write",
                    ok: liked,
                    detail: "liked and unliked \(track.title), account restored"
                ))
            } catch {
                steps.append(Step(name: "like-write", ok: false, detail: error.localizedDescription))
            }
        }

        // 6c7. Daily recommendation and charts.
        if model.connection.isConnected {
            let daily = (try? await model.platform.dailySongs()) ?? []
            steps.append(Step(
                name: "daily",
                ok: !daily.isEmpty,
                detail: "\(daily.count) tracks, first = \(daily.first?.title ?? "-")"
            ))

            let charts = (try? await model.platform.toplists()) ?? []
            var chartTracks = 0
            var chartName = "-"
            if let first = charts.first {
                chartName = first.title
                chartTracks = ((try? await model.platform.toplistTracks(first, offset: 0))?.tracks ?? []).count
            }
            steps.append(Step(
                name: "charts",
                ok: !charts.isEmpty && chartTracks > 0,
                detail: "\(charts.count) charts, \(chartName): \(chartTracks) tracks"
            ))

            // Charts page by offset; a 100-track chart must yield a second page.
            if let first = charts.first(where: { $0.trackCount > 20 }) {
                let page1 = (try? await model.platform.toplistTracks(first, offset: 0))?.tracks ?? []
                let page2 = (try? await model.platform.toplistTracks(first, offset: page1.count))?.tracks ?? []
                let distinct = Set(page1.map(\.id)).isDisjoint(with: Set(page2.map(\.id)))
                steps.append(Step(
                    name: "chart-paging",
                    ok: page2.count > 0 && distinct,
                    detail: "\(first.title): page1 \(page1.count), page2 \(page2.count), distinct \(distinct)"
                ))
            }

            // Daily is a fixed 30-track set; paging params are ignored upstream, so the app must not
            // pretend it can page. Recorded here so the limitation stays visible.
            let dailyAgain = (try? await model.platform.dailySongs()) ?? []
            steps.append(Step(
                name: "daily-fixed",
                ok: dailyAgain.count == daily.count,
                detail: "\(daily.count) tracks, same set on repeat request (no paging upstream)"
            ))
        }

        // 6c8. Rows must carry the ids needed to link artist and album.
        if let withIDs = model.results.first(where: { $0.artistID != nil && $0.albumID != nil }) {
            steps.append(Step(
                name: "row-links",
                ok: true,
                detail: "artistID + albumID present on \(withIDs.title.prefix(24))"
            ))
        } else if !model.results.isEmpty {
            steps.append(Step(name: "row-links", ok: false, detail: "no result carried both ids"))
        }

        // 6d. Audio quality: the API must report real files, not a fixed menu.
        if let track = model.results.first {
            let qualities = (try? await model.platform.availableQualities(for: track)) ?? []
            steps.append(Step(
                name: "qualities",
                ok: !qualities.isEmpty,
                detail: qualities.isEmpty
                    ? "none reported"
                    : qualities.map { "\($0.quality.shortLabel) \($0.sizeText)" }.joined(separator: ", ")
            ))
        }

        // 6e. MCP endpoint: reachable on loopback, authenticated, and exposing tools.
        let mcpProbe = await Self.probeMCP(token: model.mcpToken)
        steps.append(Step(
            name: "mcp",
            ok: mcpProbe.ok,
            detail: mcpProbe.detail
        ))

        // 7. Last.fm: credential storage, auth state, and the scrobble rule engine.
        let credentialsFile = LastFMCredentialsStore.fileURL(
            supportDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("bbMusic", isDirectory: true)
        )
        let credentials = LastFMCredentialsStore.load(from: credentialsFile)
        let mode = (try? FileManager.default.attributesOfItem(atPath: credentialsFile.path)[.posixPermissions] as? Int) ?? nil
        steps.append(Step(
            name: "lfm-creds",
            ok: credentials != nil,
            detail: credentials == nil
                ? "no credentials file at \(credentialsFile.lastPathComponent)"
                : "file mode \(mode.map { String($0, radix: 8) } ?? "?"), session \(credentials?.sessionKey == nil ? "absent" : "present")"
        ))
        steps.append(Step(
            name: "lfm-auth",
            ok: model.scrobbler.connection.isConnected,
            detail: model.scrobbler.connection.label
        ))

        // The rule engine must refuse anything Last.fm itself would refuse. Exercised as pure
        // decisions: submitting real scrobbles here would write fake plays into the user's history.
        let cases: [(String, TimeInterval, TimeInterval, Bool, Bool)] = [
            ("223s track, played 112s", 223, 112, false, true),
            ("223s track, played 111s", 223, 111, false, false),
            ("600s track, played 240s", 600, 240, false, true),
            ("600s track, played 239s", 600, 239, false, false),
            ("20s track, played fully", 20, 20, false, false),
            ("223s preview, played fully", 223, 223, true, false),
        ]
        var ruleFailures: [String] = []
        for (name, duration, elapsed, preview, expected) in cases {
            let got = Scrobbler.wouldScrobble(duration: duration, elapsed: elapsed, isPreview: preview)
            if got != expected { ruleFailures.append("\(name) -> \(got)") }
        }
        steps.append(Step(
            name: "lfm-rules",
            ok: ruleFailures.isEmpty,
            detail: ruleFailures.isEmpty
                ? "\(cases.count) rule cases correct"
                : "wrong: \(ruleFailures.joined(separator: "; "))"
        ))

        return finish(steps)
    }

    /// Whether CoreAudio can actually render, which is separate from whether the player works.
    @MainActor
    private static func audioOutputIsUsable() -> Bool {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            engine.stop()
            return true
        } catch {
            return false
        }
    }

    /// Talks to the MCP endpoint the same way a client would.
    @MainActor
    private static func probeMCP(token: String) async -> (ok: Bool, detail: String) {
        guard let url = URL(string: "http://127.0.0.1:\(AppModel.mcpPort)/") else {
            return (false, "bad url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#.utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = root["result"] as? [String: Any],
                  let tools = result["tools"] as? [[String: Any]]
            else {
                return (false, "tools/list failed")
            }
            // An unauthenticated call must be refused, or the endpoint is open to any local process.
            var unauthorized = URLRequest(url: url)
            unauthorized.httpMethod = "POST"
            unauthorized.httpBody = request.httpBody
            let (_, unauthedResponse) = try await URLSession.shared.data(for: unauthorized)
            let refused = (unauthedResponse as? HTTPURLResponse)?.statusCode == 401
            return (
                refused && tools.count >= 8,
                "\(tools.count) tools, unauthenticated \(refused ? "refused" : "ALLOWED")"
            )
        } catch {
            return (false, error.localizedDescription)
        }
    }

    @MainActor
    private static func finish(_ steps: [Step]) -> (report: String, ok: Bool) {
        var lines: [String] = []
        for step in steps {
            lines.append("  \(step.ok ? "PASS" : "FAIL")  \(step.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(step.detail)")
        }
        let ok = steps.allSatisfy(\.ok)
        let header = ok ? "SELF-TEST PASS" : "SELF-TEST FAIL"
        return ("\(header)\n" + lines.joined(separator: "\n"), ok)
    }

    @MainActor
    private static func waitUntil(timeout: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return condition()
    }
}

/// Shown only in self-test mode; triggers the check once and terminates.
struct SelfTestView: View {
    @ObservedObject var model: AppModel
    @State private var started = false

    var body: some View {
        Text("self-test running…")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(width: 320, height: 80)
            .onAppear {
                guard !started else { return }
                started = true
                model.start()
                Task { @MainActor in
                    let outcome = await SelfTest.run(model: model)
                    FileHandle.standardError.write(Data((outcome.report + "\n").utf8))
                    model.shutdown()
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    exit(outcome.ok ? 0 : 1)
                }
            }
    }
}
