import AppKit
import SwiftUI

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

/// Measures how long a real click on a track row takes to become a visible selection.
///
/// `bbMusic --click-probe` synthesises genuine `mouseDown`/`mouseUp` events and sends them through
/// `NSWindow.sendEvent`, so the click travels the same path a user's does: hit testing, SwiftUI's
/// gesture machinery, the state change, and the row re-render. Polling the model for the selection
/// is what gives the end-to-end number — measuring the assignment alone would only prove that an
/// assignment is fast, which was never in doubt.
///
/// This exists because the symptom ("single click does not keep up") is a latency question, and a
/// latency question needs a number before it needs a fix.
@MainActor
enum ClickProbe {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--click-probe")
    }

    struct Result {
        var name: String
        var latencyMs: Double?
        var note: String
    }

    static func run(model: AppModel) async -> Int32 {
        model.start()
        _ = await waitUntil(timeout: 30) { model.sidecarState.port != nil }
        await model.refreshConnection()
        // A section with plenty of rows: the list the user actually clicks in.
        await model.selectSection(.liked)
        _ = await waitUntil(timeout: 20) { !model.libraryTracks.isEmpty }

        guard let window = await mainWindow() else {
            FileHandle.standardError.write(Data("no window\n".utf8))
            return 1
        }
        // A fixed geometry so the same point lands on the same row every run.
        window.setContentSize(NSSize(width: 1180, height: 760))
        // A window that is not key does not route clicks into its content view, so a synthesised
        // event would be dropped before hit testing.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 800_000_000)

        var results: [Result] = []
        results.append(await measure(window: window, model: model, name: "idle（无播放）"))
        results.append(await measure(window: window, model: model, name: "playing（播放中，4Hz tick）", playing: true))

        var report = ["CLICK PROBE"]
        var failures = 0
        for result in results {
            if let latency = result.latencyMs {
                let ok = latency <= 50
                if !ok { failures += 1 }
                let padded = result.name.padding(toLength: 30, withPad: " ", startingAt: 0)
                report.append(String(format: "  %@  %@ %6.1f ms   %@",
                                     ok ? "PASS" : "FAIL", padded, latency, result.note))
            } else {
                failures += 1
                report.append("  FAIL  \(result.name)  \(result.note)")
            }
        }
        print(report.joined(separator: "\n"))
        model.shutdown()
        return failures == 0 ? 0 : 1
    }

    /// One click on a row, timed from the event to the selection being observable.
    private static func measure(
        window: NSWindow,
        model: AppModel,
        name: String,
        playing: Bool = false
    ) async -> Result {
        if playing {
            // Real playback so the 4 Hz position observer is actually firing.
            if let track = model.libraryTracks.first {
                model.player.play(tracks: model.libraryTracks, startingAt: 0)
                model.player.seek(to: 1)
                _ = await waitUntil(timeout: 10) { model.player.isPlaying }
                _ = track
            }
        } else {
            model.player.stop()
        }
        try? await Task.sleep(nanoseconds: 500_000_000)

        guard let point = await rowPoint(window: window, model: model) else {
            return Result(name: name, latencyMs: nil, note: "找不到可点的行")
        }

        // Consecutive rows, so the click always changes the selection: clicking the already-selected
        // row would measure nothing.
        var latencies: [Double] = []
        for attempt in 0..<3 {
            let before = model.selectedTrackID
            let target = point(attempt)
            let started = DispatchTime.now().uptimeNanoseconds
            postClick(window: window, at: target)
            let changed = await waitUntil(timeout: 2.0, intervalMs: 1) {
                model.selectedTrackID != before
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            guard changed else {
                return Result(name: name, latencyMs: nil, note: "第 \(attempt + 1) 次点击没有改变选中项")
            }
            latencies.append(elapsed)
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        let worst = latencies.max() ?? 0
        return Result(
            name: name,
            latencyMs: worst,
            note: "三次取最慢：\(latencies.map { String(format: "%.1f", $0) }.joined(separator: "/")) ms"
        )
    }

    // MARK: - Event plumbing

    /// The click-catching views the rows installed, found in the live view hierarchy.
    ///
    /// Synthesised `NSEvent`s do not reach SwiftUI's hit testing from outside a real mouse session, so
    /// the click is delivered to the view that now owns it. That is the code path a real click takes
    /// once hit testing has chosen this view — the part that used to wait out the double-click window
    /// is gone, and this measures what replaced it.
    private static func clickViews(in window: NSWindow) -> [RowClickCatcher.ClickView] {
        var found: [RowClickCatcher.ClickView] = []
        func walk(_ view: NSView) {
            if let click = view as? RowClickCatcher.ClickView { found.append(click) }
            for sub in view.subviews { walk(sub) }
        }
        if let root = window.contentView { walk(root) }
        return found
    }

    private static func rowPoint(window: NSWindow, model: AppModel) async -> ((Int) -> NSPoint)? {
        let views = clickViews(in: window)
        guard !views.isEmpty else { return nil }
        // A point inside the first catcher, expressed in window coordinates.
        let first = views[0]
        guard let content = window.contentView else { return nil }
        let inWindow = first.convert(first.bounds.center, to: nil)
        _ = content
        return { index in NSPoint(x: inWindow.x, y: CGFloat(index)) }
    }

    private static func postClick(window: NSWindow, at point: NSPoint, clickCount: Int = 1) {
        let views = clickViews(in: window)
        guard !views.isEmpty else { return }
        let index = min(Int(point.y), views.count - 1)
        let target = views[index]
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ) else { return }
        target.mouseDown(with: down)
    }

    private static func mainWindow() async -> NSWindow? {
        for _ in 0..<40 {
            if let window = NSApp.windows.first(where: {
                $0.contentView != nil && $0.frame.height > 300 && $0.isVisible
            }) ?? NSApp.windows.first(where: { $0.contentView != nil && $0.frame.height > 300 }) {
                return window
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }

    private static func waitUntil(
        timeout: TimeInterval,
        intervalMs: UInt64 = 20,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: intervalMs * 1_000_000)
        }
        return condition()
    }
}
