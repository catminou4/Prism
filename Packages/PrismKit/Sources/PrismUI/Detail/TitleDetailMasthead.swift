import PrismCore
import PrismDesign
import SwiftUI

struct TitleDetailMasthead: View {
    let title: MediaTitle
    let height: CGFloat
    let metadata: TMDBMetadata?
    let backdrops: [URL]
    let posters: [URL]
    let plot: String?
    let facts: [String]
    let quality: String?
    let playLabel: String
    let progress: Double?
    let canPlay: Bool
    let isInWatchlist: Bool
    let edition: TitleEdition?
    let editionCount: Int
    let play: () -> Void
    let toggleWatchlist: () -> Void
    let showEditions: () -> Void

    private var displayTitle: String {
        let name = metadata?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty { return name }
        return title.title
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let textWidth = min(530, size.width * 0.62)
            ZStack(alignment: .bottomLeading) {
                HeroBackdrop(
                    backdropURLs: backdrops, seed: title.id.rawValue, fallbackPosterURLs: posters,
                    leadingScrim: 0.78, extendsUnderSidebar: true, artSize: size
                )
                .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 12) {
                    TitleLogo(
                        url: metadata?.images.logoURL, fallbackTitle: displayTitle,
                        maxSize: CGSize(width: min(400, textWidth), height: 112)
                    )
                    if !facts.isEmpty || quality != nil {
                        HStack(spacing: 9) {
                            Text(facts.joined(separator: "  ·  "))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.82))
                                .lineLimit(2)
                            if let quality {
                                MediaBadge(quality, style: .filled)
                            }
                        }
                    }
                    if let plot {
                        ExpandableText(
                            plot, lineLimit: 2, font: .system(size: 14), moreTitle: "Plus",
                            popoverTitle: "Synopsis", lineSpacing: 3
                        )
                        .foregroundStyle(.white.opacity(0.91))
                    }
                    actions
                        .padding(.top, 6)
                }
                .frame(width: textWidth, alignment: .leading)
                .padding(.leading, PrismMetrics.contentMargin)
                .padding(.bottom, 44)
            }
        }
        .frame(height: height)
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear, PrismColors.pageBackground], startPoint: .top, endPoint: .bottom)
                .frame(height: 30)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                playButton
                watchlistButton
                if let edition { editionButton(edition) }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    playButton
                    watchlistButton
                }
                if let edition { editionButton(edition) }
            }
        }
    }

    private var playButton: some View {
        PrimaryCapsuleButton(
            playLabel, systemImage: "play.fill", progress: progress, height: 40, minWidth: 120, action: play
        )
        .disabled(!canPlay)
    }

    private var watchlistButton: some View {
        WatchlistButton(isAdded: isInWatchlist, size: 40, action: toggleWatchlist)
    }

    private func editionButton(_ edition: TitleEdition) -> some View {
        GlassCapsuleButton(
            title: editionCount > 1 ? "Sources et langues" : edition.source.name,
            systemImage: "rectangle.on.rectangle",
            trailingChevron: editionCount > 1,
            action: showEditions
        )
        .disabled(!canPlay)
        .accessibilityLabel("Sources et langues")
        .accessibilityValue(editionCount > 1 ? "\(editionCount) éditions" : edition.source.name)
        .help("Source actuelle : \(edition.source.name) · \(edition.edition.title)")
    }
}
