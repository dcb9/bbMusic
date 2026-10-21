import AVFoundation
import Foundation

/// Owns playback and the queue. This is the single source of truth for "what is playing"; no view
/// keeps its own copy.
///
/// The queue is managed here rather than by `AVQueuePlayer` because the user reorders, inserts and
/// jumps freely — `AVQueuePlayer`'s monotonic advance model fights every one of those.
@MainActor
final class Player: ObservableObject {
    enum RepeatMode: String, CaseIterable {
        case off, all, one

        var symbol: String {
            switch self {
            case .off: return "arrow.right"
            case .all: return "repeat"
            case .one: return "repeat.1"
            }
        }
    }

    // MARK: - Published state

    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isBuffering = false
    @Published private(set) var notice: String?
    @Published private(set) var isPreview = false
    @Published var repeatMode: RepeatMode = .off
    @Published var isShuffled = false
    @Published var volume: Double = 0.8 {
        didSet { player.volume = Float(volume) }
    }
    @Published private(set) var lyrics: Lyrics = .empty

    var currentTrack: Track? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    /// Called when a track starts, so the scrobbler can send now-playing and later judge the play.
    var onTrackStarted: ((Track) -> Void)?
    /// Called with the user-facing reason a track could not be played.
    var onPlaybackFailure: ((String) -> Void)?
    /// Called on every progress tick, so the scrobbler can judge the play against Last.fm's rule.
    var onProgress: ((TimeInterval) -> Void)?

    // MARK: - Internals

    private let platform: MusicPlatform
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var loadTask: Task<Void, Never>?
    /// Bumped on every load so a slow response for a track the user already skipped past cannot
    /// overwrite the current one.
    private var loadGeneration = 0

    init(platform: MusicPlatform) {
        self.platform = platform
        player.volume = Float(volume)
        installObservers()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    // MARK: - Queue control

    /// Plays a list starting at `index`. The list becomes the queue.
    func play(tracks: [Track], startingAt index: Int) {
        guard tracks.indices.contains(index) else { return }
        queue = tracks
        currentIndex = index
        load(tracks[index])
    }

    func playNow(_ track: Track, in tracks: [Track]? = nil) {
        if let tracks, let index = tracks.firstIndex(of: track) {
            play(tracks: tracks, startingAt: index)
        } else {
            queue = [track]
            currentIndex = 0
            load(track)
        }
    }

    func enqueue(_ track: Track) {
        guard !queue.contains(where: { $0.id == track.id }) else { return }
        queue.append(track)
        if currentIndex == nil {
            currentIndex = queue.count - 1
            load(track)
        }
    }

    func removeFromQueue(at offsets: IndexSet) {
        let removingCurrent = offsets.contains { $0 == currentIndex }
        let before = queue.count
        queue = queue.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        guard queue.count != before else { return }
        if queue.isEmpty {
            stop()
            return
        }
        if removingCurrent {
            let next = min(offsets.min() ?? 0, queue.count - 1)
            currentIndex = next
            load(queue[next])
        } else if let index = currentIndex {
            // Keep pointing at the same track after indices shift.
            currentIndex = min(index, queue.count - 1)
        }
    }

    func clearQueue() {
        stop()
        queue = []
        currentIndex = nil
    }

    func togglePlayPause() {
        guard currentTrack != nil else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func next(userInitiated: Bool = true) {
        guard !queue.isEmpty, let index = currentIndex else { return }
        if isShuffled, queue.count > 1 {
            var candidate = index
            while candidate == index { candidate = Int.random(in: 0..<queue.count) }
            currentIndex = candidate
        } else if index + 1 < queue.count {
            currentIndex = index + 1
        } else if repeatMode != .off {
            currentIndex = 0
        } else {
            player.pause()
            isPlaying = false
            player.seek(to: .zero)
            return
        }
        load(queue[currentIndex!])
    }

    func previous() {
        guard !queue.isEmpty, let index = currentIndex else { return }
        // Standard behaviour: restart the track unless we are in its first few seconds.
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        currentIndex = index > 0 ? index - 1 : 0
        load(queue[currentIndex!])
    }

    func seek(to time: TimeInterval) {
        let target = CMTime(seconds: max(0, time), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = max(0, time)
    }

    func stop() {
        loadTask?.cancel()
        loadGeneration += 1
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        isBuffering = false
        currentTime = 0
        duration = 0
        lyrics = .empty
        isPreview = false
    }

    // MARK: - Loading

    private func load(_ track: Track) {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        notice = nil
        lyrics = .empty
        isPreview = false
        isBuffering = true
        currentTime = 0
        duration = track.duration

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await self.platform.streamSource(for: track, quality: .best)
                guard generation == self.loadGeneration else { return }
                let url: URL
                switch source {
                case .url(let value):
                    url = value
                case .preview(let value):
                    url = value
                    self.isPreview = true
                }
                self.attach(url: url, track: track)
                self.onTrackStarted?(track)
            } catch {
                guard generation == self.loadGeneration else { return }
                let message = error.localizedDescription
                self.isBuffering = false
                self.isPlaying = false
                self.notice = message
                self.onPlaybackFailure?(message)
            }
            // Lyrics are secondary: never let a lyric failure interrupt playback.
            if let fetched = try? await self.platform.lyrics(for: track),
               generation == self.loadGeneration {
                self.lyrics = fetched
            }
        }
    }

    private func attach(url: URL, track: Track) {
        let item = AVPlayerItem(url: url)
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.isBuffering = false
                case .failed:

                    self.isBuffering = false
                    self.isPlaying = false
                    let message = item.error?.localizedDescription ?? "播放失败"
                    self.notice = message
                    self.onPlaybackFailure?(message)
                default:
                    break
                }
            }
        }
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true

        if track.duration == 0, item.duration.isNumeric {
            duration = CMTimeGetSeconds(item.duration)
        }
    }

    // MARK: - Observers

    private func installObservers() {
        // 4 Hz is enough for a smooth progress bar and a lyric line that lands on time.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = CMTimeGetSeconds(time)
                self.onProgress?(self.currentTime)
                if let item = self.player.currentItem, item.duration.isNumeric {
                    let value = CMTimeGetSeconds(item.duration)
                    if value.isFinite, value > 0 { self.duration = value }
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.repeatMode == .one {
                    self.seek(to: 0)
                    self.player.play()
                } else {
                    self.next(userInitiated: false)
                }
            }
        }
    }
}

private extension CMTime {
    var isNumeric: Bool {
        !flags.contains(.indefinite) && seconds.isFinite && seconds > 0
    }
}
