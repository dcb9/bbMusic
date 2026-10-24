import SwiftUI

/// The hover feedback shared by every control in the window: a faint wash while the pointer is on it,
/// and — after `HoverTip.delay` — the control's name in a bubble above it.
///
/// One modifier rather than a hand-rolled `onHover` on each control, because a window where some
/// buttons light up and others do not reads as "the others are not clickable", and because the bubble
/// has to be drawn in exactly one place (`HoverTipOverlay`) for the reason recorded there.
///
/// The wash is drawn behind the label and changes no layout: the pointer moving along a row must not
/// shift a single control.
///
/// `tint` is the control's resting colour, so a toggle that is already on (an accent-coloured repeat
/// button) does not lose that state while the pointer is on it. `isEnabled` is passed in rather than
/// read from the environment so a disabled control neither lights up nor explains itself.
struct HoverFeedback: ViewModifier {
    let text: String
    var tint: Color? = nil
    var shape: Shape = .rounded
    var isEnabled: Bool = true
    @EnvironmentObject private var presenter: HoverTipPresenter

    enum Shape {
        /// A 6pt rounded rectangle around a glyph or a short word.
        case rounded
        /// A halo around the filled play/pause disc, which a wash behind it would hide.
        case circle
    }

    @StateObject private var tip = HoverTip()
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isLit ? palette.accent : (tint ?? palette.accent))
            .background {
                wash
                    .padding(.horizontal, shape == .circle ? 3 : 4)
                    .padding(.vertical, 3)
                    .opacity(isLit ? 1 : 0)
            }
            // The control's own frame, reported upward so the root can draw the bubble there. Measured
            // only while the label is due, so a resting pointer over a list costs nothing.
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: HoverTipFrameKey.self,
                        value: tip.isVisible ? proxy.frame(in: .global) : .zero
                    )
                }
            )
            .onHover { inside in
                if inside && isEnabled {
                    tip.setHovering(true)
                } else {
                    tip.hide()
                }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { tip.hide() }
            }
            // A frame arrives only while the label is due; losing it is how the bubble goes away.
            .onPreferenceChange(HoverTipFrameKey.self) { frame in
                if tip.isVisible, frame != .zero {
                    presenter.show(.init(frame: frame, text: text, owner: ObjectIdentifier(tip)))
                } else {
                    presenter.hide(owner: ObjectIdentifier(tip))
                }
            }
            .onChange(of: tip.isVisible) { _, visible in
                // Hiding must not wait for the next frame report: the pointer may already be on
                // another control, whose bubble would otherwise be cleared by this one a tick later.
                if !visible { presenter.hide(owner: ObjectIdentifier(tip)) }
            }
            .onDisappear {
                // A control that leaves the screen never reports its exit. Opening the song detail page
                // from a row's ⓘ removed that row, so the bubble stayed on the new page — pointing at
                // a button that was no longer there.
                tip.hide()
                presenter.hide(owner: ObjectIdentifier(tip))
            }
            .animation(.easeOut(duration: 0.08), value: tip.isHovering)
            .accessibilityLabel(text)
    }

    private var isLit: Bool { tip.isHovering && isEnabled }

    /// Nothing until the pointer is on the control; a faint accent wash once it is.
    @ViewBuilder
    private var wash: some View {
        switch shape {
        case .circle: Circle().fill(palette.accent.opacity(0.16))
        case .rounded: RoundedRectangle(cornerRadius: 6).fill(palette.accent.opacity(0.12))
        }
    }
}

extension View {
    /// See `HoverFeedback`.
    func hoverFeedback(
        _ text: String,
        tint: Color? = nil,
        shape: HoverFeedback.Shape = .rounded,
        isEnabled: Bool = true
    ) -> some View {
        modifier(HoverFeedback(text: text, tint: tint, shape: shape, isEnabled: isEnabled))
    }
}
