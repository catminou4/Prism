import Foundation
import PrismCore
import PrismDesign
import SwiftUI

/// What the playback sheet shows in its hero (artwork, eyebrow, title or logo, facts, synopsis)
/// and in its `Informations` column — for a film or for one episode.
struct PlaybackSheetHero {
    var eyebrow: String
    var name: String
    var logo: URL?
    var details: [String]
    var rating: String?
    var runtimeSeconds: Int?
    var synopsisCandidates: [String?]
    /// Landscape artwork, best first; the poster is the portrait fallback.
    var landscapes: [URL]
    var poster: URL?
    var seed: String
    var info: [InfoRow]

    private static let locale = Locale(identifier: "fr-FR")

    static func episode(
        _ episode: Episode, series: String, metadata: TMDBEpisodeInfo?, backdrop: URL?, poster: URL?
    ) -> Self {
        let names = [metadata?.title, episode.title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let seconds = metadata?.runtimeMinutes.flatMap { $0 > 0 ? $0 * 60 : nil }
            ?? episode.durationSeconds.flatMap { $0 > 0 ? $0 : nil }
        let duration = seconds.map { "\(max(1, $0 / 60)) min" }
        let date = episode.airDate.map {
            $0.formatted(.dateTime.day().month(.wide).year().locale(locale))
        }
        let rating = formattedRating([metadata?.voteAverage, episode.rating])
        let position = episode.season > 0
            ? "Saison \(episode.season) · Épisode \(episode.number)"
            : "Épisode spécial \(episode.number)"
        return Self(
            eyebrow: position,
            name: names.first { !$0.isEmpty } ?? "Épisode \(episode.number)",
            details: [duration, date].compactMap { $0 },
            rating: rating,
            runtimeSeconds: seconds,
            synopsisCandidates: [metadata?.overview, episode.plot],
            landscapes: [metadata?.stillURL, episode.stillURL, backdrop].compactMap { $0 },
            poster: poster,
            seed: episode.id.rawValue,
            info: rows([
                ("Série", series), ("Épisode", position), ("Durée", duration), ("Diffusion", date),
                ("Note", rating.map { "\($0) / 10" }),
            ])
        )
    }

    static func title(
        _ title: MediaTitle, year: Int?, genre: String?, runtimeMinutes: Int?, certification: String?,
        plot: String?, rating: Double?, backdrop: URL?, poster: URL?, logo: URL?
    ) -> Self {
        let duration = runtimeMinutes.flatMap { $0 > 0 ? "\($0) min" : nil }
        let rating = formattedRating([rating])
        return Self(
            eyebrow: title.kind == .series ? "Série" : "Film",
            name: title.title,
            logo: logo,
            details: [year.map(String.init), genre, duration, certification].compactMap { $0 },
            rating: rating,
            runtimeSeconds: runtimeMinutes.flatMap { $0 > 0 ? $0 * 60 : nil },
            synopsisCandidates: [plot, title.plot],
            landscapes: [backdrop].compactMap { $0 },
            poster: poster ?? title.posterURL,
            seed: title.id.rawValue,
            info: rows([
                ("Sortie", year.map(String.init)), ("Genre", genre), ("Durée", duration),
                ("Classification", certification), ("Note", rating.map { "\($0) / 10" }),
            ])
        )
    }

    private static func rows(_ pairs: [(String, String?)]) -> [InfoRow] {
        pairs.compactMap { label, value in value.map { InfoRow(label, $0) } }
    }

    private static func formattedRating(_ candidates: [Double?]) -> String? {
        candidates.compactMap { $0 }.first { $0 > 0 && $0 <= 10 }
            .map { $0.formatted(.number.precision(.fractionLength(1)).locale(locale)) }
    }
}

/// One playable edition in the playback sheet: language, optional source/duplicate line,
/// tech labels. Sits on the page background, so it follows the system appearance.
struct PlaybackEditionTile: View {
    static let size = CGSize(width: 220, height: 104)

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

    private var labels: [String] {
        option.label.components(separatedBy: " · ").filter { !$0.isEmpty }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(option.titleEdition.edition.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .accessibilityHidden(true)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 3)
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    ForEach(labels.indices, id: \.self) { index in
                        TechLabel(text: labels[index])
                    }
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
            .background(fill, in: shape)
            .overlay {
                shape.strokeBorder(stroke, lineWidth: selected || focused ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .contentShape(shape)
            .scaleEffect(reduceMotion ? 1 : (hovered ? 1.03 : 1))
            .shadow(color: .black.opacity(hovered && !reduceMotion ? 0.12 : 0), radius: 12, y: 6)
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

    private var fill: Color {
        if selected { return .accentColor.opacity(0.10) }
        return hovered ? .primary.opacity(0.09) : PrismColors.panelFill
    }

    private var stroke: Color {
        if selected || focused { return .accentColor }
        return .primary.opacity(0.06)
    }
}

/// `MediaBadge` metrics in adaptive colours: picture-quality labels filled, others outlined.
private struct TechLabel: View {
    let text: String

    var body: some View {
        let filled = MediaBadge.isQualityLabel(text)
        let shape = RoundedRectangle(cornerRadius: PrismMetrics.badgeRadius, style: .continuous)
        Text(text.uppercased())
            .font(PrismFont.badge)
            .tracking(0.2)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, PrismMetrics.badgeHorizontalPadding + 0.5)
            .frame(height: PrismMetrics.badgeHeight + 2)
            .foregroundStyle(filled ? AnyShapeStyle(PrismColors.pageBackground) : AnyShapeStyle(.secondary))
            .background {
                if filled {
                    shape.fill(.secondary)
                } else {
                    shape.strokeBorder(.secondary, lineWidth: 1)
                }
            }
    }
}
