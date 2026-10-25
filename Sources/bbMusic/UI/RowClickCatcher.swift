import AppKit
import SwiftUI

/// Turns a click on a row into a selection, on mouse-down, with no disambiguation delay — and a second
/// click into a play.
///
/// SwiftUI's `TapGesture` cannot report a single click promptly when a double-click gesture shares the
/// view: it has to wait out `NSEvent.doubleClickInterval` (0.5 s) to learn whether a second click is
/// coming. Measured on this app, that made selecting a row take 220–370 ms. So the double-click is not
/// a SwiftUI gesture here. `NSEvent.clickCount` is computed by the window server and arrives *with* the
/// press, which means the first click can select immediately and the second can play immediately, with
/// no waiting in between — the gesture recogniser's 0.5 s window never exists.
///
/// Selection happens on the first click of a double-click too: the row is selected by the time the
/// second click lands, which is the same order a Finder list uses.
///
/// It is installed as the row's background, not an overlay, so it never covers the row's own controls:
/// SwiftUI's buttons claim their points first, and a click anywhere else falls through to this view.
/// That is also why a double-click on the artist or album column opens its page instead of playing —
/// those are buttons, and they get the event first.
struct RowClickCatcher: NSViewRepresentable {
    var onClick: () -> Void
    /// Called on the second click of a double-click. `nil` leaves double-click doing nothing extra.
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = ClickView(frame: .zero)
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ClickView else { return }
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
    }

    final class ClickView: NSView {
        var onClick: () -> Void = {}
        var onDoubleClick: (() -> Void)?

        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            // Acting on the press rather than the release is what makes selection feel attached to the
            // pointer. Every macOS list selects this way.
            //
            // `clickCount` is 1 on the first press and 2 on the second, so this branch decides the
            // whole interaction without ever waiting to see whether another click follows.
            if event.clickCount >= 2, let onDoubleClick {
                onDoubleClick()
            } else {
                onClick()
            }
        }

        /// A view that receives a click also receives the wheel. Without this, scrolling with the
        /// pointer over a row would do nothing.
        override func scrollWheel(with event: NSEvent) {
            nextResponder?.scrollWheel(with: event)
        }
    }
}
