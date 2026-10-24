import SwiftUI
import XCTest
@testable import bbMusic

/// Which state paints a row's background when a row is both the one playing and the one selected.
///
/// The reported symptom was "the queue keeps highlighting the song I first clicked". Both states were
/// true on that row, and the selection happened to be painted last, so the playing row — the one the
/// queue exists to show — was the quiet one. These tests pin the rule down per list.
@MainActor
final class RowHighlightTests: XCTestCase {
    private let accent = Color(hex: 0x2E6B4F)

    // MARK: - The queue: playback leads

    /// The regression. Click row 1 to start playback, let it run to row 4: row 4 is current and row 1
    /// is still selected. The playing row must carry the accent, and the clicked one must not.
    func testQueueHighlightsThePlayingRowNotTheClickedOne() {
        let playing = RowHighlight.resolve(isCurrent: true, isSelected: false, lead: .playback)
        let clicked = RowHighlight.resolve(isCurrent: false, isSelected: true, lead: .playback)

        XCTAssertTrue(playing.leads, "队列里正在播放的行应是最强的那个")
        XCTAssertFalse(clicked.leads, "被点过但没在播的行不应抢走高亮")
        XCTAssertEqual(
            playing.background(accent: accent),
            accent.opacity(0.14),
            "播放行用强调色底"
        )
    }

    /// A row that is both current and selected still gets exactly one background, not two stacked.
    func testQueueRowThatIsBothCurrentAndSelectedLeadsOnce() {
        let highlight = RowHighlight.resolve(isCurrent: true, isSelected: true, lead: .playback)
        XCTAssertTrue(highlight.leads)
        XCTAssertFalse(highlight.tints, "两种状态同时为真时只有一层底色")
    }

    /// When the queue has moved on, the selected row keeps a faint mark so it can still be found.
    func testQueueKeepsAFaintMarkOnTheSelectedRow() {
        let clicked = RowHighlight.resolve(isCurrent: false, isSelected: true, lead: .playback)
        XCTAssertTrue(clicked.tints)
        XCTAssertNotEqual(clicked.background(accent: accent), .clear)
        XCTAssertNotEqual(
            clicked.background(accent: accent),
            accent.opacity(0.14),
            "淡底不能和播放行一样重，否则又分不出哪首在播"
        )
    }

    // MARK: - Every other list: selection leads

    /// Album pages, 每日推荐 and search results are lists you pick from; there the selection is what
    /// the user is acting on, so it keeps the accent. This is the behaviour that already shipped.
    func testOtherListsKeepSelectionAsTheStrongest() {
        let selected = RowHighlight.resolve(isCurrent: false, isSelected: true, lead: .selection)
        let playing = RowHighlight.resolve(isCurrent: true, isSelected: false, lead: .selection)

        XCTAssertTrue(selected.leads)
        XCTAssertFalse(playing.leads)
        XCTAssertTrue(playing.tints, "播放行仍有淡底，只是不抢强调色")
        XCTAssertEqual(selected.background(accent: accent), accent.opacity(0.14))
    }

    func testRowWithNeitherStateIsPlain() {
        for lead in [RowHighlight.Lead.selection, .playback] {
            let plain = RowHighlight.resolve(isCurrent: false, isSelected: false, lead: lead)
            XCTAssertFalse(plain.leads)
            XCTAssertFalse(plain.tints)
            XCTAssertEqual(plain.background(accent: accent), .clear, "普通行不应有底色")
        }
    }
}
