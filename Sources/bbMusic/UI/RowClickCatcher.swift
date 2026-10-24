import AppKit
import SwiftUI

/// Turns a click on a row into a selection, on mouse-down, with no disambiguation delay.
///
/// SwiftUI's `TapGesture` cannot report a single click promptly when a double-click gesture shares the
/// view: it has to wait out `NSEvent.doubleClickInterval` (0.5 s) to learn whether a second click is
/// coming. Measured on this app, that made selecting a row take 220–370 ms.
///
/// This app no longer has a double-click action at all — playing is a button on the row and a context
/// menu item — so there is nothing to disambiguate. `NSEvent.clickCount` is computed by the window
/// server and arrives with the press, which is why acting in `mouseDown` is both immediate and exact.
///
/// It is installed as the row's background, not an overlay, so it never covers the row's own controls:
/// SwiftUI's buttons claim their points first, and a click anywhere else falls through to this view.
struct RowClickCatcher: NSViewRepresentable {
    var onClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ClickView(frame: .zero)
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ClickView)?.onClick = onClick
    }

    final class ClickView: NSView {
        var onClick: () -> Void = {}

        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            // Acting on the press rather than the release is what makes selection feel attached to the
            // pointer. Every macOS list selects this way.
            onClick()
        }

        /// A view that receives a click also receives the wheel. Without this, scrolling with the
        /// pointer over a row would do nothing.
        override func scrollWheel(with event: NSEvent) {
            nextResponder?.scrollWheel(with: event)
        }
    }
}
