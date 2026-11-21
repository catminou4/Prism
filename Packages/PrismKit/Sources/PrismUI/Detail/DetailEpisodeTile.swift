import PrismCore
import PrismDesign
import SwiftUI

struct DetailEpisodeTile: View {
    @Environment(\.prismCardWidth) private var cardWidth
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
    private var accessibleName: String {
        let location = episode.season > 0 ? "Saison \(episode.season), épisode \(episode.number)" : "Épisode spécial \(episode.number)"
        let duration = minutes.map { $0 == 1 ? "1 minute" : "\($0) minutes" }
        return [location, title, duration].compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        let width = cardWidth ?? 252
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 0) {
                image(width: width)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Épisode \(episode.number)")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        if let minutes {
                            Text("\(minutes) min")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(metadata?.overview ?? episode.plot ?? "")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                }
                .padding(13)
            }
            .frame(width: width, alignment: .leading)
            .background(PrismColors.panelFill)
            .clipShape(.rect(cornerRadius: PrismMetrics.wideRadius))
            .overlay {
                RoundedRectangle(cornerRadius: PrismMetrics.wideRadius)
                    .strokeBorder(.primary.opacity(0.09), lineWidth: 1)
            }
        }
        .buttonStyle(CardButtonStyle(hoverScale: 1.025))
        .accessibilityLabel(accessibleName)
        .accessibilityValue(watched ? "Vu" : progress.map { $0.fraction.formatted(.percent.precision(.fractionLength(0))) + " regardé" } ?? "")
        .accessibilityHint("Lancer la lecture")
        .help(title)
    }

    private func image(width: CGFloat) -> some View {
        let size = CGSize(width: width, height: (width / PrismMetrics.wideAspectRatio).rounded())
        return RemoteImage(
            url: metadata?.stillURL ?? episode.stillURL ?? artwork, size: size,
            placeholderSeed: episode.id.rawValue, showsPlaceholder: false
        )
        .background {
            ZStack {
                Rectangle().fill(Color(white: 0.14))
                Image(systemName: "play.rectangle")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.white.opacity(0.48))
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let progress, !watched && progress.fraction > 0 {
                ProgressCapsule(fraction: progress.fraction, width: width - 24, height: 3)
                    .shadow(color: .black.opacity(0.55), radius: 4)
                    .padding(12)
            }
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
