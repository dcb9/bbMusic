import SwiftUI

/// Adaptive card grid used for playlists, albums and search results.
///
/// One card size (120pt artwork) that reflows as the window widens, rather than a fixed column count
/// that either wastes space or clips.
struct CardGrid<Item: Identifiable, Content: View>: View {
    let items: [Item]
    var minimumWidth: CGFloat = 120
    /// Called when the last card comes into view; nil disables infinite scrolling.
    var onReachEnd: (() -> Void)?
    @ViewBuilder let content: (Item) -> Content

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: minimumWidth, maximum: minimumWidth * 1.6), spacing: 16, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(items) { item in
                    content(item)
                }
                if let onReachEnd {
                    // Sentinel: LazyVGrid only builds cards near the viewport, so this appearing
                    // means the user scrolled to the bottom.
                    Color.clear
                        .frame(height: 1)
                        .onAppear { onReachEnd() }
                }
            }
            .padding(16)
        }
    }
}

/// A single artwork card: large square image, title, subtitle.
struct MediaCard: View {
    let title: String
    let subtitle: String
    let artworkURL: URL?
    var badge: String?
    var placeholderSymbol: String = "music.note"
    var side: CGFloat = 120
    var isSelected: Bool = false
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Metrics.cardCornerRadius)
                    .fill(Color.primary.opacity(0.08))
                if let artworkURL {
                    AsyncImage(url: artworkURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else if phase.error != nil {
                            Image(systemName: placeholderSymbol)
                                .font(.system(size: 24))
                                .foregroundStyle(.tertiary)
                        } else {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cardCornerRadius))
                } else {
                    // No artwork at all: show the placeholder straight away rather than a spinner
                    // that would never resolve.
                    Image(systemName: placeholderSymbol)
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: side, height: side)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.cardCornerRadius)
                    .stroke(isSelected ? palette.accent : Color.clear, lineWidth: 2)
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(width: side, alignment: .leading)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(width: side, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
    }
}
