import XCTest
@testable import bbMusic

/// The player bar's hover label appears after a rest, not on contact, and goes away the moment the
/// pointer leaves.
///
/// The delay is the requested behaviour ("hover 到对应的按钮上时延迟 100ms 显示文字"), and it is also
/// the part that is easy to get wrong: a label that shows instantly flickers as the pointer crosses
/// the bar, and one that lingers after the pointer has left ends up describing the wrong button.
@MainActor
final class HoverTipTests: XCTestCase {
    /// Shorter than the real delay so the suite does not sleep for the product's timing; the state
    /// machine does not care what the interval is.
    private let delay = Duration.milliseconds(40)

    func testLabelIsNotShownUntilThePointerHasRested() async {
        let tip = HoverTip()
        tip.setHovering(true, delay: delay)

        XCTAssertTrue(tip.isHovering, "指针在按钮上，底色应当立刻出现")
        XCTAssertTrue(tip.isWaiting)
        XCTAssertFalse(tip.isVisible, "刚进入时不应有文字，否则划过一排按钮会闪成一片")

        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(tip.isVisible, "停留超过延迟后应显示文字")
        XCTAssertFalse(tip.isWaiting)
    }

    func testLeavingHidesTheLabelImmediately() async {
        let tip = HoverTip()
        tip.setHovering(true, delay: delay)
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(tip.isVisible)

        tip.setHovering(false)
        XCTAssertFalse(tip.isVisible, "指针离开后文字应立刻消失，不能继续描述上一个按钮")
        XCTAssertFalse(tip.isHovering)
    }

    /// Crossing a row of buttons: enter, leave before the delay expires, enter the next one. Only the
    /// button the pointer actually settled on may show a label — the abandoned wait must not fire.
    func testAWaiterAbandonedBeforeTheDelayNeverShows() async {
        let tip = HoverTip()
        tip.setHovering(true, delay: delay)
        try? await Task.sleep(for: .milliseconds(10))
        tip.setHovering(false)
        XCTAssertFalse(tip.isVisible)

        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(tip.isVisible, "被取消的那次等待不应补上显示")
    }

    func testRepeatedHoverDoesNotRestartTheWait() async {
        let tip = HoverTip()
        tip.setHovering(true, delay: delay)
        // SwiftUI can deliver `onHover(true)` more than once for one visit; that must not reset the
        // clock, or a label would never appear on a view that re-renders while the pointer rests.
        try? await Task.sleep(for: .milliseconds(20))
        tip.setHovering(true, delay: delay)
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(tip.isVisible, "重复的进入事件不应把计时重新开始")
    }

    /// A control that turns disabled under the pointer (nothing playing any more) drops its label.
    func testHideClearsEveryPieceOfState() async {
        let tip = HoverTip()
        tip.setHovering(true, delay: delay)
        tip.hide()

        XCTAssertFalse(tip.isHovering)
        XCTAssertFalse(tip.isWaiting)
        XCTAssertFalse(tip.isVisible)

        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(tip.isVisible)
    }

    /// The product asked for 100ms specifically; the constant is the one place that number lives.
    func testTheProductDelayIsOneHundredMilliseconds() {
        XCTAssertEqual(HoverTip.delay, .milliseconds(100))
    }
}
