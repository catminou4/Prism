import Foundation
import PrismCore
import PrismDesign
import SwiftUI

/// What the immersive playback sheet shows above the edition picker: artwork, eyebrow,
/// title (or logo), facts line and synopsis — for a film or for one episode.
struct PlaybackSheetHero {
    var eyebrow: String
    var name: String
    var logo: URL?
    var details: [String]
    var rating: String?
    var runtimeSeconds: Int?
    var synopsisCandidates: [String?]
    /// Landscape artwork, best first; the poster is the blurred last resort.
    var landscapes: [URL]
    var poster: URL?
    var seed: String

    private static let locale = Locale(identifier: "fr-FR")

    static func episode(_ episode: Episode, metadata: TMDBEpisodeInfo?, backdrop: URL?, poster: URL?) -> Self {
        let names = [metadata?.title, episode.title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let seconds = metadata?.runtimeMinutes.flatMap { $0 > 0 ? $0 * 60 : nil }
            ?? episode.durationSeconds.flatMap { $0 > 0 ? $0 : nil }
        let date = episode.airDate.map {
            $0.formatted(.dateTime.day().month(.wide).year().locale(locale))
        }
        return Self(
            eyebrow: episode.season > 0
                ? "Saison \(episode.season) · Épisode \(episode.number)"
                : "Épisode spécial \(episode.number)",
            name: names.first { !$0.isEmpty } ?? "Épisode \(episode.number)",
            details: [seconds.map { "\(max(1, $0 / 60)) min" }, date].compactMap { $0 },
            rating: formattedRating([metadata?.voteAverage, episode.rating]),
            runtimeSeconds: seconds,
            synopsisCandidates: [metadata?.overview, episode.plot],
            landscapes: [metadata?.stillURL, episode.stillURL, backdrop].compactMap { $0 },
            poster: poster,
            seed: episode.id.rawValue
        )
    }

    static func title(
        _ title: MediaTitle, facts: [String], plot: String?, rating: Double?, runtimeMinutes: Int?,
        backdrop: URL?, poster: URL?, logo: URL?
    ) -> Self {
        Self(
            eyebrow: title.kind == .series ? "Série" : "Film",
            name: title.title,
            logo: logo,
            details: facts,
            rating: formattedRating([rating]),
            runtimeSeconds: runtimeMinutes.flatMap { $0 > 0 ? $0 * 60 : nil },
            synopsisCandidates: [plot, title.plot],
            landscapes: [backdrop].compactMap { $0 },
            poster: poster ?? title.posterURL,
            seed: title.id.rawValue
        )
    }

    private static func formattedRating(_ candidates: [Double?]) -> String? {
        candidates.compactMap { $0 }.first { $0 > 0 && $0 <= 10 }
            .map { $0.formatted(.number.precision(.fractionLength(1)).locale(locale)) }
    }
}

/// Full-bleed artwork over an ambient, blurred copy of the same image — the sheet's
/// background. Falls back through the landscape candidates, then a blurred poster, then a gradient.
struct PlaybackSheetBackdrop: View {
    let hero: PlaybackSheetHero
    let size: CGSize
    let heroHeight: CGFloat

    @State private var failed: Set<URL> = []

    var body: some View {
        let landscape = hero.landscapes.first { !failed.contains($0) }
        let poster = hero.poster.flatMap { failed.contains($0) ? nil : $0 }
        let ambient = landscape ?? poster
        let heroSize = CGSize(width: size.width, height: heroHeight)
        ZStack(alignment: .top) {
            Color(white: 0.05)
            if let ambient {
                RemoteImage(url: ambient, size: size, placeholderSeed: hero.seed, blurRadius: 60, showsPlaceholder: false)
                    .opacity(0.55)
                    .id(ambient)
            }
            // Darken the ambient wash so the edition tiles stay legible on any artwork.
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)

            Group {
                if let landscape {
                    RemoteImage(url: landscape, size: heroSize, placeholderSeed: hero.seed, showsPlaceholder: false,
                                onLoadFailure: { failed.insert(landscape) })
                        .id(landscape)
                } else if let poster {
                    RemoteImage(url: poster, size: heroSize, placeholderSeed: hero.seed, blurRadius: 24,
                                showsPlaceholder: false, onLoadFailure: { failed.insert(poster) })
                        .id(poster)
                } else {
                    PlaceholderArtwork(seed: hero.seed, style: .none)
                }
            }
            .frame(width: heroSize.width, height: heroSize.height)
            .clipped()
            .overlay {
                // Legibility scrims: leading + bottom for the text block, top for the toolbar.
                LinearGradient(
                    stops: [.init(color: .black.opacity(0.8), location: 0), .init(color: .black.opacity(0.45), location: 0.4),
                            .init(color: .black.opacity(0), location: 0.72)],
                    startPoint: .leading, endPoint: .trailing
                )
                LinearGradient(
                    stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.65), location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.25))
            }
            .mask {
                LinearGradient(
                    stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.55), .init(color: .clear, location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// One playable edition in the playback sheet: language, optional source/duplicate line, tech badges.
struct PlaybackEditionTile: View {
    static let size = CGSize(width: 212, height: 100)

    let option: TitlePlaybackOption
    let selected: Bool
    let focused: Bool
    let duplicateNumber: Int?
    let showsSource: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    private var subtitle: String? {
        let parts = [showsSource ? option.titleEdition.source.name : nil, duplicateNumber.map { "Édition \($0)" }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var badges: [String] {
        option.label.components(separatedBy: " · ").filter { !$0.isEmpty }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(option.titleEdition.edition.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(selected ? Color.white : Color.white.opacity(0.32))
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .accessibilityHidden(true)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .padding(.top, 3)
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    ForEach(badges.indices, id: \.self) { index in
                        MediaBadge(automatic: badges[index])
                    }
                }
                .foregroundStyle(.white.opacity(selected ? 0.9 : 0.7))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
            .background(Color.white.opacity(selected ? 0.20 : hovered ? 0.12 : 0.07), in: shape)
            .overlay {
                shape.strokeBorder(stroke, lineWidth: selected || focused ? 1.5 : 1)
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
            .scaleEffect(reduceMotion ? 1 : (hovered ? 1.03 : 1))
        }
        .buttonStyle(PressableButtonStyle())
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .animation(PrismMotion.respecting(reduceMotion, PrismMotion.hover), value: hovered)
        .animation(PrismMotion.respecting(reduceMotion, .easeOut(duration: 0.16)), value: selected)
        .accessibilityLabel(option.titleEdition.edition.title)
        .accessibilityValue(
            [subtitle, option.titleEdition.source.name, option.label]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(option.titleEdition.variant.rawName)
    }

    private var stroke: Color {
        if focused { return .accentColor }
        return selected ? .white.opacity(0.85) : .white.opacity(0.08)
    }
}
