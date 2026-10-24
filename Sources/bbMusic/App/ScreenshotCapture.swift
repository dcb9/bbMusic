import AppKit
import SwiftUI

/// Renders each page of the app to PNG: `bbMusic --capture-screenshots <directory>`.
///
/// Synthetic mouse events need Accessibility permission, which a terminal does not have here, so
/// driving the UI from outside is not possible. Rendering from inside the app needs no permission
/// at all and produces the same image every run, which also makes these screenshots reproducible
/// for the README instead of being one-off manual captures.
@MainActor
enum ScreenshotCapture {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--capture-screenshots")
    }

    /// `--appearance dark` renders the dark palette; the default follows the system.
    ///
    /// Both appearances ship, so both need a reproducible capture — driving the system setting from
    /// a script would change the user's whole desktop for the duration of the run.
    static var requestedAppearance: NSAppearance? {
        guard let index = CommandLine.arguments.firstIndex(of: "--appearance"),
              index + 1 < CommandLine.arguments.count else { return nil }
        switch CommandLine.arguments[index + 1] {
        case "dark": return NSAppearance(named: .darkAqua)
        case "light": return NSAppearance(named: .aqua)
        default: return nil
        }
    }

    static var outputDirectory: URL {
        if let index = CommandLine.arguments.firstIndex(of: "--capture-screenshots"),
           index + 1 < CommandLine.arguments.count {
            return URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        return URL(fileURLWithPath: "docs/screenshots")
    }

    static func run(model: AppModel) async -> Int32 {
        let directory = outputDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // A fixed size makes the screenshots comparable run to run.
        await setWindowSize(CGSize(width: 1180, height: 760))
        // The queue shot starts real playback; keep it barely audible rather than taking over the
        // machine. It is also the marker that this run is a test, not the user's own listening.
        model.player.volume = 0.02
        model.start()
        // After `start()`, which restores the saved appearance: a capture run forces the palette it
        // was asked for, and must not leave that choice saved for the user's next launch.
        if let appearance = requestedAppearance {
            NSApp.appearance = appearance
        }
        // Wait for the sidecar, then for the account so the pages have real data.
        _ = await waitUntil(timeout: 30) { model.sidecarState.port != nil }
        await model.refreshConnection()
        await model.loadLibrary()
        _ = await waitUntil(timeout: 30) { !model.playlists.isEmpty }

        guard let window = await mainWindow() else {
            FileHandle.standardError.write(Data("no window to capture\n".utf8))
            return 1
        }

        var shots: [(String, () async -> Void)] = []

        // 1. Search results
        shots.append(("01-search", {
            model.section = .search
            model.searchKind = .song
            model.query = "贝多芬"
            await model.runSearch()
        }))

        // 2. Daily recommendation
        shots.append(("02-daily", {
            await model.selectSection(.daily)
        }))

        // 3. Charts index
        shots.append(("03-charts", {
            await model.selectSection(.charts)
        }))

        // 4. One chart's tracks
        shots.append(("04-chart-detail", {
            if let first = model.toplists.first(where: { $0.trackCount > 20 }) {
                await model.open(first)
            }
        }))

        // 5. Playlists grid
        shots.append(("05-playlists", {
            await model.selectSection(.playlists)
        }))

        // 6. Albums grid
        shots.append(("06-albums", {
            await model.selectSection(.albums)
        }))

        // 7. Liked songs, with hearts visible
        shots.append(("07-liked", {
            await model.selectSection(.liked)
        }))

        // 8. Artist page
        shots.append(("08-artist", {
            model.clearRoutes()
            model.section = .search
            if let found = try? await model.platform.search("周杰伦", kind: .singer, page: 1),
               let artist = found.artists.first {
                await model.open(artist)
            }
        }))

        // 9. Classical album detail — shows composer and disc structure
        shots.append(("09-album-classical", {
            model.clearRoutes()
            model.section = .albums
            if let album = model.albums.first(where: {
                $0.name.lowercased().contains("beethoven") || $0.name.contains("古典")
            }) ?? model.albums.first {
                await model.open(album)
            }
        }))

        // 10. Now playing + queue
        shots.append(("10-queue", {
            model.clearRoutes()
            model.section = .search
            model.searchKind = .song
            model.query = "稻香"
            await model.runSearch()
            // Play through the same path the UI uses, so the queue shot shows what a user would
            // actually get: the song's album, not the result list.
            if let first = model.results.first {
                await model.playFromSearch(first)
            }
            // The state that used to be misleading: the row that was clicked stays selected while a
            // later row plays. Selecting the queue's first track makes both states true at once, so the
            // shot can show that the playing row — not the selected one — is the highlighted one.
            model.player.next()
            model.player.next()
            model.selectedTrackID = model.player.queue.first?.id
            model.showQueue = true
        }))

        // 11. Lyrics
        shots.append(("11-lyrics", {
            model.showQueue = false
            model.pane = .lyrics
        }))

        // 11a. A row with its hover actions visible: play, detail and the heart.
        shots.append(("13-row-actions", {
            model.clearRoutes()
            model.section = .daily
            await model.selectSection(.daily)
            model.selectedTrackID = model.libraryTracks.dropFirst(2).first?.id
            await setMouseOverRow()
        }))

        // 11b. The player bar's hover feedback: a wash on the control under the pointer and, after
        // the delay, its name in a bubble. Only visible with the pointer parked on a button, so it
        // cannot be captured by rendering a page alone.
        shots.append(("16-player-bar-hover", {
            model.clearRoutes()
            model.section = .search
            await setMouseOverQueueButton()
        }))

        // 11c. A playlist page with the facts the API reports, and the collect button.
        shots.append(("14-playlist-detail", {
            model.clearRoutes()
            model.section = .playlists
            await model.selectSection(.playlists)
            if let playlist = model.playlists.first(where: { !$0.isLikedSongs }) {
                await model.open(playlist)
            }
        }))

        // 11d. The same page's own play button, under the blurb.
        shots.append(("17-playlist-play", {
            model.clearRoutes()
            model.section = .playlists
            await model.selectSection(.playlists)
            if let playlist = model.playlists.first(where: { !$0.isLikedSongs }) {
                await model.open(playlist)
            }
        }))

        // 11e. An album page with its full metadata.
        shots.append(("15-album-detail", {
            model.clearRoutes()
            model.section = .albums
            await model.selectSection(.albums)
            if let album = model.albums.first {
                await model.open(album)
            }
        }))

        // 12. The song's own page, reached from the player bar's left block. A multi-artist track is
        // preferred so the screenshot shows the credit split into separate, clickable names.
        shots.append(("12-track-detail", {
            model.pane = .list
            model.query = "不该 周杰伦"
            model.searchKind = .song
            await model.runSearch()
            if let duet = model.results.first(where: { TrackDisplay.performers(from: $0.artist).count > 1 }) {
                await model.playFromSearch(duet)
            }
            model.toggleTrackDetail()
            // The facts arrive from their own request; give it a moment before the shutter.
            _ = await waitUntil(timeout: 8) { model.trackDetail != nil }
        }))

        var failures = 0
        for (name, prepare) in shots {
            await prepare()
            // Give async image loads and list layout a moment to settle.
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            let url = directory.appendingPathComponent("\(name).png")
            if capture(window: window, to: url) {
                print("captured \(name).png")
            } else {
                print("FAILED \(name)")
                failures += 1
            }
        }

        model.shutdown()
        try? await Task.sleep(nanoseconds: 400_000_000)
        return failures == 0 ? 0 : 1
    }

    /// Parks the pointer on the ⓘ button of a row so the hover-only actions, the wash on the one under
    /// the pointer, and its label are all captured. A row without the pointer on it would show none.
    ///
    /// The point is the row's action group: 66pt wide, sitting before the 44pt duration column and the
    /// 14pt trailing padding, with the three 20pt buttons ending at its right edge — so the middle one
    /// (ⓘ) is centred 20pt in from the group's trailing edge.
    private static func setMouseOverRow(rowIndex: Int = 2) async {
        guard let window = await mainWindow() else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 400_000_000)
        let frame = window.frame
        // Row geometry: 44pt header, then 30pt-minimum rows that grow for long titles. Row 3 sits
        // around 100pt down in the fixed capture layout.
        let y = frame.height - CGFloat(104 + rowIndex * 62)
        // Two moves: the first makes SwiftUI notice the pointer is in the window, the second lands it
        // on the button. A single warp sometimes leaves hover tracking with nothing to react to.
        await movePointer(in: window, to: CGPoint(x: frame.width - 300, y: y))
        try? await Task.sleep(nanoseconds: 250_000_000)
        await movePointer(in: window, to: CGPoint(x: frame.width - 90, y: y))
        // Longer than `HoverTip.delay`, so the bubble is up when the shutter opens.
        try? await Task.sleep(nanoseconds: 700_000_000)
    }

    /// Parks the pointer on the queue button in the player bar, which is the state the hover feedback
    /// exists for: the control under the pointer carries a wash, and after `HoverTip.delay` its name in
    /// a bubble. Only reachable with the pointer actually on the button, so it cannot be captured by
    /// rendering a page alone.
    private static func setMouseOverQueueButton() async {
        guard let window = await mainWindow() else { return }
        // SwiftUI only tracks hover inside a key window, and a capture run never makes the app
        // active on its own.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 400_000_000)
        let frame = window.frame
        // The queue button is in the player bar, the window's bottom strip. Window coordinates count
        // from the bottom-left; the window server's count from the top-left of the screen.
        await movePointer(
            in: window,
            to: CGPoint(x: frame.width - 82, y: Theme.Metrics.playerBarHeight / 2)
        )
        // Longer than `HoverTip.delay`, so the bubble is up when the shutter opens.
        try? await Task.sleep(nanoseconds: 700_000_000)
    }

    /// Moves the pointer to a point in the window's own coordinates and delivers the move event, so
    /// SwiftUI's hover tracking sees it arrive. Warping the cursor alone changes where it is without
    /// producing the event tracking areas listen for.
    private static func movePointer(in window: NSWindow, to point: CGPoint) async {
        let frame = window.frame
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(
            CGPoint(x: frame.minX + point.x, y: screenHeight - (frame.minY + point.y))
        )
        try? await Task.sleep(nanoseconds: 250_000_000)
        if let move = NSEvent.mouseEvent(
            with: .mouseMoved, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ) {
            window.sendEvent(move)
        }
    }

    private static func setWindowSize(_ size: CGSize) async {
        for _ in 0..<40 {
            if let window = NSApp.windows.first(where: { $0.contentView != nil && $0.frame.height > 300 }) {
                var frame = window.frame
                frame.size = size
                window.setFrame(frame, display: true)
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// The main window, once AppKit has created it.
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

    /// Renders the window's content view into a PNG.
    ///
    /// `cacheDisplay` draws the view hierarchy into a bitmap without going through the window
    /// server, so it needs no screen-recording permission and captures exactly what the app drew.
    private static func capture(window: NSWindow, to url: URL) -> Bool {
        guard let view = window.contentView else { return false }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return false }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    private static func waitUntil(timeout: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return condition()
    }
}

/// Minimal host used only in capture mode.
struct ScreenshotCaptureView: View {
    @ObservedObject var model: AppModel
    @State private var started = false

    var body: some View {
        Text("capturing…")
            .font(.system(size: 11))
            .frame(width: 320, height: 80)
            .onAppear {
                guard !started else { return }
                started = true
                Task { @MainActor in
                    let code = await ScreenshotCapture.run(model: model)
                    exit(code)
                }
            }
    }
}
