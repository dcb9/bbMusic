import Foundation

/// A detail page: an album, one of the user's playlists, a playlist found by search, an artist, or
/// a chart.
///
/// The stack these live on is the single answer to both "what is the content area showing" and
/// "what does 返回 go to". Keeping those two in one value is the whole point: while they were
/// separate fields, a detail page could be on screen while the field that said where it came from
/// still held an older page — so 返回 left the user somewhere else, and the collect button acted on
/// the wrong item.
enum Route: Hashable {
    case toplist(Toplist)
    case playlist(Playlist)
    case searchPlaylist(SearchPlaylist)
    case album(Album)
    case artist(Artist)
}

/// A route plus everything that page loaded.
///
/// The payload travels with the route so 返回 is a restore rather than a fresh request: the page
/// below reappears with exactly the tracks it had, even offline, and can never be confused with
/// another page's data.
struct RouteEntry: Equatable {
    /// Identifies this push, so a load that finishes after the user navigated away still lands on
    /// the page that asked for it instead of whatever is on top by then.
    var token: Int
    var route: Route
    var tracks: [Track] = []
    var error: String?
    var albumDetails: AlbumClassicalDetails?
    /// Header facts for a playlist page: description, owner, counts.
    var playlistDetails: PlaylistDetails?
    /// The refreshed artist profile for `.artist`, when the detail endpoint answered.
    var artist: Artist?
    var artistSongs: [Track] = []
    var artistAlbums: [Album] = []
    var toplistTotal = 0
}

/// The navigation stack. Pushing a detail page never changes the sidebar selection, which is what
/// keeps "from 我喜欢 into an artist page" returning to 我喜欢.
struct RouteStack: Equatable {
    private(set) var entries: [RouteEntry] = []
    private var nextToken = 0

    var current: RouteEntry? { entries.last }
    var isEmpty: Bool { entries.isEmpty }
    var canGoBack: Bool { !entries.isEmpty }

    /// Pushes a page and returns the token its load must report back with.
    mutating func push(_ route: Route) -> Int {
        nextToken += 1
        entries.append(RouteEntry(token: nextToken, route: route))
        return nextToken
    }

    /// Removes the top page. A no-op on an empty stack, so a stray 返回 cannot navigate anywhere.
    mutating func pop() {
        guard !entries.isEmpty else { return }
        entries.removeLast()
    }

    /// Drops the whole stack — the user changed destination, which is not a back action.
    mutating func removeAll() {
        entries.removeAll()
    }

    /// Applies a load result to the page that started it, wherever it now sits in the stack. A page
    /// the user has already popped is simply gone, so its late result is discarded.
    mutating func update(token: Int, _ body: (inout RouteEntry) -> Void) {
        guard let index = entries.lastIndex(where: { $0.token == token }) else { return }
        body(&entries[index])
    }
}
