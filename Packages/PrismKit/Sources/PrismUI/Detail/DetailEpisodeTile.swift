import PrismCore
import PrismDesign
import SwiftUI

struct DetailEpisodeTile: View {
    @Environment(\.prismCardWidth) private var cardWidth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var plot: String?
    let episode: Episode
    let metadata: TMDBEpisodeInfo?
    let artwork: URL?
    let progress: PlaybackProgress?
    let watched: Bool
    let onPlay: () -> Void

    private var title: String { metadata?.title ?? episode.title }
    private var minutes: Int? {
        metadata?.runtimeMinutes ?? episode.durationSeconds.flatMap { $0 > 0 ? max(1, $0 / 60) : nil }
    }
    private var rating: DetailRating? {
        DetailRating.preferred(tmdb: metadata?.voteAverage, voteCount: metadata?.voteCount, provider: [episode.rating])
    }
    private var accessibleName: String {
        let location = episode.season > 0 ? "Saison \(episode.season), épisode \(episode.number)" : "Épisode spécial \(episode.number)"
        let duration = minutes.map { $0 == 1 ? "1 minute" : "\($0) minutes" }
        return [location, title, duration, rating?.accessibleDescription].compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        let width = cardWidth ?? 252
        let artworkHeight = (width / PrismMetrics.wideAspectRatio).rounded()
        let size = CGSize(width: width, height: artworkHeight + 101)
        let imageSize = CGSize(width: width, height: artworkHeight + 31)
        Button(action: onPlay) {
            ZStack(alignment: .topLeading) {
                Color(white: 0.10)
                if let stillURL {
                    RemoteImage(
                        url: stillURL, size: size, placeholderSeed: episode.id.rawValue,
                        blurRadius: 24, showsPlaceholder: false
                    )
                    .blursArtwork(sized: imageSize)
                    .opacity(0.28)
                    .accessibilityHidden(true)
                }
                image(size: imageSize)
                caption
                    .padding(.horizontal, 13)
                    .padding(.bottom, 14)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(.rect(cornerRadius: PrismMetrics.wideRadius))
            .overlay {
                RoundedRectangle(cornerRadius: PrismMetrics.wideRadius)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(CardButtonStyle(hoverScale: 1.025))
        .accessibilityLabel(accessibleName)
        .accessibilityValue(watched ? "Vu" : progress.map { $0.fraction.formatted(.percent.precision(.fractionLength(0))) + " regardé" } ?? "")
        .accessibilityHint("Afficher l’épisode et les options de lecture")
        .help(title)
        .task(id: [metadata?.overview, episode.plot]) {
            let synopsis = await DetailPresentation.synopsis([metadata?.overview, episode.plot])
            if !Task.isCancelled { plot = synopsis }
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Épisode \(episode.number)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.68))
                .textCase(.uppercase)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(plot ?? "")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                if let minutes { Text("\(minutes) min") }
                if let progress, !watched, progress.fraction > 0 {
                    ProgressCapsule(fraction: progress.fraction, width: 34, height: 3)
                }
                Spacer(minLength: 6)
                if let rating {
                    Label("\(rating.formatted) / 10", systemImage: "star.fill")
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText(value: rating.value))
                        .transition(.opacity)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.77))
            .frame(height: 15)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: rating)
        }
    }

    private var stillURL: URL? { metadata?.stillURL ?? episode.stillURL ?? artwork }

    private func image(size: CGSize) -> some View {
        RemoteImage(
            url: stillURL, size: size,
            placeholderSeed: episode.id.rawValue, showsPlaceholder: false
        )
        .background {
            ZStack {
                Rectangle().fill(Color(white: 0.16))
                Image(systemName: "play.rectangle")
                    .font(.system(size: 25, weight: .regular))
                    .foregroundStyle(.white.opacity(0.34))
            }
        }
        .mask {
            LinearGradient(
                stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.48), .init(color: .clear, location: 1)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .overlay(alignment: .topTrailing) {
            if watched {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(.black.opacity(0.65), in: .circle)
                    .padding(10)
            }
        }
        .accessibilityHidden(true)
    }
}
