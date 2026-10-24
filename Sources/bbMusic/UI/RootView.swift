import SwiftUI

/// Sidebar + content + player bar. Three regions, fixed: the navigation never disappears and the
/// player bar is always present, even when nothing is playing.
struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: Player
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Palette.resolve(colorScheme)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SidebarView(model: model, player: player)
                    .frame(width: Theme.Metrics.sidebarWidth)
                    .frame(maxHeight: .infinity)
                // No strip above the content: each page states what it is in its own header, and the
                // sidebar already shows where the user is. A second copy of the same name across the
                // top was pure repetition.
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.content)
            }
            if let success = model.writeSuccess {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.accent)
                    Text(success)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(palette.accent.opacity(0.10))
                .transition(.opacity)
            }
            if let failure = model.writeError {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                    Text(failure)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.clearWriteError()
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.07))
                .transition(.opacity)
            }
            Divider()
            PlayerBarView(model: model, player: player)
        }
        .animation(.easeInOut(duration: 0.15), value: model.writeSuccess)
        .animation(.easeInOut(duration: 0.15), value: model.writeError)
        .frame(minWidth: 820, minHeight: 500)
        .background(palette.content)
        .tint(palette.accent)
        .environment(\.palette, palette)
        .background(WindowChrome())
        // The window's content starts at the very top edge, so the sidebar's plate reaches it and the
        // traffic lights float over it instead of sitting in a system strip of their own.
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder
    private var content: some View {
        if let message = sidecarMessage {
            ServiceUnavailableView(message: message) {
                model.start()
            }
        } else if model.showQueue {
            // The queue sits above the pane pages: opening it from the lyrics or the song detail
            // page has to actually show it, and those pages otherwise own the content area.
            QueuePane(model: model, player: player)
        } else if model.pane == .lyrics, player.currentTrack != nil {
            LyricsView(player: player) {
                model.pane = .list
            }
        } else if model.pane == .trackDetail, model.trackOnDetailPage != nil {
            TrackDetailPane(model: model, player: player) {
                model.closeTrackDetail()
            }
        } else if let unsupported = model.unsupportedMessage(for: model.section) {
            UnavailablePane(
                title: model.section.title,
                message: unsupported,
                needsLogin: !model.connection.isConnected && model.section != .search
            ) {
                model.showLoginSheet = true
            }
        } else if let route = model.route {
            // Every detail page comes from the route stack, so what is on screen and where 返回 goes
            // are the same fact. Picking the pane off separate `selected*` fields is what used to
            // let one page's leftovers render inside another.
            detailPane(route)
        } else {
            sectionPane
        }
    }

    @ViewBuilder
    private func detailPane(_ route: Route) -> some View {
        switch route {
        case .artist:
            ArtistDetailPane(model: model, player: player)
        case .toplist, .playlist, .searchPlaylist, .album:
            TracksPane(model: model, player: player)
        }
    }

    /// The section's own page, shown when no detail page is open.
    @ViewBuilder
    private var sectionPane: some View {
        switch model.section {
        case .charts:
            ChartsPane(model: model)
        case .search:
            SearchPane(model: model, player: player)
        case .playlists:
            PlaylistsPane(model: model)
        case .albums:
            AlbumsPane(model: model)
        case .daily, .liked:
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
    @Environment(\.palette) private var palette

    var body: some View {
        let side = palette.sidebar
        VStack(alignment: .leading, spacing: 0) {
            // The window has no system title bar: this plate reaches the top edge, and the app's
            // identity sits in the strip the traffic lights float over.
            TitleBarView(model: model, player: player)
            // No platform banner: the account state belongs at the bottom, next to the other one.
            // 每日推荐 and 排行榜 were never implemented; their entries only ever led to a
            // placeholder, so they are gone rather than left as dead ends.
            section("浏览", items: [.search, .daily, .charts])
            section("我的音乐", items: [.liked, .playlists, .albums])

            Spacer()

            VStack(spacing: 0) {
                Rectangle()
                    .fill(side.divider)
                    .frame(height: 1)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(side.background)
    }

    private func statusRow(label: String, connected: Bool, action: @escaping () -> Void) -> some View {
        let side = palette.sidebar
        return Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(connected ? side.statusDot : side.tertiaryText.opacity(0.6))
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(side.secondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func section(_ title: String, items: [AppModel.Section]) -> some View {
        let side = palette.sidebar
        return VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(side.tertiaryText)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 3)

            ForEach(items) { item in
                let isActive = model.section == item
                Button {
                    Task { await model.selectSection(item) }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11))
                            .frame(width: 15)
                            .foregroundStyle(isActive ? side.accent : side.tertiaryText)
                        Text(item.title)
                            .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                            .foregroundStyle(isActive ? side.text : side.secondaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isActive ? side.selection : .clear)
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
    @Environment(\.palette) private var palette

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
            if model.searchResults.isEmpty, model.isSearching {
                // Only before the first page arrives; after that the list stays put and grows.
                StatusPane(title: "搜索中…", message: nil, symbol: nil)
            } else if let error = model.searchError, model.searchResults.isEmpty {
                StatusPane(title: "搜索失败", message: error, symbol: "exclamationmark.triangle")
            } else if model.searchResults.isEmpty {
                StatusPane(
                    title: model.query.isEmpty ? "搜索" : "没有找到\(model.searchKind.label)",
                    message: model.query.isEmpty
                        ? "输入关键词后回车。可以切换搜索歌曲、专辑、歌单或歌手。"
                        : "换个关键词，或换一种搜索类型试试。",
                    symbol: nil,
                    usesMark: true
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

            if model.hasActiveFilters {
                Text("\(model.filteredCount) / \(model.searchResults.count) 条")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(palette.filterBar)
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
            .foregroundStyle(isActive ? palette.accent : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isActive ? palette.accent.opacity(0.14) : palette.chip)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var results: some View {
        VStack(spacing: 0) {
            resultsBody
            if model.canLoadMore || model.isLoadingMore || (model.isSearching && !model.searchResults.isEmpty) {
                loadMoreBar
            }
        }
    }

    /// Pulls the next batch when the user scrolls to the bottom.
    ///
    /// Skipped while a filter is active: the filtered list is shorter than the unfiltered one, so
    /// reaching its end does not mean the user has seen everything — loading on that signal would
    /// keep firing until the whole result set was fetched, which is the opposite of paging.
    private func autoLoad() {
        guard !model.hasActiveFilters, model.canLoadMore, !model.isLoadingMore else { return }
        Task { await model.loadMoreResults() }
    }

    /// Footer: reports progress rather than asking for a click, now that scrolling loads the next
    /// batch. Keeps the "how much is loaded" distinction visible next to the filters.
    private var loadMoreBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if model.isLoadingMore || model.isSearching {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                    Text("载入中…").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if model.canLoadMore {
                    Text("继续向下滚动载入更多")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("已全部载入")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text("已载入 \(model.searchResults.count) / \(model.searchResults.totalAvailable)")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var resultsBody: some View {
        switch model.searchKind {
        case .song:
            TrackList(
                tracks: model.filteredSongs,
                player: player,
                selectedID: $model.selectedTrackID,
                onReachEnd: autoLoad,
                isLiked: model.isLiked,
                onToggleLike: { track in Task { await model.toggleLike(track) } },
                onOpenArtist: { id, name in Task { await model.openArtist(id: id, name: name) } },
                onOpenAlbum: { id, name, artist in
                    Task { await model.openAlbum(id: id, name: name, artist: artist) }
                },
                // Search results are unrelated songs, so a play builds the queue out of the song's
                // own album instead of the rest of the result list.
                onPlay: { track in
                    Task { await model.playFromSearch(track) }
                },
                onShowDetail: { track in
                    model.showDetail(for: track)
                }
            )
        case .album:
            CardGrid(items: model.filteredAlbums, onReachEnd: autoLoad) { album in
                VStack(spacing: 4) {
                    Button {
                        Task { await model.open(album) }
                    } label: {
                        MediaCard(
                            title: album.name,
                            // Year first: on a classical catalogue it is often the only thing that
                            // distinguishes two recordings of the same work.
                            subtitle: album.year.map { "\($0) · \(album.artist)" } ?? album.artist,
                            artworkURL: album.artworkURL,
                            placeholderSymbol: "square.stack",
                            side: 120
                        )
                    }
                    .buttonStyle(.plain)
                    Button("点击收藏专辑") {
                        Task { await model.toggleSubscription(album) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                }
            }
        case .playlist:
            CardGrid(items: model.searchResults.playlists, onReachEnd: autoLoad) { playlist in
                VStack(spacing: 4) {
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
                    Button("点击收藏歌单") {
                        Task { await model.toggleSubscription(playlist) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                }
            }
        case .singer:
            CardGrid(items: model.searchResults.artists, onReachEnd: autoLoad) { artist in
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
            // Type selector first: it decides what the query means. Drawn with the palette rather
            // than as a system segmented control, which ignores tint and stayed system grey.
            ThemedSegmentedControl(
                selection: $model.searchKind,
                options: SearchKind.allCases.map { ($0, $0.label) },
                width: 260
            )

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
                    .fill(palette.field)
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
    @ObservedObject var model: AppModel
    @ObservedObject var player: Player

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if model.routes.canGoBack {
                    Button {
                        model.goBack()
                    } label: {
                        Label("返回", systemImage: "chevron.left")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                // A chart states its full size; how much of it is loaded belongs to the progress line
                // at the bottom, which also reports it.
                if model.isChartPage, model.toplistTotal > 0 {
                    Text("\(model.toplistTotal) 首")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if !model.libraryTracks.isEmpty {
                    Text("\(model.libraryTracks.count) 首")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // One button, both directions: an album that is in the collection says 取消收藏, and
                // the playlist button only ever acts on the playlist this page is showing.
                if let album = model.currentAlbum {
                    collectionButton(collected: model.isCollected(album)) {
                        Task { await model.toggleCollected(album) }
                    }
                } else if let playlist = model.openPlaylist {
                    collectionButton(collected: model.isCollected(playlist)) {
                        Task { await model.toggleCollected(playlist) }
                    }
                } else if let playlist = model.currentSearchPlaylist {
                    collectionButton(collected: model.isCollected(playlist)) {
                        Task { await model.toggleSubscription(playlist) }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider()

            // What the platform says about this playlist or album: description, owner, counts. Shown
            // above the tracks because it is what identifies the page, and dropped row by row when a
            // field was not reported.
            if !detailHeader.isEmpty {
                detailHeaderView(detailHeader)
            }

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
                    symbol: nil,
                    usesMark: true
                )
            } else {
                TrackList(
                    tracks: model.libraryTracks,
                    player: player,
                    selectedID: $model.selectedTrackID,
                    showsDiscs: model.currentAlbum != nil,
                    // Every song list shows the same columns: a playlist mixes albums, so the album
                    // a track came from is exactly what tells them apart.
                    showsAlbum: true,
                    onReachEnd: model.canLoadMoreToplist ? { Task { await model.loadMoreToplistTracks() } } : nil,
                    isLiked: model.isLiked,
                    onToggleLike: { track in Task { await model.toggleLike(track) } },
                    onOpenArtist: { id, name in Task { await model.openArtist(id: id, name: name) } },
                    onOpenAlbum: { id, name, artist in
                        Task { await model.openAlbum(id: id, name: name, artist: artist) }
                    },
                    onShowDetail: { track in model.showDetail(for: track) }
                )
                // A chart always says how much of it is on screen — "20 / 100" while there is more
                // to fetch, and the same line settled once everything is loaded. It used to appear
                // only while paging was still possible, so the count vanished exactly when the user
                // wanted to confirm they had seen the whole chart.
                if model.isChartPage {
                    HStack(spacing: 6) {
                        if model.isLoadingMore {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                            Text("载入中…")
                        } else if model.canLoadMoreToplist {
                            Text("继续向下滚动载入更多")
                        } else {
                            Text("已全部载入")
                        }
                        Spacer()
                        Text("已载入 \(model.libraryTracks.count) / \(model.toplistTotal)")
                    }
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func collectionButton(collected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(collected ? "取消收藏" : "收藏")
                .font(.system(size: 11))
        }
        .controlSize(.small)
    }

    /// The facts to show above the track list, if this page has any.
    private var detailHeader: [DetailHeaderItem] {
        var items: [DetailHeaderItem] = []
        if let album = model.currentAlbum {
            if let date = album.releaseDate { items.append(.init("发行", date)) }
            if let company = album.company { items.append(.init("唱片公司", company)) }
            if let genre = album.genre { items.append(.init("流派", genre)) }
            if let language = album.language { items.append(.init("语种", language)) }
            if let summary = album.summary { items.append(.init("简介", summary, isLong: true)) }
        } else if let details = model.currentPlaylistDetails {
            if let creator = details.creator { items.append(.init("创建者", creator)) }
            if let count = details.trackCount { items.append(.init("曲目", "\(count) 首")) }
            if let plays = details.playCount, plays > 0 { items.append(.init("播放", "\(plays) 次")) }
            if let comments = details.commentCount, comments > 0 {
                items.append(.init("评论", "\(comments) 条"))
            }
            if let created = details.createdAt {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                items.append(.init("创建于", formatter.string(from: created)))
            }
            if !details.tags.isEmpty {
                items.append(.init("标签", details.tags.joined(separator: " · ")))
            }
            if let summary = details.summary { items.append(.init("简介", summary, isLong: true)) }
        }
        return items
    }

    private func detailHeaderView(_ items: [DetailHeaderItem]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 10) {
                    Text(item.label)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .frame(width: 56, alignment: .leading)
                    Text(item.value)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(item.isLong ? 4 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.02))
    }

    /// The open page's own name, falling back to the section. Nothing from a page the user has
    /// already left can leak in here: the title is read off the route that is on screen.
    private var title: String {
        switch model.route {
        case .toplist(let toplist): return toplist.title
        case .playlist(let playlist): return playlist.name
        case .searchPlaylist(let playlist): return playlist.name
        case .album(let album): return album.name
        case .artist(let artist): return artist.name
        case nil:
            if model.section == .daily { return "每日推荐" }
            return model.section.title
        }
    }

    private var emptyTitle: String {
        if model.section == .daily, model.route == nil { return "今天没有推荐" }
        if model.route != nil { return "这里没有歌曲" }
        return model.section == .liked ? "「我喜欢」里还没有歌曲" : "这里是空的"
    }

    private var emptyMessage: String {
        if model.route != nil { return "这个专辑、歌单或歌手没有返回可播放的曲目。" }
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
                StatusPane(title: "还没有歌单", message: "在 QQ 音乐里创建或收藏歌单后会出现在这里。", symbol: nil, usesMark: true)
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
                            isSelected: model.route == .playlist(playlist)
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
                StatusPane(title: "还没有收藏的专辑", message: "在 QQ 音乐里收藏专辑后会出现在这里。", symbol: nil, usesMark: true)
            } else {
                CardGrid(items: model.albums) { album in
                    Button {
                        Task { await model.open(album) }
                    } label: {
                        MediaCard(
                            title: album.name,
                            subtitle: album.year.map { "\($0) · \(album.artist)" } ?? album.artist,
                            artworkURL: album.artworkURL,
                            placeholderSymbol: "square.stack",
                            side: 120,
                            isSelected: model.currentAlbum?.id == album.id
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Charts

private struct ChartsPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("排行榜").font(.system(size: 13, weight: .semibold))
                if !model.toplists.isEmpty {
                    Text("\(model.toplists.count) 个").font(.system(size: 11)).foregroundStyle(.secondary)
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
            } else if model.toplists.isEmpty {
                StatusPane(title: "没有取到排行榜", message: "检查网络或登录状态。", symbol: nil, usesMark: true)
            } else {
                CardGrid(items: model.toplists) { toplist in
                    Button {
                        Task { await model.open(toplist) }
                    } label: {
                        MediaCard(
                            title: toplist.title,
                            subtitle: "\(toplist.group) · \(toplist.trackCount) 首",
                            artworkURL: toplist.artworkURL,
                            placeholderSymbol: "list.number",
                            side: 120
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Artist detail

private struct ArtistDetailPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: Player

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.libraryError {
                StatusPane(title: "载入失败", message: error, symbol: "exclamationmark.triangle")
            } else if model.isLoadingLibrary {
                StatusPane(title: "载入中…", message: nil, symbol: nil)
            } else {
                switch model.artistTab {
                case .songs:
                    if model.artistSongs.isEmpty {
                        StatusPane(title: "没有取到歌曲", message: "这个歌手可能没有公开的曲目。", symbol: "music.note")
                    } else {
                        TrackList(
                            tracks: model.artistSongs,
                            player: player,
                            selectedID: $model.selectedTrackID,
                            isLiked: model.isLiked,
                            onToggleLike: { track in Task { await model.toggleLike(track) } },
                            onOpenArtist: { id, name in Task { await model.openArtist(id: id, name: name) } },
                            onOpenAlbum: { id, name, artist in
                                Task { await model.openAlbum(id: id, name: name, artist: artist) }
                            },
                            onShowDetail: { track in model.showDetail(for: track) }
                        )
                    }
                case .albums:
                    if model.artistAlbums.isEmpty {
                        StatusPane(title: "没有取到专辑", message: "这个歌手可能没有公开的专辑。", symbol: "square.stack")
                    } else {
                        CardGrid(items: model.artistAlbums) { album in
                            Button {
                                Task { await model.open(album) }
                            } label: {
                                MediaCard(
                                    title: album.name,
                                    subtitle: album.year.map { "\($0) · \(album.artist)" } ?? album.artist,
                                    artworkURL: album.artworkURL,
                                    placeholderSymbol: "square.stack",
                                    side: 120
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    model.goBack()
                } label: {
                    Label("返回", systemImage: "chevron.left")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(alignment: .top, spacing: 12) {
                AsyncImage(url: model.searchArtistDetail?.artworkURL) { phase in
                    ZStack {
                        Circle().fill(Color.primary.opacity(0.08))
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 22))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.searchArtistDetail?.name ?? "")
                        .font(.system(size: 15, weight: .semibold))
                    if let artist = model.searchArtistDetail {
                        Text("\(artist.songCount) 首 · \(artist.albumCount) 张专辑")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let bio = model.searchArtistDetail?.bio, !bio.isEmpty {
                        Text(bio)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }

            ThemedSegmentedControl(
                selection: $model.artistTab,
                options: AppModel.ArtistTab.allCases.map { ($0, $0.label) },
                width: 220
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 8)
    }
}

// MARK: - Queue

private struct QueuePane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: Player

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // Opened from the lyrics or the song detail page there is no list behind the queue,
                // so no 返回 is offered: the queue button itself closes it again.
                if model.queueReturnPane == nil {
                    Button {
                        model.closeQueue()
                    } label: {
                        Label("返回", systemImage: "chevron.left")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
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
                        // The queue is a list of tracks like any other, so it uses the same row: album,
                        // artist, heart and links all work here too. Keyed by track id rather than by
                        // position, so removing an entry does not shuffle every row's identity.
                        ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, track in
                            TrackRow(
                                index: index,
                                track: track,
                                isCurrent: player.currentTrack?.id == track.id,
                                isPlaying: player.currentTrack?.id == track.id && player.isPlaying,
                                isSelected: model.selectedTrackID == track.id,
                                showsAlbum: true,
                                isLiked: model.isLiked(track),
                                onToggleLike: { Task { await model.toggleLike(track) } },
                                onOpenArtist: { id, name in Task { await model.openArtist(id: id, name: name) } },
                                onOpenAlbum: { id, name, artist in
                                    Task { await model.openAlbum(id: id, name: name, artist: artist) }
                                },
                                onPlay: {
                                    model.selectedTrackID = track.id
                                    player.play(tracks: player.queue, startingAt: index)
                                },
                                onShowDetail: {
                                    model.selectedTrackID = track.id
                                    model.showDetail(for: track)
                                }
                            )
                            .background(RowClickCatcher(onClick: { model.selectedTrackID = track.id }))
                            .contextMenu {
                                Button("播放") {
                                    model.selectedTrackID = track.id
                                    player.play(tracks: player.queue, startingAt: index)
                                }
                                Button("详情") {
                                    model.selectedTrackID = track.id
                                    model.showDetail(for: track)
                                }
                                Divider()
                                Button("从队列移除") { player.removeFromQueue(at: IndexSet(integer: index)) }
                            }
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
        }
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
    /// Called when the last row comes into view; nil disables infinite scrolling.
    var onReachEnd: (() -> Void)?
    /// Like state lookup, supplied by the model so rows stay dumb.
    var isLiked: (Track) -> Bool = { _ in false }
    var onToggleLike: (Track) -> Void = { _ in }
    var onOpenArtist: (String, String) -> Void = { _, _ in }
    var onOpenAlbum: (String, String, String) -> Void = { _, _, _ in }
    /// What the row's 播放 button does. Defaults to "this list, from this row"; the search pane
    /// supplies its own, because a search result list is not an album or a playlist.
    var onPlay: ((Track) -> Void)?
    /// What the row's 详情 button and the context menu's 详情 do. The page it opens knows how to come
    /// back to the list it was opened from.
    var onShowDetail: ((Track) -> Void)?

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
                        showsAlbum: showsAlbum,
                        isLiked: isLiked(track),
                        onToggleLike: { onToggleLike(track) },
                        onOpenArtist: onOpenArtist,
                        onOpenAlbum: onOpenAlbum,
                        onPlay: {
                            selectedID = track.id
                            if let onPlay {
                                onPlay(track)
                            } else {
                                player.play(tracks: tracks, startingAt: index)
                            }
                        },
                        onShowDetail: onShowDetail.map { show in
                            { selectedID = track.id; show(track) }
                        }
                    )
                    // Selection is handled by AppKit on mouse-down. There is no double-click gesture
                    // any more — playing is a button and a menu item — so nothing has to wait out
                    // `NSEvent.doubleClickInterval` before a click registers.
                    .background(
                        RowClickCatcher(onClick: { selectedID = track.id })
                    )
                    .contextMenu {
                        Button("播放") {
                            selectedID = track.id
                            if let onPlay {
                                onPlay(track)
                            } else {
                                player.play(tracks: tracks, startingAt: index)
                            }
                        }
                        Button("详情") {
                            selectedID = track.id
                            onShowDetail?(track)
                        }
                        Divider()
                        Button(isLiked(track) ? "取消红心" : "加入我喜欢") { onToggleLike(track) }
                        if track.artistID != nil {
                            Button("歌手") { onOpenArtist(track.artistID!, track.artist) }
                        }
                        if track.albumID != nil {
                            Button("专辑") { onOpenAlbum(track.albumID!, track.album, track.artist) }
                        }
                    }
                    Divider().opacity(0.35)
                    if index == tracks.count - 1, let onReachEnd {
                        // The last row appearing is the "reached the bottom" signal; a sentinel view
                        // is used rather than a scroll offset because LazyVStack only builds rows
                        // near the viewport, so its appearance means the user is actually there.
                        Color.clear
                            .frame(height: 1)
                            .onAppear { onReachEnd() }
                    }
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
    var isLiked: Bool = false
    var onToggleLike: () -> Void = {}
    var onOpenArtist: (String, String) -> Void = { _, _ in }
    var onOpenAlbum: (String, String, String) -> Void = { _, _, _ in }
    /// Plays this row. `nil` hides the button (a list that has no notion of playing, e.g. the queue's
    /// own rows would still have one, so it is always supplied in practice).
    var onPlay: (() -> Void)?
    /// Opens this row's song detail page. `nil` hides the button.
    var onShowDetail: (() -> Void)?
    @State private var isHovering = false
    @Environment(\.palette) private var palette

    var body: some View {
        let info = TrackDisplay.info(for: track)
        HStack(spacing: 10) {
            Group {
                if isCurrent {
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.accent)
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

            // Artist and album link through to their pages, when the track carries an id for them.
            Button {
                if let id = track.artistID { onOpenArtist(id, track.artist) }
            } label: {
                Text(track.artist)
                    .font(.system(size: 11.5))
                    .foregroundStyle(track.artistID == nil ? Color.secondary : Color.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 150, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(track.artistID == nil)
            .onHover { inside in if inside, track.artistID != nil { NSCursor.pointingHand.push() } else { NSCursor.pop() } }

            if showsAlbum {
                Button {
                    if let id = track.albumID { onOpenAlbum(id, track.album, track.artist) }
                } label: {
                    Text(track.album)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 160, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(track.albumID == nil)
            }

            // Row actions sit before the duration and only appear on hover: a permanent pair of
            // buttons on every row would out-shout the content, and they are one click away when the
            // pointer is actually on the row.
            HStack(spacing: 2) {
                if let onPlay {
                    rowAction("play.fill", help: "播放", action: onPlay)
                }
                if let onShowDetail {
                    rowAction("info.circle", help: "详情", action: onShowDetail)
                }
                rowAction(
                    isLiked ? "heart.fill" : "heart",
                    help: isLiked ? "取消红心" : "加入我喜欢",
                    tint: isLiked ? palette.accent : Color.secondary.opacity(0.5),
                    action: onToggleLike
                )
            }
            // Reserved at the full width of all three actions so the duration column never shifts
            // when the pointer enters a row.
            .frame(width: 66, alignment: .trailing)
            .opacity(isHovering || isSelected ? 1 : 0)

            Text(track.durationText)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .onHover { isHovering = $0 }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(minHeight: Theme.Metrics.rowMinHeight)
        .background(rowBackground)
        .contentShape(Rectangle())
    }

    /// A row action. The hover fill is what tells the user which of the three the pointer is on —
    /// three 18pt icons in a row are otherwise indistinguishable targets.
    private func rowAction(
        _ symbol: String,
        help: String,
        tint: Color = .secondary,
        action: @escaping () -> Void
    ) -> some View {
        RowActionButton(symbol: symbol, help: help, tint: tint, action: action)
    }

    private var rowBackground: Color {
        if isSelected { return palette.accent.opacity(0.14) }
        if isCurrent { return Color.primary.opacity(0.06) }
        return .clear
    }
}

// MARK: - Player bar

private struct PlayerBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: Player
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 11) {
            // Artwork, title and artist are one target: clicking any of them opens the song's own
            // page, and clicking again closes it. It is the whole left block, not three small links.
            Button {
                model.toggleTrackDetail()
            } label: {
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(player.currentTrack == nil)
            .help("歌曲详情")
            .onHover { inside in
                if inside, player.currentTrack != nil { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

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
                    .foregroundStyle(player.repeatMode == .off ? .secondary : palette.accent)
            }
            .buttonStyle(.plain)
            .help("播放模式")

            // Queue and lyrics live at the far right of the player bar: both belong to playback,
            // not navigation. 「词」 sits to the queue's right and toggles — pressing it while the
            // lyrics are open returns to the list. A word rather than an SF Symbol because 词 is what
            // a listener says.
            Button {
                model.toggleQueue()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 11))
                    if !player.queue.isEmpty {
                        Text("\(player.queue.count)")
                            .font(.system(size: 9.5).monospacedDigit())
                    }
                }
                .foregroundStyle(model.showQueue ? palette.accent : .secondary)
            }
            .buttonStyle(.plain)
            .help("播放队列")

            Button {
                model.toggleLyrics()
            } label: {
                Text("词")
                    .font(.system(size: 11, weight: model.pane == .lyrics ? .semibold : .regular))
                    .foregroundStyle(model.pane == .lyrics ? palette.accent : .secondary)
                    .frame(width: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(player.currentTrack == nil)
            .help(model.pane == .lyrics ? "回到列表" : "查看歌词")
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.Metrics.playerBarHeight)
        .background(palette.content)
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
                RoundedRectangle(cornerRadius: Theme.Metrics.artworkCornerRadius)
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
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.artworkCornerRadius))
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
                        .fill(player.currentTrack == nil ? Color.secondary.opacity(0.25) : palette.playButton)
                        .frame(width: 28, height: 28)
                    if player.isBuffering && player.currentTrack != nil {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.playButtonGlyph)
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
        .background(Color.orange.opacity(0.10))
    }
}

/// Shared by every pane: an empty or failed area always explains itself in words.
struct StatusPane: View {
    let title: String
    let message: String?
    /// When the pane is empty rather than broken, the app's own mark stands in for an icon, so the
    /// window and the Dock use one symbol. Errors keep their SF Symbol.
    let symbol: String?
    var usesMark: Bool = false
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 9) {
            if usesMark {
                DoubleFlatMark()
                    .fill(palette.accent.opacity(0.55))
                    .frame(width: 44, height: 44)
                    .padding(.bottom, 2)
            } else if let symbol {
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
                    .frame(maxWidth: 320)
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

/// One label/value pair in a detail page's header.
private struct DetailHeaderItem: Identifiable {
    let label: String
    let value: String
    var isLong: Bool
    var id: String { label }

    init(_ label: String, _ value: String, isLong: Bool = false) {
        self.label = label
        self.value = value
        self.isLong = isLong
    }
}
