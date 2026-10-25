import AppKit
import XCTest
@testable import bbMusic

/// A row selects on the first click and plays on the second, with no waiting in between.
///
/// This is the part that is easy to get wrong: the obvious way to add a double-click is a SwiftUI
/// `onTapGesture(count: 2)`, which forces the single click to wait out `NSEvent.doubleClickInterval`
/// (0.5 s) — the exact regression `--click-probe` exists to catch. Driving `mouseDown` off the event's
/// own `clickCount` keeps both actions immediate.
@MainActor
final class RowDoubleClickTests: XCTestCase {
    private func click(_ view: RowClickCatcher.ClickView, count: Int) {
        var selections = 0
        var plays = 0
        view.onClick = { selections += 1 }
        view.onDoubleClick = { plays += 1 }

        view.mouseDown(with: press(clickCount: count))

        // Asserted through the counters rather than by inspecting state, so a test failure names which
        // handler ran.
        XCTAssertEqual(selections, count >= 2 ? 0 : 1, "第 \(count) 次按下应\(count >= 2 ? "不" : "")触发选中")
        XCTAssertEqual(plays, count >= 2 ? 1 : 0, "第 \(count) 次按下应\(count >= 2 ? "" : "不")触发播放")
    }

    private func press(clickCount: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
        )!
    }

    /// The first press selects. No timer, no gesture recogniser, nothing to wait for.
    func testFirstClickSelects() {
        click(RowClickCatcher.ClickView(frame: .zero), count: 1)
    }

    /// The second press plays.
    func testSecondClickPlays() {
        click(RowClickCatcher.ClickView(frame: .zero), count: 2)
    }

    /// A triple-click still plays rather than falling back to selecting: the window server reports 3,
    /// and anything past the second press is part of the same gesture.
    func testThirdPressStillPlays() {
        click(RowClickCatcher.ClickView(frame: .zero), count: 3)
    }

    /// A catcher with no double-click handler — used where a row has nothing to play — must not crash
    /// or swallow the second click's selection.
    func testWithoutADoubleClickHandlerTheSecondClickStillSelects() {
        let view = RowClickCatcher.ClickView(frame: .zero)
        var selections = 0
        view.onClick = { selections += 1 }
        view.onDoubleClick = nil

        view.mouseDown(with: press(clickCount: 2))

        XCTAssertEqual(selections, 1, "没有双击动作时，第二次按下仍按选中处理")
    }

    /// The delay that must not come back. If this ever changes, the whole "double-click is free"
    /// argument has to be re-measured rather than assumed.
    func testTheGestureWindowWeAvoidIsStillHalfASecond() {
        XCTAssertEqual(NSEvent.doubleClickInterval, 0.5, accuracy: 0.001)
    }
}
