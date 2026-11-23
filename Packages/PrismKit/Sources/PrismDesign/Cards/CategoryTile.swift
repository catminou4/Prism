import SwiftUI

/// Browse tile (genres, collections): artwork with a colour wash rising from the bottom and
/// a 15 pt bold title bottom-leading. Without artwork, a tint gradient (like `4K HDR`).
public struct CategoryTile: View {
    public enum Aspect: Sendable {
        /// 2:3 (Apple TV Browse).
        case poster
        /// 16:10 (genres in compact grids).
        case wide

        var ratio: CGFloat { self == .poster ? 2.0 / 3.0 : 16.0 / 10.0 }
    }

    private let title: String
    private let imageURL: URL?
    private let seed: String
    private let tint: Color?
    private let fallbackTint: Color
    private let aspect: Aspect
    private let width: CGFloat?
    private let action: (() -> Void)?
    @State private var sampledTint: Color?
    @Environment(\.prismCardWidth) private var shelfWidth

    public init(title: String, imageURL: URL? = nil, seed: String? = nil, tint: Color? = nil, aspect: Aspect = .poster, width: CGFloat? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.imageURL = imageURL
        self.seed = seed ?? title
        self.tint = tint
        fallbackTint = tint ?? PrismTint.forSeed(seed ?? title).color
        self.aspect = aspect
        self.width = width
        self.action = action
    }

    public var body: some View {
        let w = width ?? shelfWidth ?? PrismMetrics.categoryTileWidth
        let size = CGSize(width: w, height: (w / aspect.ratio).rounded())
        let wash = tint ?? sampledTint ?? fallbackTint
        CardContainer(accessibilityLabel: Text(title), action: action, menu: { EmptyView() }) { _ in
            ArtworkSurface(radius: PrismMetrics.tileRadius) {
                ZStack(alignment: .bottomLeading) {
                    if imageURL != nil {
                        RemoteImage(url: imageURL, size: size, placeholderSeed: seed, placeholderStyle: .none)
                        LinearGradient(
                            stops: [.init(color: wash.opacity(0), location: 0.45), .init(color: wash.opacity(0.85), location: 1)],
                            startPoint: .top, endPoint: .bottom
                        )
                    } else {
                        LinearGradient(
                            colors: [fallbackTint, fallbackTint.mix(with: Color(red: 0.45, green: 0.2, blue: 0.9), by: 0.6), Color(red: 0.72, green: 0.04, blue: 0.38)],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
                    LinearGradient(colors: [.clear, .black.opacity(0.25)], startPoint: .center, endPoint: .bottom)
                    Text(title)
                        .font(PrismFont.tileTitle)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 11)
                }
                .frame(width: size.width, height: size.height)
            }
        }
        .task(id: imageURL) {
            guard tint == nil, let imageURL else { return }
            if let color = await ImagePipeline.shared.averageColor(for: imageURL), !Task.isCancelled {
                sampledTint = color
            }
        }
    }
}

#Preview("CategoryTile") {
    HStack(spacing: 20) {
        CategoryTile(title: "4K HDR", tint: .blue)
        CategoryTile(title: "Action", seed: "action")
        CategoryTile(title: "Comédies", aspect: .wide, width: 220)
    }
    .padding(40)
}
