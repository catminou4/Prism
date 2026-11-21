import SwiftUI

/// Episode card (Apple TV `23_show2_s1`): the still fills the top, the lower part melts into
/// a blurred, darkened copy that carries `ÉPISODE 1`, the title, a 3-line synopsis and
/// `30 min  ⋯`.
public struct EpisodeCard<MenuContent: View>: View {
    private let stillURL: URL?
    private let seed: String
    private let eyebrow: String
    private let title: String
    private let synopsis: String?
    private let duration: String?
    private let progress: Double?
    private let isWatched: Bool
    private let width: CGFloat?
    private let action: (() -> Void)?
    private let menu: MenuContent
    @Environment(\.prismCardWidth) private var shelfWidth

    public init(
        stillURL: URL?,
        seed: String? = nil,
        eyebrow: String,
        title: String,
        synopsis: String? = nil,
        duration: String? = nil,
        progress: Double? = nil,
        isWatched: Bool = false,
        width: CGFloat? = nil,
        action: (() -> Void)? = nil,
        @ViewBuilder menu: () -> MenuContent
    ) {
        self.stillURL = stillURL
        self.seed = seed ?? "\(eyebrow) \(title)"
        self.eyebrow = eyebrow
        self.title = title
        self.synopsis = synopsis
        self.duration = duration
        self.progress = progress
        self.isWatched = isWatched
        self.width = width
        self.action = action
        self.menu = menu()
    }

    private var resolvedWidth: CGFloat { width ?? shelfWidth ?? PrismMetrics.episodeCardWidth }

    /// Card height for a given width.
    public static func height(forWidth width: CGFloat) -> CGFloat {
        (width / PrismMetrics.wideAspectRatio).rounded() + PrismMetrics.episodeTextBlock
    }

    public var body: some View {
        let w = resolvedWidth
        let artworkHeight = (w / PrismMetrics.wideAspectRatio).rounded()
        let size = CGSize(width: w, height: Self.height(forWidth: w))
        CardContainer(accessibilityLabel: accessibilityText, action: action, menu: menu) { isHovered in
            ArtworkSurface(radius: PrismMetrics.wideRadius) {
                ExtendedArtwork(url: stillURL, seed: seed, title: nil, size: size, artworkHeight: artworkHeight, meltStart: 0.62, darkening: 0.16)
                    .overlay {
                        LinearGradient(
                            stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.22), location: 1)],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
                    .overlay(alignment: .topTrailing) {
                        if isWatched {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.black, .white)
                                .font(.system(size: 18))
                                .padding(10)
                                .shadow(color: .black.opacity(0.3), radius: 3)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        textBlock(isHovered: isHovered)
                            .frame(width: w, height: size.height - artworkHeight + 18, alignment: .topLeading)
                            .offset(y: artworkHeight - 18)
                    }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    private func textBlock(isHovered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(eyebrow.uppercased())
                .font(PrismFont.episodeEyebrow)
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
            Text(title)
                .font(PrismFont.episodeTitle)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.top, 1)
            if let synopsis {
                Text(synopsis)
                    .font(PrismFont.episodeBody)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(3)
                    .lineSpacing(-0.5)
                    .padding(.top, 3)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if progress != nil || isWatched {
                    Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                }
                if let progress, !isWatched {
                    ProgressCapsule(fraction: progress, width: 22, height: 4).padding(.trailing, 2)
                }
                if let duration {
                    Text(duration)
                        .font(PrismFont.episodeDuration)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if MenuContent.self != EmptyView.self {
                    CardMenuButton(isHovered: isHovered, menu: menu)
                        .padding(.trailing, -6)
                }
            }
            .foregroundStyle(.white.opacity(0.9))
            .frame(height: 18)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 9)
    }

    private var accessibilityText: Text {
        var parts = [eyebrow, title]
        if let duration { parts.append(duration) }
        if isWatched { parts.append("Vu") } else if let progress { parts.append("\(Int((progress * 100).rounded())) % regardé") }
        if let synopsis { parts.append(synopsis) }
        return Text(parts.joined(separator: ", "))
    }
}

extension EpisodeCard where MenuContent == EmptyView {
    public init(
        stillURL: URL?,
        seed: String? = nil,
        eyebrow: String,
        title: String,
        synopsis: String? = nil,
        duration: String? = nil,
        progress: Double? = nil,
        isWatched: Bool = false,
        width: CGFloat? = nil,
        action: (() -> Void)? = nil
    ) {
        self.init(stillURL: stillURL, seed: seed, eyebrow: eyebrow, title: title, synopsis: synopsis, duration: duration, progress: progress, isWatched: isWatched, width: width, action: action) { EmptyView() }
    }
}

#Preview("EpisodeCard") {
    HStack(alignment: .top, spacing: 20) {
        EpisodeCard(
            stillURL: nil, eyebrow: "Épisode 1", title: "Pilote",
            synopsis: "Un entraîneur de football américain est engagé pour diriger une équipe anglaise de football.",
            duration: "30 min", width: 215
        ) {} menu: { Button("Marquer comme vu") {} }
        EpisodeCard(stillURL: nil, eyebrow: "Épisode 2", title: "Biscuits", synopsis: "Premier jour.", duration: "29 min", progress: 0.4, width: 215)
        EpisodeCard(stillURL: nil, eyebrow: "Épisode 3", title: "Trent Crimm : The Independent", duration: "30 min", isWatched: true, width: 215)
    }
    .padding(40)
}
