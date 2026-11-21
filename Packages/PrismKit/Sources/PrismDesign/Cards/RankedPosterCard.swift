import SwiftUI

/// Top 10 poster: large white rank number inside the top-leading corner, optional genre
/// centred at the bottom over a soft gradient.
public struct RankedPosterCard<MenuContent: View>: View {
    private let rank: Int
    private let imageURL: URL?
    private let seed: String
    private let title: String
    private let genre: String?
    private let width: CGFloat?
    private let action: (() -> Void)?
    private let menu: MenuContent
    @Environment(\.prismCardWidth) private var shelfWidth

    public init(
        rank: Int,
        imageURL: URL?,
        seed: String? = nil,
        title: String,
        genre: String? = nil,
        width: CGFloat? = nil,
        action: (() -> Void)? = nil,
        @ViewBuilder menu: () -> MenuContent
    ) {
        self.rank = rank
        self.imageURL = imageURL
        self.seed = seed ?? title
        self.title = title
        self.genre = genre
        self.width = width
        self.action = action
        self.menu = menu()
    }

    public var body: some View {
        let w = width ?? shelfWidth ?? PrismMetrics.posterWidth
        let size = CGSize(width: w, height: (w / PrismMetrics.posterAspectRatio).rounded())
        CardContainer(accessibilityLabel: Text("Numéro \(rank), \(title)"), action: action, menu: menu) { _ in
            ArtworkSurface(radius: PrismMetrics.posterRadius) {
                RemoteImage(url: imageURL, size: size, placeholderSeed: seed, placeholderTitle: title)
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [.black.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: size.height * 0.3)
                    }
                    .overlay(alignment: .bottom) {
                        if genre != nil {
                            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                                .frame(height: size.height * 0.3)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        Text(rank, format: .number)
                            .font(PrismFont.rankNumber)
                            .tracking(PrismFont.rankNumberTracking)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                            .padding(.leading, 12)
                            .padding(.top, 4)
                    }
                    .overlay(alignment: .bottom) {
                        if let genre {
                            Text(genre)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.82))
                                .lineLimit(1)
                                .padding(.bottom, 9)
                        }
                    }
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

extension RankedPosterCard where MenuContent == EmptyView {
    public init(rank: Int, imageURL: URL?, seed: String? = nil, title: String, genre: String? = nil, width: CGFloat? = nil, action: (() -> Void)? = nil) {
        self.init(rank: rank, imageURL: imageURL, seed: seed, title: title, genre: genre, width: width, action: action) { EmptyView() }
    }
}

#Preview("RankedPosterCard") {
    HStack(spacing: 20) {
        ForEach(1...4, id: \.self) { rank in
            RankedPosterCard(rank: rank, imageURL: nil, title: ["Silo", "Severance", "Slow Horses", "Pluribus"][rank - 1], genre: "Thriller")
        }
    }
    .padding(40)
}
