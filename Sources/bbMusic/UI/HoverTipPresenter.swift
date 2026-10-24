import SwiftUI

/// Where a tooltip's bubble belongs, published to the one place that draws it.
///
/// A bubble has to be drawn *outside* the scroll view its control lives in. Anchoring it to the control
/// puts it inside the clip: the first row of a list has no room above it, so its bubble was cut off —
/// resting the pointer on ⓘ showed only three little points at the top edge of the list. Drawing every
/// bubble once, at the root, over the whole window, means no clip can touch it and a bubble is free to
/// overhang its row, its list, or the player bar.
@MainActor
final class HoverTipPresenter: ObservableObject {
    struct Anchor: Equatable {
        /// The control's frame, in SwiftUI's global (window) coordinates.
        var frame: CGRect
        /// The label to draw.
        var text: String
        /// Which tip owns the bubble — a tip that has since hidden must not clear a newer one's.
        var owner: ObjectIdentifier
    }

    @Published private(set) var anchor: Anchor?

    func show(_ anchor: Anchor) {
        self.anchor = anchor
    }

    /// Clears the bubble, but only if the tip asking is the one currently showing.
    func hide(owner: ObjectIdentifier) {
        guard anchor?.owner == owner else { return }
        anchor = nil
    }
}

/// Carries a control's frame in the window's coordinate space up to the root, where the bubble is drawn.
///
/// A `PreferenceKey` because the reading has to happen where the control is while the drawing happens
/// somewhere else entirely — and because both frames are then in `.global`, so placing the bubble needs
/// no knowledge of whether the hosting view is flipped.
struct HoverTipFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// Draws the one bubble the whole window shares, over everything else.
struct HoverTipOverlay: View {
    @ObservedObject var presenter: HoverTipPresenter

    var body: some View {
        GeometryReader { proxy in
            if let anchor = presenter.anchor {
                let origin = proxy.frame(in: .global).origin
                let placement = Self.placement(
                    forControlAt: anchor.frame.offsetBy(dx: -origin.x, dy: -origin.y),
                    bubbleWidth: HoverTipBubble.width(of: anchor.text),
                    bubbleHeight: HoverTipBubble.height,
                    in: proxy.size
                )
                HoverTipBubble(text: anchor.text, tailOffset: placement.tailOffset)
                    .position(x: placement.center.x, y: placement.center.y)
            }
        }
        .allowsHitTesting(false)
    }

    /// The gap the bubble keeps above the control.
    static let gap: CGFloat = 5

    /// Where to put the bubble and where to put its tail on it.
    struct Placement: Equatable {
        /// The bubble's centre, in the overlay's own coordinates.
        var center: CGPoint
        /// How far the tail sits from the bubble's own centre, in points. Zero when the bubble is
        /// directly above the control; negative/positive when it had to shift to stay in the window.
        var tailOffset: CGFloat
    }

    /// Places a bubble of `bubbleWidth` above a control, keeping the whole plate inside the window while
    /// its tail keeps pointing at the control.
    ///
    /// The tail is what makes the label belong to its button: shifting the plate inward at the window's
    /// right edge is fine, but a bubble whose tail no longer points at anything reads as belonging to
    /// its neighbour. So the plate slides, the tail stays over the control, and the tail is clamped to
    /// the plate's own rounded corners.
    ///
    /// Kept as a function because both failure modes are geometric and testable without rendering: a
    /// control at the right edge would push the label off screen, and a control near the top (the first
    /// row of a list) has no room above it.
    static func placement(
        forControlAt control: CGRect,
        bubbleWidth: CGFloat,
        bubbleHeight: CGFloat,
        in size: CGSize
    ) -> Placement {
        let halfWidth = bubbleWidth / 2
        let wanted = control.midX
        // Keep the whole plate inside the window: it may slide, but not off the edge.
        let centerX = halfWidth >= size.width / 2
            ? size.width / 2
            : max(halfWidth, min(wanted, size.width - halfWidth))
        // Its top edge must not leave the window either — that is what clipped the first row's bubble.
        let bottom = control.minY - gap
        let centerY = max(bubbleHeight / 2, bottom - bubbleHeight / 2)
        // The tail follows the control, but stays on the plate.
        let tail = max(-halfWidth + 8, min(wanted - centerX, halfWidth - 8))
        return Placement(center: CGPoint(x: centerX, y: centerY), tailOffset: tail)
    }
}
