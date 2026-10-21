import SwiftUI

/// Sidebar + content + player bar. Three regions, fixed: the navigation never disappears and the
/// player bar is always present, even when nothing is playing.
struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: Player

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SidebarView(model: model, player: player)
                    .frame(width: 200)
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            PlayerBarView(model: model, player: player)
        }
        .frame(minWidth: 780, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        if let message = sidecarMessage {
            ServiceUnavailableView(message: message) {
                model.start()
            }
        } else if model.pane == .lyrics, player.currentTrack != nil {
            LyricsView(player: player) {
                model.pane = .list
            }
        } else if let unsupported = model.unsupportedMessage(for: model.section) {
            UnavailablePane(
                title: model.section.title,
                message: unsupported,
                needsLogin: !model.connection.isConnected && model.section != .search
            ) {
                model.showLoginSheet = true
            }
        } else {
            SearchPane(model: model, player: player)
        }
    }

    /// The sidecar is the app's only data source; when it is down every pane would be empty, so say
    /// so once, centrally, with a way to retry.
    private var sidecarMessage: String? {
        switch model.sidecarState {
        case .ready:
            return nil
        case .idle, .starting:
            return "正在启动 QQ 音乐服务…"
        case .failed(let reason):
            return reason
        }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: Player

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "music.note")
                    .foregroundStyle(.tint)
                Text("QQ 音乐")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(model.connection.label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)

            section("浏览", items: [.search, .daily, .charts])
            section("我的音乐", items: [.liked, .playlists])

            Spacer()

            VStack(spacing: 0) {
                Divider()
                // Two account rows, same shape: the platform, then the scrobbler.
                statusRow(
                    label: model.connection.isConnected
                        ? "QQ 音乐 · \(model.connection.label)"
                        : "登录 QQ 音乐",
                    connected: model.connection.isConnected
                ) {
                    model.showLoginSheet = true
                }
                statusRow(
                    label: model.scrobbler.connection.isConnected
                        ? "Last.fm · \(model.scrobbler.connection.label)"
                        : "连接 Last.fm",
                    connected: model.scrobbler.connection.isConnected
                ) {
                    model.showLastFMPanel = true
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func statusRow(label: String, connected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(connected ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func section(_ title: String, items: [AppModel.Section]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 3)

            ForEach(items) { item in
                Button {
                    model.section = item
                    model.pane = .list
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11))
                            .frame(width: 15)
                            .foregroundStyle(model.section == item ? Color.accentColor : .secondary)
                        Text(item.title)
                            .font(.system(size: 12, weight: model.section == item ? .semibold : .regular))
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(model.section == item ? Color.primary.opacity(0.08) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 5)
            }
        }
    }
}

// MARK: - Search pane

private struct SearchPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: Player
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let notice = player.notice {
                NoticeBar(text: notice)
            }
            if model.isSearching {
                StatusPane(title: "搜索中…", message: nil, symbol: nil)
            } else if let error = model.searchError {
                StatusPane(title: "搜索失败", message: error, symbol: "exclamationmark.triangle")
            } else if model.results.isEmpty {
                StatusPane(
                    title: model.query.isEmpty ? "搜索歌曲" : "没有找到结果",
                    message: model.query.isEmpty
                        ? "输入歌名、歌手或专辑，回车开始搜索。"
                        : "换个关键词试试，或者检查网络与登录状态。",
                    symbol: "magnifyingglass"
                )
            } else {
                TrackList(tracks: model.results, player: player)
            }
        }
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("搜索")
                .font(.system(size: 13, weight: .semibold))
            if !model.results.isEmpty {
                Text("\(model.results.count) 首")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索歌曲", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 170)
                    .focused($searchFocused)
                    .onSubmit { Task { await model.runSearch() } }
                if !model.query.isEmpty {
                    Button {
                        model.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - Track list

private struct TrackList: View {
    let tracks: [Track]
    @ObservedObject var player: Player

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(
                        index: index,
                        track: track,
                        isCurrent: player.currentTrack?.id == track.id,
                        isPlaying: player.currentTrack?.id == track.id && player.isPlaying
                    )
                    .onTapGesture {
                        player.play(tracks: tracks, startingAt: index)
                    }
                    Divider().opacity(0.35)
                }
            }
        }
    }
}

private struct TrackRow: View {
    let index: Int
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if isCurrent {
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 22, alignment: .trailing)

            Text(track.title)
                .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(track.artist)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)

            Text(track.durationText)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 29)
        .background(isCurrent ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
    }
}

// MARK: - Player bar

private struct PlayerBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: Player

    var body: some View {
        HStack(spacing: 11) {
            artwork

            VStack(alignment: .leading, spacing: 1) {
                Text(player.currentTrack?.title ?? "未在播放")
                    .font(.system(size: 12, weight: player.currentTrack == nil ? .regular : .semibold))
                    .foregroundStyle(player.currentTrack == nil ? .secondary : .primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)

            transport

            VStack(spacing: 2) {
                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(player.duration, 0.01)
                )
                .controlSize(.mini)
                .disabled(player.currentTrack == nil)
                HStack {
                    Text(timeText(player.currentTime))
                    Spacer()
                    Text(timeText(player.duration))
                }
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.tertiary)
            }
            .frame(minWidth: 150)

            HStack(spacing: 5) {
                Image(systemName: "speaker.wave.1")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Slider(value: $player.volume, in: 0...1)
                    .controlSize(.mini)
                    .frame(width: 70)
            }

            Button {
                player.repeatMode = nextRepeat(player.repeatMode)
            } label: {
                Image(systemName: player.repeatMode.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(player.repeatMode == .off ? .secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("播放模式")
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var subtitle: String {
        guard let track = player.currentTrack else { return "—" }
        if player.isPreview { return "\(track.artist) · 试听 30 秒" }
        return track.album.isEmpty ? track.artist : "\(track.artist) · \(track.album)"
    }

    private var artwork: some View {
        AsyncImage(url: player.currentTrack?.artworkURL) { phase in
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.08))
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var transport: some View {
        HStack(spacing: 2) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .disabled(player.currentTrack == nil)

            Button { player.togglePlayPause() } label: {
                ZStack {
                    Circle()
                        .fill(player.currentTrack == nil ? Color.secondary.opacity(0.25) : Color.primary)
                        .frame(width: 28, height: 28)
                    if player.isBuffering && player.currentTrack != nil {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(player.currentTrack == nil)

            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .disabled(player.currentTrack == nil)
        }
        .foregroundStyle(.primary)
    }

    private func timeText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func nextRepeat(_ mode: Player.RepeatMode) -> Player.RepeatMode {
        switch mode {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

// MARK: - Shared small views

private struct NoticeBar: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.08))
    }
}

private struct StatusPane: View {
    let title: String
    let message: String?
    let symbol: String?

    var body: some View {
        VStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)
            }
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
            if let message {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct UnavailablePane: View {
    let title: String
    let message: String
    let needsLogin: Bool
    let onLogin: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider()
            VStack(spacing: 9) {
                Image(systemName: needsLogin ? "lock" : "hourglass")
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)
                Text(needsLogin ? "需要先登录 QQ 音乐" : "这个入口还没接入")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                if needsLogin {
                    Button("扫码登录") { onLogin() }
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ServiceUnavailableView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("QQ 音乐服务未就绪")
                .font(.system(size: 12.5, weight: .semibold))
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("重试") { onRetry() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
