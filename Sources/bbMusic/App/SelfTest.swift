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

        // 3. Search
        model.query = "稻香"
        await model.runSearch()
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
