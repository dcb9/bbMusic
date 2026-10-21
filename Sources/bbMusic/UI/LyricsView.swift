import SwiftUI

/// Lyrics replace the list area (the sidebar and player bar stay put), per the accepted design.
/// The current line is highlighted; translations sit directly beneath their line.
struct LyricsView: View {
    @ObservedObject var player: Player
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    onBack()
                } label: {
                    Label("列表", systemImage: "chevron.left")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Text(player.currentTrack?.title ?? "歌词")
                    .font(.system(size: 13, weight: .semibold))
                if let track = player.currentTrack {
                    Text(track.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            Divider()

            if player.lyrics.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                    Text("这首歌没有歌词")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("可能还没有上传歌词，或者接口暂时取不到。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                scrollingLyrics
            }
        }
    }

    private var currentIndex: Int {
        let time = player.currentTime
        // Last line whose timestamp is at or before now.
        var result = 0
        for (index, line) in player.lyrics.lines.enumerated() where line.time <= time {
            result = index
        }
        return result
    }

    private var scrollingLyrics: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(Array(player.lyrics.lines.enumerated()), id: \.offset) { index, line in
                        VStack(spacing: 3) {
                            Text(line.text)
                                .font(.system(size: index == currentIndex ? 14 : 12,
                                              weight: index == currentIndex ? .semibold : .regular))
                                .foregroundStyle(index == currentIndex ? .primary : .secondary)
                                .multilineTextAlignment(.center)
                            if let translation = line.translation, !translation.isEmpty {
                                Text(translation)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 30)
                        .id(index)
                    }
                }
                .padding(.vertical, 24)
            }
            .onChange(of: currentIndex) { _, index in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
    }
}
