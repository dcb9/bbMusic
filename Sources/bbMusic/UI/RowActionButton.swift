import SwiftUI

/// One of a track row's small actions, with a hover fill and a delayed label.
///
/// Three 18pt glyphs sitting next to each other give no feedback about which one the pointer is over,
/// and a click that lands one icon off does the wrong thing. The hover wash names the target; the label
/// that follows says what it does.
///
/// Both come from the window's shared `hoverFeedback`, which also owns the delay and draws the bubble
/// over the window — a bubble anchored to the button would sit inside the row's scroll view and be cut
/// off on the first row.
struct RowActionButton: View {
    let symbol: String
    let help: String
    var tint: Color = .secondary
    /// Accent for a heart that is already set: its resting colour is the accent, not the neutral.
    var activeTint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFeedback(help, tint: activeTint ?? tint, shape: .rounded)
    }
}
