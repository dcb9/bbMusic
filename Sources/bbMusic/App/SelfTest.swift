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

    @MainActor
    static func run(model: AppModel) async -> (report: String, ok: Bool) {
        var steps: [Step] = []

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
        let advanced = await waitUntil(timeout: 20) {
            model.player.currentTime > 1.0
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
            ) + " notice=\(model.player.notice ?? "none")"
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
                model.closeDetail()
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
            model.closeDetail()
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
                    let results = try await model.platform.search("周杰伦", kind: kind)
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
            if let found = try? await model.platform.search("周杰伦", kind: .playlist),
               let playlist = found.playlists.first {
                let tracks = (try? await model.platform.tracks(inSearchPlaylist: playlist)) ?? []
                steps.append(Step(
                    name: "found-playlist",
                    ok: !tracks.isEmpty,
                    detail: "\(playlist.name): \(tracks.count) tracks"
                ))
            }
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
