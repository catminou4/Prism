import SwiftUI

/// 2:3 poster (films, séries). Title/subtitle below only in grids (`showsTitle`).
public struct PosterCard<MenuContent: View>: View {
    private let imageURL: URL?
    private let seed: String
    private let title: String
    private let subtitle: String?
    private let showsTitle: Bool
    private let badge: String?
    private let rank: Int?
    private let progress: Double?
    private let width: CGFloat?
    private let action: (() -> Void)?
    private let menu: MenuContent
    @Environment(\.prismCardWidth) private var shelfWidth

    public init(
        imageURL: URL?,
        seed: String? = nil,
        title: String,
        subtitle: String? = nil,
        showsTitle: Bool = false,
        badge: String? = nil,
        rank: Int? = nil,
        progress: Double? = nil,
        width: CGFloat? = nil,
        action: (() -> Void)? = nil,
        @ViewBuilder menu: () -> MenuContent
    ) {
        self.imageURL = imageURL
        self.seed = seed ?? title
        self.title = title
        self.subtitle = subtitle
        self.showsTitle = showsTitle
        self.badge = badge
        self.rank = rank
        self.progress = progress
        self.width = width
        self.action = action
        self.menu = menu()
    }

    private var resolvedWidth: CGFloat { width ?? shelfWidth ?? PrismMetrics.posterWidth }

    public var body: some View {
        let w = resolvedWidth
        let artworkSize = CGSize(width: w, height: (w / PrismMetrics.posterAspectRatio).rounded())
        let label = [title, subtitle, rank.map { "Rang \($0)" }].compactMap { $0 }.joined(separator: ", ")
        CardContainer(accessibilityLabel: Text(label), action: action, menu: menu) { _ in
            VStack(alignment: .leading, spacing: 8) {
                ArtworkSurface(radius: PrismMetrics.posterRadius) {
                    artwork(size: artworkSize)
                }
                if showsTitle {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(PrismFont.cardTitle)
                            .foregroundStyle(.primary)
                        if let subtitle {
                            Text(subtitle)
                                .font(PrismFont.cardMeta)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .frame(width: w, alignment: .leading)
                }
            }
            .frame(width: w, alignment: .leading)
        }
    }

    @ViewBuilder private func artwork(size: CGSize) -> some View {
        let image = RemoteImage(url: imageURL, size: size, placeholderSeed: seed, placeholderTitle: showsTitle ? nil : title)
        if badge == nil, rank == nil, progress == nil {
            // The catalogue grid mounts plain posters as each row comes into view.
            image
        } else {
            image
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        MediaBadge(badge, style: .filled)
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(8)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let rank {
                        Text(rank, format: .number)
                            .font(.system(size: 21, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(minWidth: 34, minHeight: 30)
                            .background(.black.opacity(0.64), in: .capsule)
                            .padding(8)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let progress {
                        ProgressCapsule(fraction: progress, width: nil, height: 3)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 10)
                            .shadow(color: .black.opacity(0.4), radius: 3)
                    }
                }
        }
    }
}

extension PosterCard where MenuContent == EmptyView {
    public init(
        imageURL: URL?,
        seed: String? = nil,
        title: String,
        subtitle: String? = nil,
        showsTitle: Bool = false,
        badge: String? = nil,
        rank: Int? = nil,
        progress: Double? = nil,
        width: CGFloat? = nil,
        action: (() -> Void)? = nil
    ) {
        self.init(
            imageURL: imageURL, seed: seed, title: title, subtitle: subtitle, showsTitle: showsTitle,
            badge: badge, rank: rank, progress: progress, width: width, action: action
        ) { EmptyView() }
    }
}

#Preview("PosterCard") {
    HStack(alignment: .top, spacing: 20) {
        PosterCard(imageURL: nil, title: "Dune : Deuxième partie")
        PosterCard(imageURL: nil, title: "Slow Horses", subtitle: "2022", showsTitle: true, badge: "4K") {}
        PosterCard(imageURL: nil, title: "Foundation", progress: 0.4) {} menu: {
            Button("Ajouter à Ma liste", systemImage: "plus") {}
        }
    }
    .padding(40)
}
