import SwiftUI
import XCTest
@testable import bbMusic

/// Where the shared bubble is drawn, given the control it belongs to and its own width.
///
/// Two real defects live here, both geometric:
///
/// - a bubble anchored to its control was cut off by the scroll view when the control sat near the top
///   of a list (the first row's ⓘ), so the bubble is drawn at the root and clamped into the window;
/// - a hard-coded bubble width pushed the 词 bubble 42pt to the left of its button, because it was made
///   to clear a 120pt plate for a label that is really 35pt wide.
@MainActor
final class HoverTipPlacementTests: XCTestCase {
    private let window = CGSize(width: 1180, height: 760)
    private let narrow: CGFloat = 35      // 歌词
    private let wide: CGFloat = 107       // 播放模式 · 顺序播放
    private let height: CGFloat = 22

    private func place(_ control: CGRect, width: CGFloat) -> HoverTipOverlay.Placement {
        HoverTipOverlay.placement(
            forControlAt: control, bubbleWidth: width, bubbleHeight: height, in: window
        )
    }

    /// A control in the middle of the window: the bubble sits above it, centred, tail straight down.
    func testBubbleSitsAboveTheControlWithNoTailOffset() {
        let control = CGRect(x: 500, y: 400, width: 20, height: 20)
        let placement = place(control, width: narrow)

        XCTAssertEqual(placement.center.x, control.midX, "居中于控件")
        XCTAssertEqual(placement.tailOffset, 0, "不需要让位时尾巴就在正中")
        XCTAssertEqual(
            control.minY - placement.center.y,
            HoverTipOverlay.gap + height / 2,
            "间距固定：贴住控件上沿再留出气泡高度的一半"
        )
    }

    /// The regression. 词 is the rightmost control; a 35pt label must stay centred over it instead of
    /// being pushed inward as though it were 120pt wide.
    func testANarrowBubbleOverTheRightmostControlStaysCentred() {
        // 词's real geometry in the 1180pt window: a 16pt label ending 12pt from the edge.
        let word = CGRect(x: 1180 - 28, y: 30, width: 16, height: 16)
        let placement = place(word, width: narrow)

        XCTAssertEqual(
            placement.center.x, word.midX, accuracy: 0.01,
            "短标签正对按钮，不应被推到左边"
        )
        XCTAssertEqual(placement.tailOffset, 0, accuracy: 0.01)
    }

    /// The rightmost control whose label is long enough to run off the window: the plate slides in, and
    /// the tail keeps pointing at the button rather than following the plate.
    func testAWideBubbleAtTheRightEdgeSlidesInAndKeepsItsTailOnTheControl() {
        let word = CGRect(x: 1180 - 28, y: 30, width: 16, height: 16)
        let placement = place(word, width: wide)

        XCTAssertLessThanOrEqual(
            placement.center.x + wide / 2, window.width + 0.01,
            "整块气泡必须在窗口内"
        )
        XCTAssertLessThan(placement.center.x, word.midX, "气泡向左让位")
        XCTAssertGreaterThan(placement.tailOffset, 0, "尾巴向右偏，仍指向按钮")
        XCTAssertEqual(
            placement.center.x + placement.tailOffset, word.midX, accuracy: 0.01,
            "尾巴必须落在按钮中心上"
        )
    }

    /// The first row's action button sits near the top of the list, where a bubble anchored to it was
    /// clipped. Its centre has to be pushed down into the window instead.
    func testBubbleIsPushedInsideForAControlNearTheTop() {
        let firstRowButton = CGRect(x: 1000, y: 4, width: 20, height: 20)
        let placement = place(firstRowButton, width: narrow)

        XCTAssertGreaterThanOrEqual(
            placement.center.y - height / 2, 0,
            "气泡的顶边不能越过窗口上沿，否则第一行的提示又被裁掉"
        )
    }

    /// A label wider than the window has nowhere to slide to; it simply centres rather than producing
    /// a negative or inverted clamp.
    func testABubbleWiderThanTheWindowCentres() {
        let placement = place(CGRect(x: 600, y: 400, width: 20, height: 20), width: 1400)
        XCTAssertEqual(placement.center.x, window.width / 2)
    }

    /// The presenter shows one bubble at a time, and an older tip hiding must not clear a newer one's.
    func testOnlyTheOwningTipCanClearTheBubble() {
        let presenter = HoverTipPresenter()
        let first = NSObject()
        let second = NSObject()
        let frame = CGRect(x: 10, y: 10, width: 20, height: 20)

        presenter.show(.init(frame: frame, text: "第一", owner: ObjectIdentifier(first)))
        presenter.show(.init(frame: frame, text: "第二", owner: ObjectIdentifier(second)))

        presenter.hide(owner: ObjectIdentifier(first))
        XCTAssertEqual(presenter.anchor?.text, "第二", "先前的控件隐藏不应清掉后来的气泡")

        presenter.hide(owner: ObjectIdentifier(second))
        XCTAssertNil(presenter.anchor)
    }
}
