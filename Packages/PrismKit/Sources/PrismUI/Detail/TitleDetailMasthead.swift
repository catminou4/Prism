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
    @State private var failedArtwork: Set<URL> = []

    private let ink = Color(white: 0.045)
    private var displayTitle: String {
        if let name = metadata?.title, !name.isEmpty { return name }
        return title.title
    }
    private var availableBackdrop: URL? {
        guard let backdrop, !failedArtwork.contains(backdrop) else { return nil }
        return backdrop
    }
    private var availablePoster: URL? {
        [metadata?.images.posterURL, title.posterURL].compactMap { $0 }.first { !failedArtwork.contains($0) }
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let textWidth = min(430, size.width * 0.60)
            ZStack(alignment: .bottomLeading) {
                artwork(size: size)
                VStack(alignment: .leading, spacing: 10) {
                    titleLine
                    if !facts.isEmpty {
                        Text(facts.joined(separator: "  ·  "))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(2)
                    }
                    if let plot {
                        ExpandableText(
                            plot, lineLimit: 2, font: .system(size: 14), moreTitle: "Plus",
                            popoverTitle: "Synopsis", lineSpacing: 2
                        )
                        .foregroundStyle(.white.opacity(0.88))
                    }
                    actions
                        .padding(.top, 5)
                }
                .frame(width: textWidth, alignment: .leading)
                .padding(.leading, 40)
                .padding(.bottom, 38)
            }
        }
        .frame(height: height)
        .clipShape(.rect(cornerRadius: PrismMetrics.heroRadius))
        .task(id: isPageActive && !reduceMotion && availableBackdrop != nil) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { drift = false }
            guard isPageActive, !reduceMotion, availableBackdrop != nil else { return }
            // Yield after clearing the previous transaction so the first animation has a start state.
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 15).repeatForever(autoreverses: true)) { drift = true }
        }
    }

    @ViewBuilder private var titleLine: some View {
        if let logo = metadata?.images.logoURL {
            TitleLogo(url: logo, fallbackTitle: displayTitle, maxSize: CGSize(width: 380, height: 100))
        } else {
            Text(displayTitle)
                .font(.system(size: 53, weight: .bold))
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
            playLabel, systemImage: "play.fill", progress: progress, height: 39, minWidth: 118, action: play
        )
        .disabled(!canPlay)
    }

    private var watchlistButton: some View {
        WatchlistButton(isAdded: isInWatchlist, size: 39, action: toggleWatchlist)
    }

    private func editionButton(_ edition: TitleEdition) -> some View {
        GlassCapsuleButton(
            title: editionCount > 1 ? "\(editionCount) éditions" : edition.source.name,
            systemImage: "rectangle.on.rectangle",
            trailingChevron: false,
            action: showEditions
        )
        .disabled(!canPlay)
        .accessibilityLabel("Sources et langues")
        .accessibilityValue(editionCount > 1 ? "\(editionCount) éditions" : edition.source.name)
        .help("Source actuelle : \(edition.source.name) · \(edition.edition.title)")
    }

    private func artwork(size: CGSize) -> some View {
        ZStack(alignment: .trailing) {
            ink
            if let backdrop = availableBackdrop {
                let artSize = CGSize(width: size.width, height: size.height)
                RemoteImage(
                    url: backdrop, size: artSize, placeholderSeed: title.id.rawValue, showsPlaceholder: false,
                    onLoadFailure: { failedArtwork.insert(backdrop) }
                )
                .scaleEffect(drift ? 1.045 : 1, anchor: .trailing)
            } else if let poster = availablePoster {
                let artSize = CGSize(width: size.width * 0.72, height: size.height)
                RemoteImage(
                    url: poster, size: artSize,
                    placeholderSeed: title.id.rawValue, blurRadius: 28, showsPlaceholder: false
                )
                .opacity(0.44)
                .mask {
                    LinearGradient(colors: [.clear, .white], startPoint: .leading, endPoint: .trailing)
                }
                let posterHeight = size.height * 0.68
                RemoteImage(
                    url: poster,
                    size: CGSize(width: posterHeight * PrismMetrics.posterAspectRatio, height: posterHeight),
                    placeholderSeed: title.id.rawValue, showsPlaceholder: false,
                    onLoadFailure: { failedArtwork.insert(poster) }
                )
                .clipShape(.rect(cornerRadius: PrismMetrics.posterRadius))
                .padding(.trailing, size.width * 0.105)
            } else {
                LinearGradient(colors: [ink, Color(white: 0.16)], startPoint: .bottomLeading, endPoint: .topTrailing)
            }

            LinearGradient(
                stops: [
                    .init(color: ink.opacity(0.92), location: 0),
                    .init(color: ink.opacity(0.48), location: 0.34),
                    .init(color: .clear, location: 0.73),
                ],
                startPoint: .leading, endPoint: .trailing
            )
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.44),
                    .init(color: ink.opacity(0.78), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
