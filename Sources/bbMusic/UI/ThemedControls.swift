import SwiftUI

/// Segmented control in the app's own palette.
///
/// `Picker(.segmented)` is drawn by AppKit and ignores `tint`, so it kept showing the system's grey
/// capsule inside a paper window — the one control that never joined the theme. This draws the same
/// affordance with the palette instead: a recessed track, a raised pill for the selection, and a
/// hairline between unselected segments.
struct ThemedSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    var width: CGFloat?
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.value) { index, option in
                if index > 0, selection != option.value,
                   selection != options[index - 1].value {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1, height: 12)
                }
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: selection == option.value ? .medium : .regular))
                        .foregroundStyle(selection == option.value ? palette.playButtonGlyph : Color.secondary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(selection == option.value ? palette.playButton : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(palette.chip)
        )
        .frame(width: width)
    }
}
