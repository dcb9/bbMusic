import Foundation
@testable import bbMusic

/// A stand-in platform: every call answers from a fixture and records what was asked for.
///
/// The app's navigation and queue rules are pure state machines over these answers, so testing them
/// needs no sidecar, no account and no network.
final class StubPlatform: MusicPlatform, @unchecked Sendable {
    let id = "stub"
    let displayName = "Stub"

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    var connected = true

    // Fixtures.
    var sectionTracks: [Track] = []
    var playlistTracks: [String: [Track]] = [:]
    var albumTracks: [String: [Track]] = [:]
    /// Album metadata the endpoint reports, keyed by album id.
    var albumMetadata: [String: (name: String, artist: String, year: Int?)] = [:]
    var failingAlbums: Set<String> = []
    var artistSongs: [Track] = []
    var artistAlbums: [Album] = []
    /// Totals the listing endpoints report, which can exceed what one page holds.
    var artistSongTotal: Int?
    var artistAlbumTotal: Int?
    var detail = TrackDetail()
    var toplistPages: [Int: (tracks: [Track], total: Int)] = [:]

    // Recorded calls.
    private(set) var albumRequests: [String] = []

    func connectionState() async -> PlatformConnectionState {
        connected ? .connected(displayName: "Stub") : .disconnected
    }

    func signIn() async throws -> PlatformConnectionState { await connectionState() }
    func signOut() async throws {}

    func search(_ query: String) async throws -> [Track] { [] }
    var artistSearchResults: [Artist] = []
    var searchAlbums: [Album] = []
    var searchPlaylists: [SearchPlaylist] = []
    private(set) var searches: [(query: String, kind: SearchKind)] = []

    func search(_ query: String, kind: SearchKind, page: Int) async throws -> SearchResults {
        searches.append((query, kind))
        var results = SearchResults(kind: kind)
        switch kind {
        case .singer:
            results.artists = artistSearchResults
            results.totalAvailable = artistSearchResults.count
        case .album:
            results.albums = searchAlbums
            results.totalAvailable = searchAlbums.count
        case .playlist:
            results.playlists = searchPlaylists
            results.totalAvailable = searchPlaylists.count
        case .song:
            break
        }
        return results
    }

    func tracks(inSearchPlaylist playlist: SearchPlaylist) async throws -> [Track] {
        playlistTracks[playlist.id] ?? []
    }

    func songs(by artist: Artist) async throws -> ArtistSongs {
        ArtistSongs(tracks: artistSongs, total: artistSongTotal ?? artistSongs.count)
    }
    /// Mirrors the real endpoint: it supplies a biography and artwork but **no counts**, which is
    /// exactly why an artist page cannot read them from here.
    func artistDetail(_ artist: Artist) async throws -> Artist {
        Artist(
            id: artist.id, name: artist.name,
            songCount: artist.songCount, albumCount: artist.albumCount,
            artworkURL: artist.artworkURL, bio: "简介"
        )
    }
    func albums(by artist: Artist) async throws -> ArtistAlbums {
        ArtistAlbums(albums: artistAlbums, total: artistAlbumTotal ?? artistAlbums.count)
    }
    func dailySongs() async throws -> [Track] { sectionTracks }

    var charts: [Toplist] = []
    func toplists() async throws -> [Toplist] { charts }

    func toplistTracks(_ toplist: Toplist, offset: Int) async throws -> (tracks: [Track], total: Int) {
        toplistPages[offset] ?? ([], 0)
    }

    // Writes are recorded so a test can assert not just the resulting state but that a no-op really
    // sent nothing.
    private(set) var likedWrites: [(id: String, liked: Bool)] = []
    private(set) var albumWrites: [(id: String, subscribed: Bool)] = []
    private(set) var playlistWrites: [(id: String, subscribed: Bool)] = []

    func setLiked(_ liked: Bool, track: Track) async throws {
        likedWrites.append((track.id, liked))
    }
    func setSubscribed(_ subscribed: Bool, album: Album) async throws {
        albumWrites.append((album.id, subscribed))
    }
    func setSubscribed(_ subscribed: Bool, playlist: SearchPlaylist) async throws {
        playlistWrites.append((playlist.id, subscribed))
    }

    func likedSongs() async throws -> [Track] { sectionTracks }
    var savedPlaylists: [Playlist] = []
    func playlists() async throws -> [Playlist] { savedPlaylists }
    func tracks(in playlist: Playlist) async throws -> [Track] {
        playlistTracks[playlist.id] ?? []
    }
    var savedAlbums: [Album] = []
    func albums() async throws -> [Album] { savedAlbums }

    func albumTracks(_ album: Album) async throws -> AlbumContents {
        albumRequests.append(album.id)
        if failingAlbums.contains(album.id) {
            throw Failure(message: "专辑取不到")
        }
        let tracks = albumTracks[album.id] ?? []
        let meta = albumMetadata[album.id]
        return AlbumContents(
            tracks: tracks,
            details: nil,
            name: meta?.name,
            artist: meta?.artist,
            year: meta?.year
        )
    }

    func availableQualities(for track: Track) async throws -> [AvailableQuality] { [] }
    func streamSource(for track: Track, quality: AudioQuality) async throws -> StreamSource {
        .url(URL(string: "https://example.invalid/\(track.id).mp3")!)
    }
    func lyrics(for track: Track) async throws -> Lyrics { .empty }
    func trackDetail(for track: Track) async throws -> TrackDetail { detail }

    var knownTracks: [String: Track] = [:]
    func track(withID id: String) async throws -> Track {
        guard let track = knownTracks[id] else { throw Failure(message: "找不到曲目 \(id)") }
        return track
    }
}

/// Convenience builders so a test reads as the scenario, not as a struct literal.
enum Fixture {
    static func track(
        _ id: String,
        albumID: String? = nil,
        artistID: String? = nil,
        title: String? = nil,
        album: String = "专辑"
    ) -> Track {
        Track(
            id: id,
            title: title ?? "曲目 \(id)",
            artist: "歌手",
            album: album,
            duration: 200,
            artworkURL: nil,
            isPlayable: true,
            artistID: artistID,
            albumID: albumID
        )
    }

    static func album(_ id: String, name: String = "专辑") -> Album {
        Album(id: id, name: name, artist: "歌手", trackCount: 10, artworkURL: nil, year: 2000)
    }

    static func playlist(_ id: String, name: String = "歌单") -> Playlist {
        Playlist(id: id, name: name, trackCount: 10)
    }

    static func searchPlaylist(_ id: String, name: String = "别人的歌单") -> SearchPlaylist {
        SearchPlaylist(id: id, name: name, creator: "某人", trackCount: 10, artworkURL: nil, listenCount: 0)
    }

    static func artist(_ id: String, name: String = "歌手") -> Artist {
        Artist(id: id, name: name, songCount: 5, albumCount: 2, artworkURL: nil)
    }

    static func toplist(_ id: String, title: String = "榜单", count: Int = 100) -> Toplist {
        Toplist(id: id, title: title, intro: "", trackCount: count, updateTime: nil, artworkURL: nil, group: "地区榜")
    }
}
