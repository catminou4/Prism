import SwiftUI

/// Wide card (Continuer, bandes-annonces, chaînes): 16:9 artwork over a blurred caption band.
///
/// One-line layout: `[▶ ━━] caption … ⋯`. Two-line layout (caption + metadata):
/// caption on the first line, `[▶ ━━] metadata … ⋯` on the second.
public struct WideCard<MenuContent: View>: View {
    private let imageURL: URL?
    private let seed: String
    private let caption: String
    private let metadata: String?
    private let progress: Double?
    private let isLive: Bool
    private let logoURL: URL?
    private let showsPlayGlyph: Bool
    private let placeholderTitle: String?
    private let width: CGFloat?
    private let action: (() -> Void)?
    private let menu: () -> MenuContent
    private let accessibilityText: Text
    @Environment(\.prismCardWidth) private var shelfWidth

    public init(
        imageURL: URL?,
        seed: String? = nil,
        caption: String,
        metadata: String? = nil,
        progress: Double? = nil,
        isLive: Bool = false,
        logoURL: URL? = nil,
        showsPlayGlyph: Bool? = nil,
        placeholderTitle: String? = nil,
        width: CGFloat? = nil,
        action: (() -> Void)? = nil,
        @ViewBuilder menu: @escaping () -> MenuContent
    ) {
        self.placeholderTitle = placeholderTitle
        self.imageURL = imageURL
        self.seed = seed ?? caption
        self.caption = caption
        self.metadata = metadata
        self.progress = progress
        self.isLive = isLive
        self.logoURL = logoURL
        self.showsPlayGlyph = showsPlayGlyph ?? (progress != nil || metadata != nil)
        self.width = width
        self.action = action
        self.menu = menu
        var parts = [caption]
        if let metadata { parts.append(metadata) }
        if isLive { parts.append("En direct") }
        if let progress { parts.append("\(Int((progress * 100).rounded())) % regardé") }
        accessibilityText = Text(parts.joined(separator: ", "))
    }

    private var resolvedWidth: CGFloat { width ?? shelfWidth ?? PrismMetrics.wideCardWidth }

    /// Card height for a given width (use it to size skeletons/grids).
    public static func height(forWidth width: CGFloat, twoLines: Bool) -> CGFloat {
        (width / PrismMetrics.wideAspectRatio).rounded() + (twoLines ? 38 : PrismMetrics.wideCardCaptionBand)
    }

    public var body: some View {
        let w = resolvedWidth
        let twoLines = metadata != nil
        let artworkHeight = (w / PrismMetrics.wideAspectRatio).rounded()
        let size = CGSize(width: w, height: Self.height(forWidth: w, twoLines: twoLines))
        CardContainer(accessibilityLabel: accessibilityText, action: action, menu: menu) { isHovered in
            ArtworkSurface(radius: PrismMetrics.wideRadius) {
                ExtendedArtwork(url: imageURL, seed: seed, title: placeholderTitle, size: size, artworkHeight: artworkHeight, meltStart: twoLines ? 0.62 : 0.78)
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                            .frame(height: size.height * 0.5)
                    }
                    .overlay(alignment: .topLeading) {
                        if let logoURL {
                            RemoteImage(url: logoURL, size: CGSize(width: w * 0.28, height: 24), contentMode: .fit, placeholderSeed: seed, showsPlaceholder: false)
                                .shadow(color: .black.opacity(0.35), radius: 4)
                                .padding(10)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if isLive {
                            LiveBadge(pulsing: false, compact: true).padding(10)
                        }
                    }
                    .overlay(alignment: .bottom) { captionBlock(isHovered: isHovered, twoLines: twoLines) }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    private func captionBlock(isHovered: Bool, twoLines: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if twoLines {
                Text(caption)
                    .font(PrismFont.cardCaption)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.trailing, 12)
            }
            HStack(spacing: 6) {
                if showsPlayGlyph {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                }
                if let progress {
                    ProgressCapsule(fraction: progress, width: 22, height: 4)
                        .padding(.trailing, 2)
                }
                Text(twoLines ? (metadata ?? "") : caption)
                    .font(twoLines ? PrismFont.cardMeta.weight(.semibold) : PrismFont.cardCaption)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if MenuContent.self != EmptyView.self {
                    CardMenuButton(isHovered: isHovered, menu: menu)
                        .padding(.trailing, -6)
                }
            }
            .foregroundStyle(.white.opacity(twoLines ? 0.8 : 0.82))
            .frame(height: 16)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.bottom, twoLines ? 9 : 8)
    }
}

extension WideCard where MenuContent == EmptyView {
    public init(
        imageURL: URL?,
        seed: String? = nil,
        caption: String,
        metadata: String? = nil,
        progress: Double? = nil,
        isLive: Bool = false,
        logoURL: URL? = nil,
        showsPlayGlyph: Bool? = nil,
        placeholderTitle: String? = nil,
        width: CGFloat? = nil,
        action: (() -> Void)? = nil
    ) {
        self.init(imageURL: imageURL, seed: seed, caption: caption, metadata: metadata, progress: progress, isLive: isLive, logoURL: logoURL, showsPlayGlyph: showsPlayGlyph, placeholderTitle: placeholderTitle, width: width, action: action) { EmptyView() }
    }
}

#Preview("WideCard") {
    HStack(alignment: .top, spacing: 20) {
        WideCard(imageURL: nil, caption: "Dans Ma liste", showsPlayGlyph: false) {} menu: {
            Button("Retirer de Ma liste", systemImage: "minus.circle") {}
        }
        WideCard(imageURL: nil, caption: "S1, É1 · 23 min", progress: 0.35) {} menu: {
            Button("Marquer comme vu", systemImage: "checkmark") {}
        }
        WideCard(imageURL: nil, caption: "Bande-annonce 2", metadata: "2 min") {} menu: {
            Button("Partager", systemImage: "square.and.arrow.up") {}
        }
    }
    .padding(40)
}
