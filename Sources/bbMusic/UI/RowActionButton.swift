import SwiftUI

/// One of a track row's small actions, with a hover fill.
///
/// Three 18pt glyphs sitting next to each other give no feedback about which one the pointer is over,
/// and a click that lands one icon off does the wrong thing. A faint rounded fill on hover names the
/// target without adding a border or a second colour to the row.
struct RowActionButton: View {
    let symbol: String
    let help: String
    var tint: Color = .secondary
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(isHovering ? palette.accent : tint)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Self.fill(isHovering: isHovering, accent: palette.accent))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
    }

    /// The hover fill, isolated so its behaviour is checkable without rendering: nothing when the
    /// pointer is elsewhere, a faint accent wash when it is on this button.
    static func fill(isHovering: Bool, accent: Color) -> Color {
        isHovering ? accent.opacity(0.14) : .clear
    }
}
