import Foundation

/// The queue as it was when the app closed, so a restart does not start from nothing.
///
/// Deliberately *not* a resume: the file records what was queued and where the user was, and the app
/// restores that state paused. Music that starts on its own when a window opens is startling, and it
/// is not what "reopen the app" means — the user asked for the queue back, not for playback.
struct QueueSnapshot: Codable, Equatable {
    var tracks: [Track]
    /// Index of the track that was playing, so the list opens on the same row.
    var currentIndex: Int?
    /// Position within that track, kept so pressing play continues where it left off.
    var currentTime: TimeInterval
    /// Saved so the restored queue looks the way it did.
    var repeatMode: String
    var volume: Double

    var isEmpty: Bool { tracks.isEmpty }
}

/// Reads and writes the snapshot beside the other local state.
///
/// A plain JSON file: the queue is a list of `Track`, which is already `Codable`, and there is no
/// reason to add a database for one small document. Writes are atomic so a crash mid-save cannot
/// leave a half-written queue behind.
struct QueueStore {
    private let url: URL

    init(supportDirectory: URL) {
        url = supportDirectory.appendingPathComponent("queue.json")
    }

    func load() -> QueueSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(QueueSnapshot.self, from: data),
              !snapshot.isEmpty
        else { return nil }
        return snapshot
    }

    func save(_ snapshot: QueueSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
