import AppKit
import Foundation

/// Decides when a play counts as a scrobble, and owns the durable queue of records waiting to be
/// submitted.
///
/// The rules are Last.fm's, not ours: a track must be longer than 30 seconds and must have played
/// for half its length or 4 minutes, whichever comes first. Submitting anything less pollutes the
/// user's listening history, so the engine refuses rather than approximates.
@MainActor
final class Scrobbler: ObservableObject {
    enum Connection: Equatable {
        case noCredentials
        case disconnected
        case authorizing
        case connected(username: String)
        case failed(String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        var label: String {
            switch self {
            case .noCredentials: return "未配置"
            case .disconnected: return "未连接"
            case .authorizing: return "授权中"
            case .connected(let name): return name
            case .failed: return "出错"
            }
        }
    }

    /// Last.fm rejects scrobbles older than this. It is not in the public documentation, but it is
    /// enforced: older timestamps come back as ignored. Queued records past it are dropped instead
    /// of being retried forever.
    static let backfillWindow: TimeInterval = 14 * 24 * 60 * 60
    /// Last.fm's own threshold below which a play is never counted.
    static let minimumTrackLength: TimeInterval = 30

    @Published private(set) var connection: Connection = .noCredentials
    @Published private(set) var pendingCount = 0
    /// Short-lived message for the UI ("已记录到 Last.fm · 晴天").
    @Published private(set) var lastActivity: String?

    private var client: LastFMClient?
    private var pending: [ScrobbleRecord] = []
    private var inFlight = false
    private let storeURL: URL

    // MARK: - Current play tracking

    private var currentTrackID: String?
    private var currentStartedAt: Date?
    private var currentDuration: TimeInterval = 0
    private var currentTrack: Track?
    private var didCountCurrentPlay = false

    init(storeURL: URL) {
        self.storeURL = storeURL
        loadQueue()
    }

    // MARK: - Setup

    /// Reads the application identity and session from the Keychain and decides the initial state.
    ///
    /// Nothing is seeded from source on purpose — see `Keychain` for why the shared secret must not
    /// live in the repository.
    func bootstrap() {
        guard let credentials = Keychain.loadLastFMCredentials() else {
            connection = .noCredentials
            return
        }
        client = LastFMClient(credentials: credentials)
        if let username = credentials.username, let key = credentials.sessionKey, !key.isEmpty {
            connection = .connected(username: username)
        } else {
            connection = .disconnected
        }
        Task { await flushQueue() }
    }

    // MARK: - Authorization

