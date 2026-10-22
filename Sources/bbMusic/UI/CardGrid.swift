import SwiftUI

/// Adaptive card grid used for playlists, albums and search results.
///
/// One card size (120pt artwork) that reflows as the window widens, rather than a fixed column count
/// that either wastes space or clips.
struct CardGrid<Item: Identifiable, Content: View>: View {
    let items: [Item]
    var minimumWidth: CGFloat = 120
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
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
                    .clipShape(RoundedRectangle(cornerRadius: 8))
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
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: side, alignment: .leading)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: side, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
    }
}
