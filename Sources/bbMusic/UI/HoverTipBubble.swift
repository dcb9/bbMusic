import AppKit
import SwiftUI

/// The label a control shows above itself once the pointer has rested on it.
///
/// Drawn rather than borrowed from the system so it matches the window: the sidebar's forest green as
/// the plate, the bone text on top of it, a small pointer at the bottom edge. It never takes part in
/// hit testing — a bubble that swallowed clicks would make the control underneath it unclickable for
/// as long as the tooltip was up.
struct HoverTipBubble: View {
    let text: String
    /// How far the tail sits from the plate's centre. Non-zero when the plate had to slide inward to
    /// stay inside the window; the tail keeps pointing at the control rather than following the plate.
    var tailOffset: CGFloat = 0
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text)
            .font(Self.font)
            .foregroundStyle(palette.sidebar.text)
            .fixedSize()
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, Self.verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(palette.sidebar.background)
            )
            .overlay(alignment: .bottom) {
                Pointer()
                    .fill(palette.sidebar.background)
                    .frame(width: Self.tailWidth, height: Self.tailHeight)
                    .offset(x: tailOffset, y: Self.tailHeight)
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            // The bubble is the whole point of the delay, so it fades rather than snaps: a hard cut
            // reads as a rendering glitch on a control the pointer is still resting on.
            .transition(.opacity)
    }

    // MARK: - Size

    static let font = Font.system(size: 10.5)
    static let horizontalPadding: CGFloat = 7
    static let verticalPadding: CGFloat = 3
    static let tailWidth: CGFloat = 8
    static let tailHeight: CGFloat = 4

    /// The plate's width for a label, measured from the text rather than from a rendered view.
    ///
    /// Measuring the drawn bubble with a `GeometryReader` and feeding the result back into placement
    /// looks tidier but cannot work here: the bubble has to be laid out before its size is known, the
    /// size arrives a frame later, and re-laying out to apply it interrupts the hover that owns the
    /// bubble. Measuring the string is exact, synchronous, and has no layout pass to interrupt.
    ///
    /// Widths range from 35pt (`歌词`) to 107pt (`播放模式 · 顺序播放`), which is why a hard-coded width
    /// is not an option: an assumed 120pt plate pushed the 词 bubble 42pt off its own button.
    static func width(of text: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5),
        ]
        return ceil((text as NSString).size(withAttributes: attributes).width)
            + horizontalPadding * 2
    }

    /// The plate's height, tail included.
    static var height: CGFloat {
        let line = ceil(NSFont.systemFont(ofSize: 10.5).ascender - NSFont.systemFont(ofSize: 10.5).descender)
        return line + verticalPadding * 2
    }

    /// The little triangle under the plate.
    private struct Pointer: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
}