    /// Runs Last.fm's desktop flow: fetch a token, open the browser, poll until the user confirms.
    /// Polling is what makes a callback URL unnecessary.
    func authorize() async {
        guard let client else {
            connection = .failed("缺少 Last.fm API 凭据")
            return
        }
        connection = .authorizing
        do {
            let token = try await client.requestToken()
            guard let url = LastFMClient.authorizationURL(
                apiKey: Keychain.loadLastFMCredentials()?.apiKey ?? "",
                token: token
            ) else {
                connection = .failed("无法构造授权地址")
                return
            }
            NSWorkspace.shared.open(url)

            // The user has to switch to a browser and confirm; give them a couple of minutes.
            for _ in 0..<60 {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                do {
                    let session = try await client.createSession(token: token)
                    Keychain.saveSession(key: session.sessionKey, username: session.username)
                    self.client = LastFMClient(credentials: LastFMClient.Credentials(
                        apiKey: Keychain.loadLastFMCredentials()?.apiKey ?? "",
                        sharedSecret: Keychain.loadLastFMCredentials()?.sharedSecret ?? "",
                        sessionKey: session.sessionKey,
                        username: session.username
                    ))
                    connection = .connected(username: session.username)
                    await flushQueue()
                    return
                } catch LastFMClient.ClientError.notAuthorizedYet {
                    continue
                }
            }
            connection = .disconnected
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    func signOut() {
        Keychain.clearSession()
        if let credentials = Keychain.loadLastFMCredentials() {
            client = LastFMClient(credentials: credentials)
        }
        connection = .disconnected
    }

    // MARK: - Play lifecycle

    /// A track started playing. Announces it and arms the scrobble decision.
    func trackStarted(_ track: Track, isPreview: Bool) {
        currentTrack = track
        currentTrackID = track.id
        currentStartedAt = Date()
        currentDuration = track.duration
        didCountCurrentPlay = false

        // A 30-second preview is not a play of the song; announcing it would be a lie and counting
        // it would corrupt the history.
        guard !isPreview, connection.isConnected, track.duration > Self.minimumTrackLength else { return }
        Task { [weak self] in
            guard let self, let client = self.client else { return }
            let record = ScrobbleRecord(
                trackID: track.id, artist: track.artist, title: track.title,
                album: track.album, duration: track.duration, startedAt: Date()
            )
            try? await client.updateNowPlaying(record)
        }
    }

    /// Progress tick from the player. Counts the play at most once, as soon as the threshold is met.
    func updateProgress(_ elapsed: TimeInterval) {
        guard !didCountCurrentPlay,
              connection.isConnected,
              let track = currentTrack,
              let startedAt = currentStartedAt,
              currentDuration > Self.minimumTrackLength,
              !playerIsPreview
        else { return }

        let threshold = min(currentDuration / 2, 240)
        guard elapsed >= threshold else { return }

        didCountCurrentPlay = true
        let record = ScrobbleRecord(
            trackID: track.id,
            artist: track.artist,
            title: track.title,
            album: track.album,
            duration: currentDuration,
            startedAt: startedAt
        )
        enqueue(record)
        Task { await flushQueue() }
    }

    /// Set by the player so the engine can refuse to count previews.
    var playerIsPreview = false

    func trackStopped() {
        currentTrackID = nil
        currentStartedAt = nil
        currentTrack = nil
        didCountCurrentPlay = false
    }

    // MARK: - Queue

    private func enqueue(_ record: ScrobbleRecord) {
        guard !pending.contains(where: { $0.idempotencyKey == record.idempotencyKey }) else { return }
        pending.append(record)
        trimExpired()
        saveQueue()
    }

    /// Drops records Last.fm would refuse anyway, so the queue cannot grow without bound.
    private func trimExpired() {
        let cutoff = Date().addingTimeInterval(-Self.backfillWindow)
        pending.removeAll { $0.startedAt < cutoff }
    }

    /// Submits everything queued. Safe to call often: `inFlight` prevents overlapping runs and the
    /// idempotency key prevents duplicates.
    func flushQueue() async {
        guard !inFlight, connection.isConnected, let client else {
            pendingCount = pending.count
            return
        }
        inFlight = true
        defer {
            inFlight = false
            pendingCount = pending.count
        }
        trimExpired()

        while !pending.isEmpty {
            let batch = Array(pending.prefix(50))
            do {
                let outcome = try await client.scrobble(batch)
                // Only remove what Last.fm actually stored. Records it ignored are dropped too —
                // they are permanently unacceptable (bad metadata, artist ignored, too old) and
                // retrying can never succeed.
                let resolved = min(outcome.accepted + outcome.ignored, batch.count)
                let settled = Set(batch.prefix(resolved).map(\.idempotencyKey))
                if resolved == 0 {
                    // Nothing settled: Last.fm is refusing the batch wholesale. Keep it and stop,
                    // rather than spinning on the same records.
                    return
                }
                pending.removeAll { settled.contains($0.idempotencyKey) }
                saveQueue()
                pendingCount = pending.count
                if outcome.accepted > 0 {
                    lastActivity = outcome.accepted == 1
                        ? "已记录到 Last.fm · \(batch[0].title)"
                        : "已记录 \(outcome.accepted) 首到 Last.fm"
                }
            } catch LastFMClient.ClientError.invalidSession {
                connection = .disconnected
                return
            } catch {
                // Keep the queue; the next flush retries. Do not surface every transient failure.
                return
            }
        }
    }

    // MARK: - Persistence

    private func loadQueue() {
        guard let data = try? Data(contentsOf: storeURL),
              let records = try? JSONDecoder().decode([ScrobbleRecord].self, from: data)
        else {
            pendingCount = 0
            return
        }
        pending = records
        trimExpired()
        pendingCount = pending.count
    }

    private func saveQueue() {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: - Diagnostics

    /// Used by the self-test: the rule engine's decision for a hypothetical play, without submitting.
    static func wouldScrobble(duration: TimeInterval, elapsed: TimeInterval, isPreview: Bool) -> Bool {
        guard !isPreview, duration > minimumTrackLength else { return false }
        return elapsed >= min(duration / 2, 240)
    }
}
