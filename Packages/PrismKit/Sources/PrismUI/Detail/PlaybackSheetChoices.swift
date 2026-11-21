import Foundation
import PrismCore

nonisolated struct PlaybackSheetFilter: Identifiable, Hashable {
    let id: String
    let title: String

    static let all = Self(id: "all", title: "Toutes")

    static func available(for edition: PlaybackEdition) -> [Self] {
        let version = Self(id: "version-\(edition.key)", title: edition.title)
        switch edition.key {
        case "VFF", "VFQ", "VF2":
            return [audio("FR"), version]
        case "VOSTFR", "VOSTA", "VOST", "VO", "MULTI", "unknown":
            return [version]
        default:
            return edition.key.split(separator: "+").map { audio(String($0)) }
        }
    }

    private static func audio(_ code: String) -> Self {
        let locale = Locale(identifier: "fr-FR")
        let label = locale.localizedString(forLanguageCode: code.lowercased()) ?? code
        return Self(id: "audio-\(code)", title: label.capitalized(with: locale))
    }
}

/// Index newly resolved editions once so picking a language only reads the matching options.
nonisolated struct PlaybackSheetChoices {
    private var discoveredFilters: [PlaybackSheetFilter] = []
    private var options: [PlaybackSheetFilter: [TitlePlaybackOption]] = [:]
    private var ids: Set<ContentID> = []
    private var filtersByEdition: [PlaybackEdition: [PlaybackSheetFilter]] = [:]

    init(_ initial: [TitlePlaybackOption]) {
        append(initial)
    }

    var filters: [PlaybackSheetFilter] {
        let preferred = ["audio-FR", "audio-EN"]
        return preferred.compactMap { id in discoveredFilters.first { $0.id == id } }
            + discoveredFilters.filter { !preferred.contains($0.id) }
    }

    mutating func append(_ batch: [TitlePlaybackOption]) {
        for option in batch where ids.insert(option.id).inserted {
            let edition = option.titleEdition.edition
            let matches: [PlaybackSheetFilter]
            if let existing = filtersByEdition[edition] {
                matches = existing
            } else {
                matches = PlaybackSheetFilter.available(for: edition)
                filtersByEdition[edition] = matches
            }
            for filter in matches {
                if options[filter] == nil { discoveredFilters.append(filter) }
                options[filter, default: []].append(option)
            }
            options[.all, default: []].append(option)
        }
    }

    subscript(filter: PlaybackSheetFilter) -> [TitlePlaybackOption] { options[filter, default: []] }
}
