import Foundation
import PrismCore
import PrismPlayer
import SwiftUI

/// Connects catalog actions to the owning player session without invalidating
/// every view that reads this environment value on unrelated SwiftUI updates.
nonisolated struct PrismPlaybackAction: Equatable, Sendable {
    private let owner: ObjectIdentifier?
    private let action: @MainActor (PlaybackItem, HistoryEntry.Target, ContentID, ContentID?) -> Void

    static let none = Self(owner: nil) { _, _, _, _ in }

    init(
        owner: AnyObject?,
        action: @escaping @MainActor (PlaybackItem, HistoryEntry.Target, ContentID, ContentID?) -> Void
    ) {
        self.owner = owner.map(ObjectIdentifier.init)
        self.action = action
    }

    @MainActor func callAsFunction(
        _ item: PlaybackItem, _ target: HistoryEntry.Target, _ contentID: ContentID, seriesEditionID: ContentID? = nil
    ) {
        action(item, target, contentID, seriesEditionID)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.owner == rhs.owner }
}

extension EnvironmentValues {
    @Entry var playPrismItem: PrismPlaybackAction = .none
}

nonisolated struct PlaybackEdition: Hashable, Sendable {
    let key: String
    let title: String

    init(tags: [String], categoryLanguages: Set<String> = []) {
        let tags = tags.map { $0.uppercased() }
        let flags = Set(tags)
        let version: (String, String)? = switch true {
        case flags.contains("MULTI"): ("MULTI", "Multilingue")
        case !flags.isDisjoint(with: ["VOSTFR", "SUBFRENCH"]): ("VOSTFR", "VO sous-titrée en français")
        case flags.contains("VOSTA"): ("VOSTA", "VO sous-titrée en anglais")
        case flags.contains("VOST"): ("VOST", "Version originale sous-titrée")
        case flags.contains("VFQ"): ("VFQ", "Français québécois")
        case !flags.isDisjoint(with: ["VFF", "VFI", "TRUEFRENCH"]): ("VFF", "Français (France)")
        case flags.contains("VF2"): ("VF2", "Plusieurs doublages français")
        case !flags.isDisjoint(with: ["VF", "FRENCH"]): ("FR", "Français")
        case flags.contains("VO"): ("VO", "Version originale")
        default: nil
        }
        if let version {
            (key, title) = version
            return
        }

        let declared = Set(tags.compactMap { Self.languageCodes[$0] })
        let codes = (declared.isEmpty ? categoryLanguages : declared).sorted()
        let locale = Self.displayLocale
        let names = codes.compactMap { locale.localizedString(forLanguageCode: $0) }
        key = codes.isEmpty ? "unknown" : codes.joined(separator: "+").uppercased()
        title = names.isEmpty ? "Langue non renseignée" : names.joined(separator: " / ").capitalized(with: locale)
    }

    /// Editions are rebuilt on every detail-page evaluation; the locale is immutable and shared.
    private static let displayLocale = Locale(identifier: "fr-FR")

    // Language labels describe stream tags. Country tags such as US, CA or BE
    // alone do not establish which audio tracks the player will find.
    private static let languageCodes = [
        "FR": "fr", "FRA": "fr", "EN": "en", "ENG": "en", "ES": "es", "SPA": "es",
        "IT": "it", "ITA": "it", "DE": "de", "DEU": "de", "GER": "de", "PT": "pt", "POR": "pt",
        "AR": "ar", "ARA": "ar", "TR": "tr", "TUR": "tr", "PL": "pl", "POL": "pl", "RU": "ru", "RUS": "ru",
        "JA": "ja", "JPN": "ja", "KO": "ko", "KOR": "ko", "ZH": "zh", "HI": "hi", "HIN": "hi",
        "NL": "nl", "NLD": "nl", "EL": "el", "GRC": "el", "UKR": "uk", "SV": "sv", "SWE": "sv",
        "HU": "hu", "HUN": "hu", "RO": "ro", "RON": "ro", "CS": "cs", "CES": "cs",
    ]
}

nonisolated struct EpisodeCoordinate: Hashable, Comparable, Sendable {
    let season: Int
    let number: Int

    init(_ episode: Episode) {
        season = episode.season
        number = episode.number
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.season, lhs.number) < (rhs.season, rhs.number)
    }

    var label: String {
        season > 0 ? "S\(season) · É\(number)" : "Épisode spécial \(number)"
    }
}

nonisolated struct TitleEdition: Identifiable, Sendable {
    let variant: MediaVariant
    let source: Source
    let edition: PlaybackEdition
    var id: ContentID { variant.id }

    init(variant: MediaVariant, source: Source, categoryLanguages: Set<String> = []) {
        self.variant = variant
        self.source = source
        self.edition = PlaybackEdition(tags: variant.tags, categoryLanguages: categoryLanguages)
    }
}

nonisolated struct TitlePlaybackOption: Identifiable, Sendable {
    let titleEdition: TitleEdition
    let episode: Episode?
    let streamURL: URL
    let container: String?
    let duration: Int?
    let headers: [String: String]

    var id: ContentID { titleEdition.id }
    var contentID: ContentID { episode?.id ?? id }
    var label: String {
        [
            titleEdition.variant.quality.badge,
            container?.uppercased(),
            titleEdition.variant.tags.contains("HDR") ? "HDR" : nil,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    init?(edition: TitleEdition, episode: Episode? = nil) {
        guard edition.variant.sourceID == edition.source.id else { return nil }
        titleEdition = edition
        self.episode = episode
        let sourceHeaders: [String: String]
        if let episode, episode.seriesID == edition.id, episode.sourceID == edition.source.id {
            streamURL = episode.streamURL
            container = episode.containerExtension
            duration = episode.durationSeconds
            sourceHeaders = episode.httpHeaders
        } else if episode == nil, let movie = edition.variant.movie {
            streamURL = movie.streamURL
            container = movie.containerExtension
            duration = movie.durationSeconds
            sourceHeaders = movie.httpHeaders
        } else {
            return nil
        }
        var headers = sourceHeaders
        if let userAgent = edition.source.userAgent, !userAgent.isEmpty,
           !headers.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            headers["User-Agent"] = userAgent
        }
        self.headers = headers
    }

    /// Resume on the selected stream, including across editions with matching runtimes.
    /// Different cuts and streams with unknown runtimes keep independent positions.
    func resumePosition(exact: PlaybackProgress?, equivalent: PlaybackProgress?) -> TimeInterval? {
        if let exact {
            guard exact.position >= 5, !exact.isFinished,
                  duration.map({ $0 <= 0 || exact.position < Double($0) }) != false else { return nil }
            return exact.position
        }
        guard let equivalent, equivalent.position >= 5, !equivalent.isFinished, let duration,
              abs(Double(duration) - equivalent.duration) <= min(60, equivalent.duration * 0.03),
              equivalent.position < Double(duration) else { return nil }
        return equivalent.position
    }

    func playbackItem(for title: MediaTitle, position: TimeInterval?) -> PlaybackItem {
        let subtitle = episode.map { "\(EpisodeCoordinate($0).label) · \($0.title)" }
        return PlaybackItem(
            id: contentID.rawValue, url: streamURL, title: title.title, subtitle: subtitle,
            artworkURL: episode?.stillURL ?? title.backdropURL ?? title.posterURL, startPosition: position,
            httpHeaders: headers, containerHint: container
        )
    }
}
