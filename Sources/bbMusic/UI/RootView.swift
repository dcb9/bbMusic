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
                    .frame(width: 210)
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            PlayerBarView(model: model, player: player)
        }
        .frame(minWidth: 820, minHeight: 500)
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
        } else if model.showQueue {
            QueuePane(model: model, player: player)
        } else if model.section == .search, model.hasSearchDetail {
            TracksPane(model: model, player: player, context: .searchDetail)
        } else if model.section == .search {
            // Search has its own pane with the query field. Without this branch it fell through to
            // the library pane, which has no way to type a query at all.
            SearchPane(model: model, player: player)
        } else if model.section == .playlists && model.selectedPlaylist == nil {
            PlaylistsPane(model: model)
        } else if model.section == .albums && model.selectedAlbum == nil {
            AlbumsPane(model: model)
        } else {
            TracksPane(model: model, player: player)
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
            // No platform banner: the account state belongs at the bottom, next to the other one.
            // 每日推荐 and 排行榜 were never implemented; their entries only ever led to a
            // placeholder, so they are gone rather than left as dead ends.
            section("浏览", items: [.search])
            section("我的音乐", items: [.liked, .playlists, .albums])

            Spacer()

            VStack(spacing: 0) {
                Divider()
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
                    Task { await model.selectSection(item) }
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
            if model.hasActiveFilters || model.searchResults.totalAvailable > 0 {
                filterBar
            }
            Divider()
            if let notice = player.notice {
                NoticeBar(text: notice)
            }
            if model.isSearching {
                StatusPane(title: "搜索中…", message: nil, symbol: nil)
            } else if let error = model.searchError {
                StatusPane(title: "搜索失败", message: error, symbol: "exclamationmark.triangle")
            } else if model.searchResults.isEmpty {
                StatusPane(
                    title: model.query.isEmpty ? "搜索" : "没有找到\(model.searchKind.label)",
                    message: model.query.isEmpty
                        ? "输入关键词后回车。可以切换搜索歌曲、专辑、歌单或歌手。"
                        : "换个关键词，或换一种搜索类型试试。",
                    symbol: "magnifyingglass"
                )
            } else {
                results
            }
        }
        .onAppear { searchFocused = true }
    }

    /// Local filters over the fetched results. Only dimensions the data actually carries appear —
    /// the QQ Music search response has no label or conductor field, so offering those would mean
    /// filtering on guesses.
    @ViewBuilder
    private var filterBar: some View {
        HStack(spacing: 8) {
            Text("筛选")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)

            if !model.availableYears.isEmpty {
                filterMenu(
                    title: model.filterYear.map(String.init) ?? "年份",
                    isActive: model.filterYear != nil,
                    options: model.availableYears.map { (String($0), String($0)) },
                    selection: Binding(
                        get: { model.filterYear.map(String.init) },
                        set: { model.filterYear = $0.flatMap(Int.init) }
                    )
                )
            }
            if !model.availableComposers.isEmpty {
                filterMenu(
                    title: model.filterComposer ?? "作曲家",
                    isActive: model.filterComposer != nil,
                    options: model.availableComposers.map { ($0, $0) },
                    selection: $model.filterComposer
                )
            }
            if !model.availablePerformers.isEmpty {
                filterMenu(
                    title: model.filterPerformer ?? (model.searchKind == .album ? "乐团" : "演奏者"),
                    isActive: model.filterPerformer != nil,
                    options: model.availablePerformers.map { ($0, $0) },
                    selection: $model.filterPerformer
                )
            }
            if model.searchKind == .song, !model.availableAlbums.isEmpty {
                filterMenu(
                    title: model.filterAlbum ?? "专辑",
                    isActive: model.filterAlbum != nil,
                    options: model.availableAlbums.map { ($0, $0) },
                    selection: $model.filterAlbum
                )
            }
            if model.hasActiveFilters {
                Button("清除") { model.clearFilters() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let progress = model.searchProgress {
                Text("已取 \(progress.loaded)/\(progress.total)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            } else if model.hasActiveFilters {
                Text("\(model.filteredCount) / \(model.searchResults.count) 条")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
    }

    private func filterMenu(
        title: String,
        isActive: Bool,
        options: [(value: String, label: String)],
        selection: Binding<String?>
    ) -> some View {
        Menu {
            Button("全部") { selection.wrappedValue = nil }
            Divider()
            ForEach(options, id: \.value) { option in
                Button(option.label) { selection.wrappedValue = option.value }
            }
        } label: {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 10.5, weight: isActive ? .semibold : .regular))
                Image(systemName: "chevron.down").font(.system(size: 7))
            }
            .foregroundStyle(isActive ? Color.accentColor : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isActive ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var results: some View {
        switch model.searchKind {
        case .song:
            TrackList(tracks: model.filteredSongs, player: player, selectedID: $model.selectedTrackID)
        case .album:
            CardGrid(items: model.filteredAlbums) { album in
                Button {
                    Task { await model.openAlbum(album) }
                } label: {
                    MediaCard(
                        title: album.name,
                        subtitle: album.artist,
                        artworkURL: album.artworkURL,
                        placeholderSymbol: "square.stack",
                        side: 120
                    )
                }
                .buttonStyle(.plain)
            }
        case .playlist:
            CardGrid(items: model.searchResults.playlists) { playlist in
                Button {
                    Task { await model.open(playlist) }
                } label: {
                    MediaCard(
                        title: playlist.name,
                        subtitle: "\(playlist.creator) · \(playlist.trackCount) 首",
                        artworkURL: playlist.artworkURL,
                        placeholderSymbol: "music.note.list",
                        side: 120
                    )
                }
                .buttonStyle(.plain)
            }
        case .singer:
            CardGrid(items: model.searchResults.artists) { artist in
                Button {
                    Task { await model.open(artist) }
                } label: {
                    MediaCard(
                        title: artist.name,
                        subtitle: "\(artist.songCount) 首 · \(artist.albumCount) 张专辑",
                        artworkURL: artist.artworkURL,
                        placeholderSymbol: "person.crop.circle",
                        side: 120
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            // Type selector first: it decides what the query means.
            Picker("", selection: $model.searchKind) {
                ForEach(SearchKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            Spacer()

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索\(model.searchKind.label)", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 190)
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

// MARK: - Library panes

private struct TracksPane: View {
    enum Context { case library, searchDetail }
    @ObservedObject var model: AppModel
    @ObservedObject var player: Player
    var context: Context = .library

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if context == .searchDetail {
                    Button {
                        model.clearSearchDetail()
                    } label: {
                        Label("返回搜索", systemImage: "chevron.left")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else if model.selectedPlaylist != nil || model.selectedAlbum != nil {
                    Button {
                        model.closeDetail()
                    } label: {
                        Label("返回", systemImage: "chevron.left")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if !model.libraryTracks.isEmpty {
                    Text("\(model.libraryTracks.count) 首")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider()

            if let notice = player.notice {
                NoticeBar(text: notice)
            }

            if model.isLoadingLibrary {
                StatusPane(title: "载入中…", message: nil, symbol: nil)
            } else if let error = model.libraryError {
                StatusPane(title: "载入失败", message: error, symbol: "exclamationmark.triangle")
            } else if model.libraryTracks.isEmpty {
                StatusPane(
                    title: emptyTitle,
                    message: emptyMessage,
                    symbol: "music.note.list"
                )
            } else {
                TrackList(
                    tracks: model.libraryTracks,
                    player: player,
                    selectedID: $model.selectedTrackID,
                    showsDiscs: model.selectedAlbum != nil,
                    showsAlbum: model.selectedPlaylist == nil && model.searchPlaylistDetail == nil
                )
            }
        }
    }

    private var title: String {
        if let playlist = model.selectedPlaylist { return playlist.name }
        if let playlist = model.searchPlaylistDetail { return playlist.name }
        if let artist = model.searchArtistDetail { return artist.name }
        if let album = model.selectedAlbum { return album.name }
        return model.section.title
    }

    private var emptyTitle: String {
        if context == .searchDetail { return "这里没有歌曲" }
        return model.section == .liked ? "「我喜欢」里还没有歌曲" : "这里是空的"
    }

    private var emptyMessage: String {
        if context == .searchDetail { return "这个专辑、歌单或歌手没有返回可播放的曲目。" }
        return model.section == .liked
            ? "在 QQ 音乐里点红心的歌曲会出现在这里。"
            : "换一个歌单看看，或者检查登录状态。"
    }
}

private struct PlaylistsPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("歌单").font(.system(size: 13, weight: .semibold))
                if !model.playlists.isEmpty {
                    Text("\(model.playlists.count) 个").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider()

            if model.isLoadingLibrary {
                StatusPane(title: "载入中…", message: nil, symbol: nil)
            } else if let error = model.libraryError {
                StatusPane(title: "载入失败", message: error, symbol: "exclamationmark.triangle")
            } else if model.playlists.isEmpty {
                StatusPane(title: "还没有歌单", message: "在 QQ 音乐里创建或收藏歌单后会出现在这里。", symbol: "music.note.list")
            } else {
                CardGrid(items: model.playlists) { playlist in
                    Button {
                        Task { await model.open(playlist) }
                    } label: {
                        MediaCard(
                            title: playlist.name,
                            subtitle: "\(playlist.trackCount) 首\(playlist.isCollected ? " · 收藏" : "")",
                            // Whatever the API supplied; the card shows a placeholder when it didn't.
                            artworkURL: playlist.artworkURL,
                            placeholderSymbol: playlist.isLikedSongs ? "heart.fill" : "music.note.list",
                            side: 120,
                            isSelected: model.selectedPlaylist?.id == playlist.id
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct AlbumsPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("收藏的专辑").font(.system(size: 13, weight: .semibold))
                if !model.albums.isEmpty {
                    Text("\(model.albums.count) 张").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider()

            if model.isLoadingLibrary {
                StatusPane(title: "载入中…", message: nil, symbol: nil)
            } else if let error = model.libraryError {
                StatusPane(title: "载入失败", message: error, symbol: "exclamationmark.triangle")
            } else if model.albums.isEmpty {
                StatusPane(title: "还没有收藏的专辑", message: "在 QQ 音乐里收藏专辑后会出现在这里。", symbol: "square.stack")
            } else {
                CardGrid(items: model.albums) { album in
                    Button {
                        Task { await model.open(album) }
                    } label: {
                        MediaCard(
                            title: album.name,
                            subtitle: album.artist,
                            artworkURL: album.artworkURL,
                            placeholderSymbol: "square.stack",
                            side: 120,
                            isSelected: model.selectedAlbum?.id == album.id
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Queue

private struct QueuePane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: Player

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    model.showQueue = false
                } label: {
                    Label("返回", systemImage: "chevron.left")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Text("播放队列").font(.system(size: 13, weight: .semibold))
                if !player.queue.isEmpty {
                    Text("\(player.queue.count) 首").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if !player.queue.isEmpty {
                    Button("清空") { player.clearQueue() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider()

            if player.queue.isEmpty {
                StatusPane(
                    title: "队列是空的",
                    message: "双击歌曲列表里的任意一首，整张列表会成为播放队列。",
                    symbol: "list.bullet"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(player.queue.enumerated()), id: \.offset) { index, track in
                            QueueRow(
                                index: index,
                                track: track,
                                isCurrent: player.currentIndex == index,
                                isPlaying: player.currentIndex == index && player.isPlaying,
                                isSelected: model.selectedTrackID == track.id
                            )
                            .onTapGesture(count: 2) {
                                model.selectedTrackID = track.id
                                player.play(tracks: player.queue, startingAt: index)
                            }
                            .onTapGesture { model.selectedTrackID = track.id }
                            .contextMenu {
                                Button("移除") { player.removeFromQueue(at: IndexSet(integer: index)) }
                                Button("播放这首") { player.play(tracks: player.queue, startingAt: index) }
                            }
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
        }
    }
}

private struct QueueRow: View {
    let index: Int
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool
    let isSelected: Bool

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
                .font(.system(size: 11.5))
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
        .background(isSelected ? Color.accentColor.opacity(0.14) : (isCurrent ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
    }
}

// MARK: - Track list

private struct TrackList: View {
    let tracks: [Track]
    @ObservedObject var player: Player
    @Binding var selectedID: String?
    /// Albums show a disc heading per disc; playlists and search results do not.
    var showsDiscs: Bool = false
    /// Playlists hide the album column; search results and album pages show it.
    var showsAlbum: Bool = true

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    if showsDiscs, let heading = discHeading(at: index) {
                        Text(heading)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                    }
                    TrackRow(
                        index: index,
                        track: track,
                        isCurrent: player.currentTrack?.id == track.id,
                        isPlaying: player.currentTrack?.id == track.id && player.isPlaying,
                        isSelected: selectedID == track.id,
                        showsAlbum: showsAlbum
                    )
                    // `.simultaneousGesture` instead of two `onTapGesture`s: stacking a single- and a
                    // double-tap gesture makes SwiftUI wait for the single-tap to fail before it can
                    // resolve the double-tap, which is what made selection feel a second late.
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            selectedID = track.id
                            player.play(tracks: tracks, startingAt: index)
                        }
                    )
                    .onTapGesture {
                        selectedID = track.id
                    }
                    Divider().opacity(0.35)
                }
            }
        }
    }

    /// A disc heading appears before the first track of each disc.
    private func discHeading(at index: Int) -> String? {
        let disc = tracks[index].disc
        guard let disc, !disc.isEmpty else { return nil }
        if index == 0 { return disc }
        return tracks[index - 1].disc == disc ? nil : disc
    }
}

private struct TrackRow: View {
    let index: Int
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool
    let isSelected: Bool
    /// Album column. Hidden inside a playlist, where every row would repeat the same or an
    /// irrelevant album; shown in search results and on album pages.
    var showsAlbum: Bool = true

    var body: some View {
        let info = TrackDisplay.info(for: track)
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

            VStack(alignment: .leading, spacing: 1) {
                // Titles are shown in full: classical titles routinely run past what one line
                // holds, and truncating them hides the work, the key and the catalogue number.
                Text(track.title)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                if let credit = TrackDisplay.creditLine(for: track, heuristic: info) {
                    Text(credit)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(track.artist)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 150, alignment: .leading)

            if showsAlbum {
                Text(track.album)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 160, alignment: .leading)
            }

            Text(track.durationText)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(minHeight: 29)
        .background(rowBackground)
        .contentShape(Rectangle())
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.14) }
        if isCurrent { return Color.primary.opacity(0.06) }
        return .clear
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
            .frame(width: 170, alignment: .leading)

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

            qualityMenu

            Button {
                player.repeatMode = nextRepeat(player.repeatMode)
            } label: {
                Image(systemName: player.repeatMode.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(player.repeatMode == .off ? .secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("播放模式")

            // Queue lives at the far right of the player bar: it belongs to playback, not navigation.
            Button {
                model.showQueue.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 11))
                    if !player.queue.isEmpty {
                        Text("\(player.queue.count)")
                            .font(.system(size: 9.5).monospacedDigit())
                    }
                }
                .foregroundStyle(model.showQueue ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("播放队列")
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Quality picker. Lists what the current track can actually be served at, with file sizes, so
    /// an option is never offered that would silently produce nothing.
    private var qualityMenu: some View {
        Menu {
            Picker("音质", selection: $player.preferredQuality) {
                Text(AudioQuality.best.label).tag(AudioQuality.best)
                if !player.availableQualities.isEmpty {
                    Divider()
                    ForEach(player.availableQualities) { option in
                        Text("\(option.quality.label) · \(option.sizeText)")
                            .tag(option.quality)
                    }
                }
            }
            .pickerStyle(.inline)

            if !player.availableQualities.isEmpty {
                Divider()
                Text("当前歌曲可用 \(player.availableQualities.count) 种音质")
            }
        } label: {
            Text(qualityLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(player.currentTrack == nil ? .tertiary : .secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(player.currentTrack == nil)
        .help("音质")
    }

    private var qualityLabel: String {
        if let delivered = player.deliveredQuality { return delivered.shortLabel }
        return player.preferredQuality.shortLabel
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
