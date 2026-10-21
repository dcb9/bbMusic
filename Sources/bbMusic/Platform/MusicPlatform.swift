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
    /// Library reads. Each returns an empty list when the platform has nothing to show rather than
    /// failing, so the UI can render an honest empty state.
    func likedSongs() async throws -> [Track]
    func playlists() async throws -> [Playlist]
    func tracks(in playlist: Playlist) async throws -> [Track]
    func albums() async throws -> [Album]
    func streamSource(for track: Track, quality: AudioQuality) async throws -> StreamSource
    func lyrics(for track: Track) async throws -> Lyrics
}

enum AudioQuality: String, Codable, CaseIterable, Sendable {
    case best, flac, mp3_320, mp3_128
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
