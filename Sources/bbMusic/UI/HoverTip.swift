import SwiftUI

/// A small label that appears only after the pointer has rested on a control for a moment.
///
/// The player bar is a row of glyphs and one-word labels; several of them (`→` for the repeat mode,
/// `词` for the lyrics, `FLAC` for the quality) are not self-explanatory, and the only way to learn
/// what one does was to click it. The system's own tooltip is not usable for this: its delay comes
/// from the user's system settings — a second or more by default, and not settable per control — and
/// it is drawn as a grey system bubble inside a window that has its own palette.
///
/// So the timing lives here, as a state machine that can be tested without a window:
///
/// - the pointer enters → the wash appears, the label does not,
/// - it rests for `delay` → the label appears,
/// - it leaves, or the control becomes disabled → both disappear immediately.
///
/// The wait is cancellable because moving across a row of buttons otherwise leaves a queue of pending
/// labels that pop up one after another over whichever button the pointer has already left.
@MainActor
final class HoverTip: ObservableObject {
    /// How long the pointer has to rest before the label appears. Long enough not to flicker while
    /// the pointer crosses the bar on its way somewhere else, short enough to feel like an answer.
    static let delay: Duration = .milliseconds(100)

    /// The pointer is on the control: the wash is showing.
    @Published private(set) var isHovering = false
    /// The label is showing, i.e. the pointer stayed for `delay`.
    @Published private(set) var isVisible = false
    /// Between the two — the interval the delay covers.
    @Published private(set) var isWaiting = false

    private var pending: Task<Void, Never>?

    /// Reports the pointer's presence. Repeating the same value does nothing, so a view reporting
    /// `true` again while the pointer is already inside does not restart the wait.
    func setHovering(_ hovering: Bool, delay: Duration? = nil) {
        let delay = delay ?? Self.delay
        guard hovering != isHovering else { return }
        isHovering = hovering
        guard hovering else {
            hide()
            return
        }
        isWaiting = true
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.isWaiting = false
            self.isVisible = true
        }
    }

    /// Hides the label and abandons any pending wait. Called on pointer exit, on press, and when the
    /// control turns disabled under the pointer.
    func hide() {
        pending?.cancel()
        pending = nil
        isHovering = false
        isWaiting = false
        isVisible = false
    }

    deinit { pending?.cancel() }
}
