import AppKit
import SwiftUI

/// Tracks whether the pointing-hand cursor is currently pushed, so `push`/`pop` stay balanced.
///
/// `NSCursor.push()`/`pop()` are a stack, and a pop without its push removes whatever was underneath —
/// one unbalanced pair corrupts the cursor for the rest of the app. The hand-written hover handler this
/// replaced had exactly that shape: `if inside, track.artistID != nil { push } else { pop }` pops when
/// the pointer enters a *disabled* link, because the condition fails on the enter as well.
///
/// Kept as a value so the rule is checkable without a pointer: entering a disabled control does nothing,
/// leaving only pops what was actually pushed.
struct PointerCursorState: Equatable {
    private(set) var isPushed = false

    enum Action: Equatable {
        case none
        case push
        case pop
    }

    /// What to do for a pointer event on a control. `isEnabled` false means the control is not a link
    /// right now, so the pointer must keep its normal shape.
    mutating func update(inside: Bool, isEnabled: Bool) -> Action {
        if !isEnabled { return leave() }
        if inside { return enter() }
        return leave()
    }

    /// The control disappeared under the pointer (a row scrolled away, a page changed): the cursor must
    /// not stay a hand because the exit event never arrived.
    mutating func reset() -> Action {
        leave()
    }

    private mutating func enter() -> Action {
        guard !isPushed else { return .none }
        isPushed = true
        return .push
    }

    private mutating func leave() -> Action {
        guard isPushed else { return .none }
        isPushed = false
        return .pop
    }
}

/// Shows a pointing hand over a control that opens something.
///
/// Applied where a click leads somewhere else — the artist and album columns of a track row, the links
/// on the song detail page — so every link in the window answers the pointer the same way, whichever
/// pane it is in.
struct HoverCursor: ViewModifier {
    var cursor: NSCursor = .pointingHand
    var isEnabled: Bool = true
    @State private var state = PointerCursorState()

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                apply(state.update(inside: inside, isEnabled: isEnabled))
            }
            .onChange(of: isEnabled) { _, enabled in
                apply(state.update(inside: false, isEnabled: enabled))
            }
            .onDisappear {
                // A row that scrolls out from under the pointer never sends its exit.
                apply(state.reset())
            }
    }

    private func apply(_ action: PointerCursorState.Action) {
        switch action {
        case .none: break
        case .push: cursor.push()
        case .pop: NSCursor.pop()
        }
    }
}

extension View {
    /// See `HoverCursor`.
    func hoverCursor(_ cursor: NSCursor = .pointingHand, isEnabled: Bool = true) -> some View {
        modifier(HoverCursor(cursor: cursor, isEnabled: isEnabled))
    }
}
