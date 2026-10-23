import SwiftUI

/// The song's own page: what is playing, and the facts the platform knows about it.
///
/// A full page rather than a popover, for the same reason the lyrics are one: it sits in the same
/// place as the list, the sidebar and the player bar never move, and there is no second floating
/// layer to dismiss. It follows the current track, so skipping a song re-fills it rather than
/// leaving the previous song's facts on screen.
///
/// Restraint is the brief: one cover, one table, one paragraph. No gradients, no rotation, no
/// animation — the numbers and the artwork are the content.
struct TrackDetailPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: Player
    let onBack: () -> Void
    @Environment(\.palette) private var palette

    private var track: Track? { player.currentTrack }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let track {
                content(track)
            } else {
                StatusPane(title: "没有正在播放的歌曲", message: "先双击一首歌，再回来看这里。", symbol: nil, usesMark: true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                onBack()
            } label: {
                Label("返回", systemImage: "chevron.left")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Text("歌曲详情")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if let track {
                // Chips rather than system buttons: the rest of the window is drawn from the palette,
                // and a grey AppKit capsule in the header is the one thing that would not belong.
                headerChip(
                    model.isLiked(track) ? "已喜欢" : "加入我喜欢",
                    emphasised: model.isLiked(track)
                ) {
                    Task { await model.toggleLike(track) }
                }
                headerChip("歌词") { model.toggleLyrics() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func headerChip(
        _ title: String,
        emphasised: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: emphasised ? .medium : .regular))
                .foregroundStyle(emphasised ? palette.accent : Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(emphasised ? palette.accent.opacity(0.14) : palette.chip)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func content(_ track: Track) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero(track)
                facts(track)
                if let intro = model.trackDetail?.intro, !intro.isEmpty {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 1)
                        .padding(.top, 24)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("简介")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                        Text(intro)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(4)
                    }
                    .padding(.top, 16)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hero(_ track: Track) -> some View {
        HStack(alignment: .top, spacing: 22) {
            AsyncImage(url: track.artworkURL) { phase in
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.primary.opacity(0.08))
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 26))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(width: 152, height: 152)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 5) {
                Text(player.isPreview ? "正在播放 · 试听 30 秒" : "正在播放")
                    .font(.system(size: 9.5, weight: .medium))
                    .tracking(1.1)
                    .foregroundStyle(.tertiary)
                Text(track.title)
                    .font(.system(size: 22, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Text(track.artist)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    if track.artistID != nil {
                        Text("›").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                // Secondary line: album · year · company, each shown only when the platform said it.
                Text(secondaryLine(track))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
    }

    private func secondaryLine(_ track: Track) -> String {
        var parts: [String] = []
        if !track.album.isEmpty { parts.append(track.album) }
        if let year = track.year { parts.append(String(year)) }
        if let company = model.trackDetail?.company, !company.isEmpty { parts.append(company) }
        return parts.joined(separator: " · ")
    }

    /// Two columns of label/value pairs. Every row is conditional: a field the platform did not
    /// answer is absent rather than blank, so the table never reads like a form with holes in it.
    private func facts(_ track: Track) -> some View {
        let rows = factRows(track)
        return VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(
                columns: [
                    GridItem(.fixed(88), alignment: .leading),
                    GridItem(.flexible(), alignment: .leading),
                    GridItem(.fixed(88), alignment: .leading),
                    GridItem(.flexible(), alignment: .leading),
                ],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(rows) { row in
                    Text(row.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(row.value)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 26)
    }

    private struct Fact: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    private func factRows(_ track: Track) -> [Fact] {
        var rows: [Fact] = []
        rows.append(Fact(label: "时长", value: track.durationText))
        if let quality = deliveredQualityText {
            rows.append(Fact(label: "音质", value: quality))
        }
        if let date = model.trackDetail?.releaseDate, !date.isEmpty {
            rows.append(Fact(label: "发行时间", value: date))
        }
        if let genre = model.trackDetail?.genre, !genre.isEmpty {
            rows.append(Fact(label: "流派", value: genre))
        }
        if let language = model.trackDetail?.language, !language.isEmpty {
            rows.append(Fact(label: "语种", value: language))
        }
        if let company = model.trackDetail?.company, !company.isEmpty {
            rows.append(Fact(label: "唱片公司", value: company))
        }
        if !track.album.isEmpty {
            rows.append(Fact(label: "专辑", value: track.album))
        }
        if let composer = track.composer, !composer.isEmpty {
            rows.append(Fact(label: "作曲", value: composer))
        }
        if let work = track.work, !work.isEmpty {
            rows.append(Fact(label: "作品", value: work))
        }
        if let disc = track.disc, !disc.isEmpty {
            rows.append(Fact(label: "碟", value: disc))
        }
        return rows
    }

    /// The quality actually delivered, with its file size when the platform reported one. Both come
    /// from what the player already knows, so this row appears without an extra request.
    private var deliveredQualityText: String? {
        guard let quality = player.deliveredQuality else { return nil }
        if let option = player.availableQualities.first(where: { $0.quality == quality }) {
            return "\(quality.label) · \(option.sizeText)"
        }
        return quality.label
    }
}
