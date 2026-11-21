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
    private var sections: [PlaybackSheetFilter: Section] = [:]
    private var ids: Set<ContentID> = []
    private var ranks: [ContentID: Int] = [:]
    private var filtersByEdition: [PlaybackEdition: [PlaybackSheetFilter]] = [:]

    init(_ initial: [TitlePlaybackOption], followedBy editions: [TitleEdition] = []) {
        for id in initial.map(\.id) + editions.map(\.id) where ranks[id] == nil {
            ranks[id] = ranks.count
        }
        append(initial)
    }

    var filters: [PlaybackSheetFilter] {
        let preferred = ["audio-FR", "audio-EN"]
        return preferred.compactMap { id in discoveredFilters.first { $0.id == id } }
            + discoveredFilters.filter { !preferred.contains($0.id) }
    }

    mutating func append(_ batch: [TitlePlaybackOption]) {
        var pending: [PlaybackSheetFilter: [TitlePlaybackOption]] = [:]
        for option in batch where ids.insert(option.id).inserted {
            if ranks[option.id] == nil { ranks[option.id] = ranks.count }
            let edition = option.titleEdition.edition
            let matches: [PlaybackSheetFilter]
            if let existing = filtersByEdition[edition] {
                matches = existing
            } else {
                matches = PlaybackSheetFilter.available(for: edition)
                filtersByEdition[edition] = matches
            }
            for filter in matches {
                if sections[filter] == nil, pending[filter] == nil { discoveredFilters.append(filter) }
                pending[filter, default: []].append(option)
            }
            pending[.all, default: []].append(option)
        }
        for (filter, batch) in pending {
            let options = (sections[filter]?.options ?? []) + batch
            sections[filter] = Section(options: options.sorted {
                ranks[$0.id, default: .max] < ranks[$1.id, default: .max]
            })
        }
    }

    subscript(filter: PlaybackSheetFilter) -> [TitlePlaybackOption] { section(for: filter).options }

    func section(for filter: PlaybackSheetFilter) -> Section { sections[filter] ?? .empty }

    struct Section {
        static let empty = Section(options: [])
        let options: [TitlePlaybackOption]
        let groups: [PlaybackSourceGroup]
        let ordered: [TitlePlaybackOption]

        init(options: [TitlePlaybackOption]) {
            self.options = options
            groups = PlaybackSourceGroup.grouped(options)
            ordered = groups.flatMap(\.options)
        }
    }
}
