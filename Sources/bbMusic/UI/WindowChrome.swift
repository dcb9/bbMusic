import AppKit
import SwiftUI

/// Makes the window's title bar part of the app's own surface.
///
/// By default macOS draws a grey strip with a centred title, which is the one piece of the window
/// that does not belong to the palette. Making the title bar transparent, hiding its title and
/// letting the content view extend into it means the strip can be drawn from the same forest-green
/// plate as the sidebar — the window then reads as one object rather than a themed page inside a
/// system frame.
///
/// Configuration happens in `viewDidMoveToWindow`, not in `makeNSView`: the view is created before
/// SwiftUI has attached it to a window, so there is nothing to configure yet, and a one-shot
/// `DispatchQueue.main.async` is not guaranteed to land after the attachment either.
///
/// The traffic lights are deliberately left where macOS puts them: they are the controls every Mac
/// user already knows, and re-drawing them would trade muscle memory for a colour match.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ChromeView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ChromeView)?.apply()
    }

    private final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // AppKit builds (and may rebuild) the title bar after the first layout pass, so one
            // attempt can land too early and leave the system strip in place.
            DispatchQueue.main.async { [weak self] in self?.apply() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.apply() }
        }

        func apply() {
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // The whole window must not drag: sliders and lists live in it. Only the title bar's own
            // background is a drag area (see `WindowDragArea`).
            window.isMovableByWindowBackground = false
        }
    }
}

/// Makes a strip of app-drawn content behave like a title bar: dragging it moves the window.
///
/// `mouseDownCanMoveWindow` lets AppKit move the window without the view ever swallowing a click, so
/// a button drawn on top of this still receives its own presses.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

/// The app's identity, drawn at the top of the sidebar.
///
/// The window has no title bar of its own: the sidebar's green plate reaches the top edge and the
/// traffic lights float over it, the way Finder's sidebar works. This row is the one thing that
/// replaces the system's title — the app's name and what is currently on screen.
struct TitleBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: Player
    @Environment(\.palette) private var palette

    /// Room for the traffic lights, which sit at the window's top-left over this plate.
    private let trafficLightInset: CGFloat = 78

    var body: some View {
        HStack(spacing: 6) {
            Text("bbMusic")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(palette.sidebar.text)
            Spacer(minLength: 6)
            if player.currentTrack != nil {
                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(palette.sidebar.tertiaryText)
            }
        }
        .padding(.leading, trafficLightInset)
        .padding(.trailing, 12)
        .frame(height: Theme.Metrics.titleBarHeight)
        // Dragging the plate moves the window, the way a title bar does.
        .background(WindowDragArea())
    }
}
