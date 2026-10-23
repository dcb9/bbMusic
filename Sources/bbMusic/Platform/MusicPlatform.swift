import Foundation

/// A playable song, normalised across platforms.
///
/// `id` is the platform's own identifier (QQ Music's `songmid`); nothing outside the platform
/// adapter may interpret it.
struct Track: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String
    let album: String
    /// Seconds. `0` when the platform did not report one.
    let duration: TimeInterval
    let artworkURL: URL?
    /// Whether the platform considers this track available to the current account.
    let isPlayable: Bool
    /// Structured classical credit, when the platform provides one (QQ Music does for albums).
    /// Preferred over the title/artist heuristics in `TrackDisplay` when present.
    var composer: String?
    var work: String?
    /// Disc label ("Disc 1") for multi-disc albums.
    var disc: String?
    /// Artist and album identifiers, so a row can link through to their pages.
    var artistID: String?
    var albumID: String?
    /// Publication year from the search result, when the API reports one.
    var year: Int?
    /// Composer parsed from the result's description ("作曲: …"). Only classical results carry it.
    var composerCredit: String?

    var durationText: String {
        guard duration > 0 else { return "--:--" }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A playlist as shown in the sidebar.
struct Playlist: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let trackCount: Int
    /// QQ Music distinguishes "我喜欢的音乐" from ordinary self-built playlists.
    var isLikedSongs: Bool = false
    /// True when this is someone else's playlist the user has collected. Collected entries come
    /// back with different (lowercase) keys and are not editable.
    var isCollected: Bool = false
    /// Cover artwork. May be absent; the UI then derives one from the first track that has any.
    var artworkURL: URL?
}

/// A saved album.
struct Album: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let artist: String
    let trackCount: Int
    var artworkURL: URL?
    /// Publication year, when the API reports one.
    var year: Int?
}

/// Parsed lyrics: timed lines, each optionally carrying a translation.
struct Lyrics: Codable, Hashable, Sendable {
    struct Line: Codable, Hashable, Sendable {
        let time: TimeInterval
        let text: String
        var translation: String?
    }

    let lines: [Line]

    static let empty = Lyrics(lines: [])
    var isEmpty: Bool { lines.isEmpty }
}

/// How a platform can hand audio to the player.
enum StreamSource: Sendable {
    /// A direct media URL the system player can open itself.
    case url(URL)
    /// The platform refuses a full stream but offered a short preview (QQ Music does this
    /// anonymously). Surfaced so the UI can say so instead of silently playing 30 seconds.
    case preview(URL)
}

/// A failure worth showing the user verbatim.
struct PlatformError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Everything the app needs from a music service. One adapter per platform; the rest of the app
/// never learns which platform a track came from.
protocol MusicPlatform: AnyObject, Sendable {
    var id: String { get }
    var displayName: String { get }

    /// Whether the app has a usable session for this platform.
    func connectionState() async -> PlatformConnectionState
    /// Called when the platform needs the user to sign in before anything else works.
    func signIn() async throws -> PlatformConnectionState
    func signOut() async throws

    func search(_ query: String) async throws -> [Track]
    /// Typed search: the same query can mean songs, albums, playlists or artists.
    /// `page` is 1-based. The caller pages until `nextPage` is nil.
    func search(_ query: String, kind: SearchKind, page: Int) async throws -> SearchResults
    /// Tracks of a playlist found by search (it may belong to another user).
    func tracks(inSearchPlaylist playlist: SearchPlaylist) async throws -> [Track]
    /// An artist's songs, with the artist's total song count when the platform reports one.
    ///
    /// The count travels with the listing because the profile endpoint does not carry it: QQ Music's
    /// `/singer/detail` has a name, a picture and a biography and nothing else, so an artist page that
    /// read counts from there showed 0.
    func songs(by artist: Artist) async throws -> ArtistSongs
    /// Full artist profile (name, biography).
    func artistDetail(_ artist: Artist) async throws -> Artist
    /// An artist's albums, with the artist's total album count when the platform reports one.
    func albums(by artist: Artist) async throws -> ArtistAlbums
    /// The account's daily recommendation (30 tracks).
    func dailySongs() async throws -> [Track]
    /// All charts, grouped.
    func toplists() async throws -> [Toplist]
    /// One page of a chart's tracks. `offset` is a track index, not a page number.
    func toplistTracks(_ toplist: Toplist, offset: Int) async throws -> (tracks: [Track], total: Int)

    // MARK: - Writes
    //
    // These change the user's account. Every implementation must read the current state first and
    // treat "already in the desired state" as success, so a retry cannot flip a value back.
    func setLiked(_ liked: Bool, track: Track) async throws
    func setSubscribed(_ subscribed: Bool, album: Album) async throws
    func setSubscribed(_ subscribed: Bool, playlist: SearchPlaylist) async throws
    /// Library reads. Each returns an empty list when the platform has nothing to show rather than
    /// failing, so the UI can render an honest empty state.
    func likedSongs() async throws -> [Track]
    func playlists() async throws -> [Playlist]
    func tracks(in playlist: Playlist) async throws -> [Track]
    func albums() async throws -> [Album]
    /// Album contents. Separate from `tracks(in:)` because an album carries its own classical
    /// credits, which a playlist does not.
    func albumTracks(_ album: Album) async throws -> AlbumContents
    /// Qualities that actually exist for this track, best first. Empty when the platform cannot say.
    func availableQualities(for track: Track) async throws -> [AvailableQuality]
    func streamSource(for track: Track, quality: AudioQuality) async throws -> StreamSource
    func lyrics(for track: Track) async throws -> Lyrics
    /// Company, release date, genre, language and blurb for the detail page.
    func trackDetail(for track: Track) async throws -> TrackDetail
    /// One track's metadata by id, for callers holding a bare id (a model that saved it last week).
    func track(withID id: String) async throws -> Track
}

