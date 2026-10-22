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
}

/// A saved album.
struct Album: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let artist: String
    let trackCount: Int
    var artworkURL: URL?
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
    func search(_ query: String, kind: SearchKind) async throws -> SearchResults
    /// Tracks of a playlist found by search (it may belong to another user).
    func tracks(inSearchPlaylist playlist: SearchPlaylist) async throws -> [Track]
    /// An artist's songs.
    func songs(by artist: Artist) async throws -> [Track]
    /// Library reads. Each returns an empty list when the platform has nothing to show rather than
    /// failing, so the UI can render an honest empty state.
    func likedSongs() async throws -> [Track]
    func playlists() async throws -> [Playlist]
    func tracks(in playlist: Playlist) async throws -> [Track]
    func albums() async throws -> [Album]
    /// Album contents. Separate from `tracks(in:)` because an album carries its own classical
    /// credits, which a playlist does not.
    func albumTracks(_ album: Album) async throws -> (tracks: [Track], details: AlbumClassicalDetails?)
    /// Qualities that actually exist for this track, best first. Empty when the platform cannot say.
    func availableQualities(for track: Track) async throws -> [AvailableQuality]
    func streamSource(for track: Track, quality: AudioQuality) async throws -> StreamSource
    func lyrics(for track: Track) async throws -> Lyrics
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
}

/// One page of typed search results.
struct SearchResults: Sendable {
    var songs: [Track] = []
    var albums: [Album] = []
    var playlists: [SearchPlaylist] = []
    var artists: [Artist] = []
    var kind: SearchKind = .song

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
