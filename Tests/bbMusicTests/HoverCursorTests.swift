import AppKit
import XCTest
@testable import bbMusic

/// When the pointing hand shows, and that it never gets stuck.
///
/// `NSCursor.push()`/`pop()` is a stack. A pop without its push removes whatever cursor was underneath
/// it, so one unbalanced pair leaves the whole app with the wrong pointer. The hover handler this
/// replaced had exactly that bug — it popped when the pointer entered a disabled link, because the
/// enable check failed on the enter as well as on the leave.
@MainActor
final class HoverCursorTests: XCTestCase {
    /// The album and artist columns of a track row both open a page, so both show the hand.
    func testAnEnabledLinkShowsTheHandWhileThePointerIsOnIt() {
        var state = PointerCursorState()

        XCTAssertEqual(state.update(inside: true, isEnabled: true), .push, "进入可点链接时变小手")
        XCTAssertTrue(state.isPushed)
        XCTAssertEqual(state.update(inside: false, isEnabled: true), .pop, "离开时恢复")
        XCTAssertFalse(state.isPushed)
    }

    /// The regression: entering a link that carries no id must not pop. A row whose album has no id is
    /// plain text, and the pointer has to keep its normal shape without touching the cursor stack.
    func testEnteringADisabledLinkDoesNotPop() {
        var state = PointerCursorState()

        XCTAssertEqual(state.update(inside: true, isEnabled: false), .none, "禁用时不应 push")
        XCTAssertEqual(state.update(inside: false, isEnabled: false), .none, "更不应 pop")
        XCTAssertFalse(state.isPushed)
    }

    /// A link can become disabled while the pointer rests on it (the row reloaded, the id went away).
    /// The hand it pushed has to be taken back.
    func testTurningDisabledUnderThePointerReleasesTheHand() {
        var state = PointerCursorState()
        _ = state.update(inside: true, isEnabled: true)

        XCTAssertEqual(state.update(inside: true, isEnabled: false), .pop)
        XCTAssertFalse(state.isPushed)
    }

    /// Repeating an enter must not push twice: the cursor stack would then need two pops to unwind.
    func testRepeatedEnterPushesOnlyOnce() {
        var state = PointerCursorState()

        XCTAssertEqual(state.update(inside: true, isEnabled: true), .push)
        XCTAssertEqual(state.update(inside: true, isEnabled: true), .none)
    }

    /// A row that scrolls out from under the pointer never sends its exit event, so leaving the view
    /// has to release the hand itself.
    func testDisappearingWhileHoveredReleasesTheHand() {
        var state = PointerCursorState()
        _ = state.update(inside: true, isEnabled: true)

        XCTAssertEqual(state.reset(), .pop)
        XCTAssertFalse(state.isPushed)
        XCTAssertEqual(state.reset(), .none, "没有 push 时 reset 也不应 pop")
    }
}