/// A stream quality the QQ Music API understands.
///
/// `best` is not a real format: the API resolves it to the highest quality the account can fetch.
enum AudioQuality: String, Codable, CaseIterable, Sendable {
    case best
    case flac
    case mp3_320
    case mp3_128
    case aac
    case ape

    /// The value the API expects in `?quality=`.
    var apiValue: String {
        switch self {
        case .best: return "best"
        case .flac: return "flac"
        case .mp3_320: return "320"
        case .mp3_128: return "128"
        case .aac: return "m4a"
        case .ape: return "ape"
        }
    }

    var label: String {
        switch self {
        case .best: return "自动（最高可用）"
        case .flac: return "无损 FLAC"
        case .mp3_320: return "320K MP3"
        case .mp3_128: return "128K MP3"
        case .aac: return "AAC"
        case .ape: return "无损 APE"
        }
    }

    /// Short label for the player bar.
    var shortLabel: String {
        switch self {
        case .best: return "自动"
        case .flac: return "FLAC"
        case .mp3_320: return "320K"
        case .mp3_128: return "128K"
        case .aac: return "AAC"
        case .ape: return "APE"
        }
    }

    var isLossless: Bool {
        self == .flac || self == .ape
    }

    /// Ordering used to pick the best available option.
    var rank: Int {
        switch self {
        case .ape: return 6
        case .flac: return 5
        case .mp3_320: return 4
        case .aac: return 3
        case .mp3_128: return 2
        case .best: return 1
        }
    }
}

/// A quality that actually exists for a given track, with the file size the API reported.
struct AvailableQuality: Identifiable, Hashable, Sendable {
    let quality: AudioQuality
    let byteSize: Int

    var id: String { quality.rawValue }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }
}

enum PlatformConnectionState: Equatable, Sendable {
    case unknown
    case disconnected
    case connecting
    case connected(displayName: String)
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .unknown: return "检查中"
        case .disconnected: return "未登录"
        case .connecting: return "登录中"
        case .connected(let name): return name
        case .failed: return "连接失败"
        }
    }
}

/// Album contents: the tracks, the classical credits that come with them, and the album's own
/// description. A caller holding only an id and a name (a row's album label) gets the rest here
/// instead of guessing it.
struct AlbumContents: Sendable {
    var tracks: [Track]
    var details: AlbumClassicalDetails?
    var name: String?
    var artist: String?
    var year: Int?
}

/// Classical credits that come with an album rather than with each track.
struct AlbumClassicalDetails: Sendable, Equatable {
    var composer: String?
    var work: String?
    var discCount: Int
}

/// What kind of thing a search is looking for. QQ Music serves each type from the same endpoint
/// with a different `type` parameter and a different item shape.
enum SearchKind: String, CaseIterable, Identifiable, Sendable {
    case song, album, playlist, singer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .song: return "歌曲"
        case .album: return "专辑"
        case .playlist: return "歌单"
        case .singer: return "歌手"
        }
    }
}

/// A playlist found by search. Distinct from `Playlist`, which is one of *your* playlists and can be
/// opened for its tracks; a search result may belong to anyone.
struct SearchPlaylist: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let creator: String
    let trackCount: Int
    let artworkURL: URL?
    let listenCount: Int
}

/// An artist found by search.
struct Artist: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let songCount: Int
    let albumCount: Int
    let artworkURL: URL?
    /// Biography, when the artist detail endpoint supplies one.
    var bio: String?
}

/// An artist's songs plus the total the platform says the artist has.
struct ArtistSongs: Sendable {
    var tracks: [Track]
    /// Total songs on the artist, which can exceed `tracks.count` — the listing is one page.
    var total: Int?
}

/// An artist's albums plus the total the platform says the artist has.
struct ArtistAlbums: Sendable {
    var albums: [Album]
    var total: Int?
}

/// Extra facts about one song, for the detail page. Every field is optional: the platform answers
/// what it has, and the page shows the rows it got rather than placeholders.
struct TrackDetail: Sendable, Equatable {
    var company: String?
    var releaseDate: String?
    var genre: String?
    var language: String?
    var intro: String?
}

/// One chart, as listed by the charts index.
struct Toplist: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let intro: String
    let trackCount: Int
    let updateTime: String?
    let artworkURL: URL?
    /// Chart groups ("地区榜", "特色榜", "全球榜").
    let group: String
}

/// Whether a track is in the account's 我喜欢.
enum LikeState: Equatable, Sendable {
    case liked
    case notLiked
    case unknown

    var isLiked: Bool { self == .liked }
}

/// Whether an album or playlist is collected.
enum SubscribeState: Equatable, Sendable {
    case subscribed
    case notSubscribed
    case unknown

    var isSubscribed: Bool { self == .subscribed }
}

/// One page of typed search results.
struct SearchResults: Sendable {
    var songs: [Track] = []
    var albums: [Album] = []
    var playlists: [SearchPlaylist] = []
    var artists: [Artist] = []
    var kind: SearchKind = .song
    /// Total matches the upstream reports, which can exceed what has been fetched.
    var totalAvailable: Int = 0
    /// Next page to request, or nil when everything has been fetched.
    var nextPage: Int?

    var isEmpty: Bool {
        songs.isEmpty && albums.isEmpty && playlists.isEmpty && artists.isEmpty
    }

    var count: Int {
        switch kind {
        case .song: return songs.count
        case .album: return albums.count
        case .playlist: return playlists.count
        case .singer: return artists.count
        }
    }
}
