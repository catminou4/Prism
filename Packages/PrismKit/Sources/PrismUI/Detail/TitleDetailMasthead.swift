import PrismCore
import PrismDesign
import SwiftUI

struct TitleDetailMasthead: View {
    let title: MediaTitle
    let height: CGFloat
    let metadata: TMDBMetadata?
    let backdrop: URL?
    let plot: String?
    let facts: [String]
    let playLabel: String
    let progress: Double?
    let canPlay: Bool
    let isInWatchlist: Bool
    let edition: TitleEdition?
    let editionCount: Int
    let play: () -> Void
    let toggleWatchlist: () -> Void
    let showEditions: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isPageActive) private var isPageActive
    @State private var drift = false

    private let ink = Color(red: 0.045, green: 0.061, blue: 0.092)
    private let edge = Color.white.opacity(0.16)

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let textWidth = min(450, size.width * 0.59)
            ZStack(alignment: .bottomLeading) {
                artwork(size: size)
                VStack(alignment: .leading, spacing: 13) {
                    titleLine
                    if !facts.isEmpty {
                        Text(facts.joined(separator: "  ·  "))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(2)
                    }
                    if let plot {
                        ExpandableText(
                            plot, lineLimit: 3, font: .system(size: 15), moreTitle: "LIRE LA SUITE",
                            popoverTitle: "Synopsis", lineSpacing: 3
                        )
                        .foregroundStyle(.white.opacity(0.88))
                    }
                    actions
                        .padding(.top, 5)
                }
                .frame(width: textWidth, alignment: .leading)
                .padding(.leading, 28)
                .padding(.bottom, 29)
            }
        }
        .frame(height: height)
        .clipShape(.rect(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(edge, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .task(id: isPageActive && !reduceMotion && backdrop != nil) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { drift = false }
            guard isPageActive, !reduceMotion, backdrop != nil else { return }
            // Yield after clearing the previous transaction so the first animation has a start state.
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 15).repeatForever(autoreverses: true)) { drift = true }
        }
    }

    @ViewBuilder private var titleLine: some View {
        if let logo = metadata?.images.logoURL {
            TitleLogo(url: logo, fallbackTitle: title.title, maxSize: CGSize(width: 380, height: 100))
        } else {
            Text(title.title)
                .font(.system(size: 56, weight: .heavy))
                .tracking(-1.8)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.56)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                playButton
                watchlistButton
                if let edition, editionCount > 1 { editionButton(edition) }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    playButton
                    watchlistButton
                }
                if let edition, editionCount > 1 { editionButton(edition) }
            }
        }
    }

    private var playButton: some View {
        PrimaryCapsuleButton(
            playLabel, systemImage: "play.fill", progress: progress, height: 42, minWidth: 132, action: play
        )
        .disabled(!canPlay)
    }

    private var watchlistButton: some View {
        WatchlistButton(isAdded: isInWatchlist, size: 42, action: toggleWatchlist)
    }

    private func editionButton(_ edition: TitleEdition) -> some View {
        GlassCapsuleButton(
            title: "Éditions (\(editionCount))",
            tint: PrismTint(rawValue: edition.source.tint.rawValue)?.color,
            action: showEditions
        )
        .disabled(!canPlay)
        .help("Voir les langues, les qualités et les sources disponibles")
    }

    private func artwork(size: CGSize) -> some View {
        ZStack(alignment: .trailing) {
            ink
            if let backdrop {
                let artSize = CGSize(width: size.width * 0.81, height: size.height)
                RemoteImage(url: backdrop, size: artSize, placeholderSeed: title.id.rawValue, showsPlaceholder: false)
                    .scaleEffect(drift ? 1.045 : 1, anchor: .trailing)
                    .mask {
                        LinearGradient(
                            stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.38)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    }
            } else {
                let artSize = CGSize(width: size.width * 0.72, height: size.height)
                RemoteImage(
                    url: metadata?.images.posterURL ?? title.posterURL, size: artSize,
                    placeholderSeed: title.id.rawValue, placeholderStyle: .none, blurRadius: 28
                )
                .opacity(0.44)
                .mask {
                    LinearGradient(colors: [.clear, .white], startPoint: .leading, endPoint: .trailing)
                }
                let posterHeight = size.height * 0.68
                RemoteImage(
                    url: metadata?.images.posterURL ?? title.posterURL,
                    size: CGSize(width: posterHeight * PrismMetrics.posterAspectRatio, height: posterHeight),
                    placeholderSeed: title.id.rawValue, placeholderTitle: title.title
                )
                .clipShape(.rect(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(edge, lineWidth: 1) }
                .rotationEffect(.degrees(5))
                .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                .padding(.trailing, size.width * 0.105)
            }

            LinearGradient(
                stops: [
                    .init(color: ink, location: 0.13),
                    .init(color: ink.opacity(0.84), location: 0.43),
                    .init(color: ink.opacity(0), location: 0.75),
                ],
                startPoint: .leading, endPoint: .trailing
            )
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.48),
                    .init(color: ink.opacity(0.89), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
