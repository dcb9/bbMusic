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
