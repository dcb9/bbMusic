import SwiftUI

/// The window's palette, taken from the app icon: deep forest green as the chrome, warm bone paper
/// as the content.
///
/// Both appearances are spelled out rather than left to the system. The sidebar sits on a dark
/// green plate, where the system's own label colours would resolve to the *light* appearance's dark
/// greys and become unreadable — so it carries its own text colours. The content area stays on
/// paper tones close enough to the system window background that `.primary` / `.secondary` /
/// `.tertiary` keep working unchanged.
enum Theme {
    /// Sidebar plate and its text: bone on forest, the icon's own contrast.
    static let sidebarLight = Sidebar(
        background: Color(hex: 0x22382B),
        text: Color(hex: 0xE8E4D8),
        secondaryText: Color(hex: 0xA8B8AB),
        tertiaryText: Color(hex: 0x7E8F80),
        selection: Color(hex: 0x3A5A46),
        accent: Color(hex: 0x9FD0B2),
        divider: Color(hex: 0x2E4636),
        statusDot: Color(hex: 0x8FCBA6)
    )

    /// Dark appearance: the plate drops *below* the content, keeping the light palette's
    /// relationship — the sidebar is always the deeper layer.
    ///
    /// The gap is measured, not eyeballed: a first pass at `#16241C` against a `#1B1F1A` content area
    /// was a 1.04 luminance ratio, i.e. the sidebar vanished into the window. `#0E1E16` against
    /// `#242A23` is 1.18 — visible as a panel without becoming a second colour.
    static let sidebarDark = Sidebar(
        background: Color(hex: 0x0E1E16),
        text: Color(hex: 0xE8E4D8),
        secondaryText: Color(hex: 0xA8B8AB),
        tertiaryText: Color(hex: 0x88998B),
        selection: Color(hex: 0x1F3A2A),
        accent: Color(hex: 0x9FD0B2),
        divider: Color(hex: 0x1B3124),
        statusDot: Color(hex: 0x8FCBA6)
    )

    struct Sidebar {
        let background: Color
        let text: Color
        let secondaryText: Color
        let tertiaryText: Color
        let selection: Color
        let accent: Color
        let divider: Color
        let statusDot: Color
    }

    /// Accent: forest green on paper, moss green on the dark content. Both clear 4.5:1 against the
    /// surface they sit on.
    static let accentLight = Color(hex: 0x2E6B4F)
    static let accentDark = Color(hex: 0x7FBF97)

    enum Metrics {
        /// Widened by 6pt: the green plate needs a little more air around its labels.
        static let sidebarWidth: CGFloat = 216
        /// The app draws its own title bar; this is how tall it is. A standard macOS title bar is
        /// 28pt, and the traffic lights are centred in it — matching that height is what makes the
        /// green plate reach the top edge of the window instead of leaving a grey strip above it.
        static let titleBarHeight: CGFloat = 28
        static let playerBarHeight: CGFloat = 60
        /// Artwork cards. 10pt reads as a record sleeve rather than a button.
        static let cardCornerRadius: CGFloat = 10
        static let artworkCornerRadius: CGFloat = 6
        static let rowMinHeight: CGFloat = 30
    }
}

/// Everything a view needs from the palette, resolved once at the root and passed down.
struct Palette {
    let isDark: Bool
    /// Content area behind lists and grids.
    let content: Color
    /// Text fields and other inputs sitting on `content`.
    let field: Color
    /// The filter strip above a list.
    let filterBar: Color
    /// Small pill behind a filter menu label.
    let chip: Color
    /// Transport button: a filled disc, so it needs its own foreground.
    let playButton: Color
    let playButtonGlyph: Color
    let accent: Color
    let sidebar: Theme.Sidebar

    static let light = Palette(
        isDark: false,
        content: Color(hex: 0xFAF8F3),
        field: Color(hex: 0xFFFFFF),
        filterBar: Color(hex: 0xF4F1E8),
        chip: Color(hex: 0xEAE6DA),
        playButton: Color(hex: 0x2E6B4F),
        playButtonGlyph: Color(hex: 0xFBF9F2),
        accent: Theme.accentLight,
        sidebar: Theme.sidebarLight
    )

    static let dark = Palette(
        isDark: true,
        content: Color(hex: 0x242A23),
        field: Color(hex: 0x1C211C),
        filterBar: Color(hex: 0x1F241E),
        chip: Color(hex: 0x2E352D),
        playButton: Color(hex: 0x7FBF97),
        playButtonGlyph: Color(hex: 0x15201A),
        accent: Theme.accentDark,
        sidebar: Theme.sidebarDark
    )

    static func resolve(_ scheme: ColorScheme) -> Palette {
        scheme == .dark ? .dark : .light
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.light
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

extension Color {
    /// Hex literal for the colours that must be exact — they are the icon's palette, not system
    /// colours, so they cannot be expressed as semantic styles.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// The icon's mark — the musical double flat — drawn as a shape.
///
/// Used where the app has nothing to show (an empty list, a pane that could not load), so the
/// icon and the window agree on one symbol. Geometry is a simplified copy of
/// `Scripts/make-icon.py`: rounded stem plus a leaf bowl, two of them.
struct DoubleFlatMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Both flats laid out in a unit square, then scaled into `rect`.
        let markWidth: CGFloat = 0.78
        let gap: CGFloat = 0.20
        let flatWidth = markWidth / (2 + gap)
        let height: CGFloat = 0.72
        let left = (1 - markWidth) / 2
        let top = (1 - height) / 2

        func flat(at x: CGFloat) -> Path {
            let w = flatWidth * rect.width
            let h = height * rect.height
            let x0 = rect.minX + x * rect.width
            let y0 = rect.minY + top * rect.height
            let stem = w * 0.225
            let r = stem / 2
            let x1 = x0 + stem
            let xr = x0 + w * 0.98
            let tip = y0 + h * 0.38
            let shoulder = y0 + h * 0.66
            let back = y0 + h * 0.90
            let wb = xr - x1

            var p = Path()
            p.move(to: CGPoint(x: x0, y: y0 + r))
            p.addArc(
                center: CGPoint(x: x0 + r, y: y0 + r), radius: r,
                startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false
            )
            p.addLine(to: CGPoint(x: x1, y: tip))
            p.addCurve(
                to: CGPoint(x: xr, y: shoulder),
                control1: CGPoint(x: x1 + wb * 0.50, y: tip - h * 0.008),
                control2: CGPoint(x: xr, y: tip + h * 0.15)
            )
            p.addCurve(
                to: CGPoint(x: x1, y: back),
                control1: CGPoint(x: xr, y: shoulder + h * 0.17),
                control2: CGPoint(x: x1 + wb * 0.35, y: back - h * 0.005)
            )
            p.addLine(to: CGPoint(x: x1, y: y0 + h - r))
            p.addArc(
                center: CGPoint(x: x0 + r, y: y0 + h - r), radius: r,
                startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false
            )
            p.closeSubpath()
            return p
        }

        path.addPath(flat(at: left))
        path.addPath(flat(at: left + flatWidth * (1 + gap)))
        return path
    }
}
