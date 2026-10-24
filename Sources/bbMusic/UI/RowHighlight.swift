import SwiftUI

/// Which of a row's two states paints the accent when both are true.
///
/// A row can be the one playing *and* the one the user last clicked, and both want a background. So
/// exactly one has to win, and which one wins depends on what the list is for:
///
/// - A queue is read to answer "what is playing, and what comes next". The playing row has to be the
///   loudest thing in it, even while the row that started playback is still the selected one.
/// - Every other list is read to pick something. There the selection is what the user is acting on,
///   and playback only leaves a faint mark on its row.
///
/// Keeping the rule as a value rather than inside the row is what makes it assertable without
/// rendering — the bug this replaced was a priority written into a background computed property,
/// where nothing could check it and the selected row silently covered the playing one.
struct RowHighlight: Equatable {
    /// The row the list is about: the accent wash, the strongest background a row has.
    var leads = false
    /// The other state, when it is also true: a faint neutral tint, enough to find the row again.
    var tints = false

    enum Lead {
        /// A list you pick from: the selected row leads.
        case selection
        /// The play queue: the playing row leads.
        case playback
    }

    static func resolve(isCurrent: Bool, isSelected: Bool, lead: Lead) -> RowHighlight {
        let leader = lead == .playback ? isCurrent : isSelected
        let follower = lead == .playback ? isSelected : isCurrent
        return RowHighlight(leads: leader, tints: follower && !leader)
    }

    func background(accent: Color) -> Color {
        if leads { return accent.opacity(0.14) }
        if tints { return Color.primary.opacity(0.06) }
        return .clear
    }
}
