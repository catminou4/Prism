import PrismCore

/// Ready-to-display editorial shelves for one combination of playback languages.
public struct RecommendationSelection: Sendable {
    static let empty = RecommendationSelection(highlights: [], french: [], american: [], discoveries: [], wellRated: [])

    public let highlights: [MediaTitle]
    public let french: [MediaTitle]
    public let american: [MediaTitle]
    public let discoveries: [MediaTitle]
    public let wellRated: [MediaTitle]

    public var hasEditorialTitles: Bool { !french.isEmpty || !american.isEmpty || !discoveries.isEmpty }
}

public struct Recommendations: Sendable {
    public static let empty = Recommendations(selections: [:], editorialCopy: [:])

    let selections: [Set<HomeAudioLanguage>: RecommendationSelection]
    let editorialCopy: [TitleID: EditorialCopy]

    struct EditorialCopy: Sendable {
        let title: String
        let plot: String?
    }

    public func selection(for languages: Set<HomeAudioLanguage>) -> RecommendationSelection {
        selections[languages.isEmpty ? HomeAudioLanguage.defaults : languages] ?? .empty
    }

    /// Use the identified work's canonical name while preserving the provider's title ID and offers.
    public func named(_ media: MediaTitle) -> MediaTitle {
        guard let copy = editorialCopy[media.id] else { return media }
        var result = media
        result.title = copy.title
        result.plot = copy.plot
        return result
    }
}

public enum RecommendationBuilder {
    @concurrent
    public static func build(for catalog: Catalog) async -> Recommendations {
        if !catalog.sources.isEmpty, catalog.sources.allSatisfy(DemoContent.isDemo) {
            let titles = catalog.featured(limit: 7)
            let selection = RecommendationSelection(highlights: titles, french: [], american: [], discoveries: [], wellRated: titles)
            return Recommendations(selections: [
                HomeAudioLanguage.defaults: selection, [.french]: selection, [.english]: selection,
            ], editorialCopy: [:])
        }
        var editorialCopy: [TitleID: Recommendations.EditorialCopy] = [:]
        let editorial = EditorialSelection.shelves.map { shelf in
            shelf.map { entry in
                entry.matches(in: catalog).map { title in
                    let copy = editorialCopy[title.id] ?? .init(title: entry.name, plot: homePlot(for: title))
                    editorialCopy[title.id] = copy
                    var item = title
                    item.title = copy.title
                    item.plot = copy.plot
                    return Candidate(item: item, audio: availableAudio(for: title, original: entry.originalLanguage, catalog: catalog))
                }
            }
        }

        let choices: [Set<HomeAudioLanguage>] = [HomeAudioLanguage.defaults, [.french], [.english]]
        let curatedChoices = choices.map { languages in
            var seen: Set<TitleID> = []
            return editorial.map { shelf in
                var items: [MediaTitle] = []
                for versions in shelf {
                    guard let match = versions.first(where: { !$0.audio.isDisjoint(with: languages) && !seen.contains($0.item.id) })
                    else { continue }
                    seen.insert(match.item.id)
                    items.append(match.item)
                    if items.count == 20 { break }
                }
                return items
            }
        }
        let fallbackChoices = zip(choices, curatedChoices).compactMap { languages, curated in
            curated.allSatisfy(\.isEmpty) ? languages : nil
        }
        var rated: [[Set<HomeAudioLanguage>: [MediaTitle]]] = []
        if !fallbackChoices.isEmpty, catalog.indexes.hasTaggedEditions || !catalog.indexes.categoryLanguages.isEmpty {
            let excluded = Set(editorialCopy.keys)
            async let movies = fallback(catalog.movies, choices: fallbackChoices, catalog: catalog, excluding: excluded)
            async let series = fallback(catalog.series, choices: fallbackChoices, catalog: catalog, excluding: excluded)
            rated = await [movies, series]
        }

        var selections: [Set<HomeAudioLanguage>: RecommendationSelection] = [:]
        for (languages, curated) in zip(choices, curatedChoices) {
            let fallback = interleaved(rated.map { $0[languages] ?? [] }, limit: 24)
            let spotlight = interleaved(curated.map(artworkFirst), limit: 7)
            let fallbackHighlights: [MediaTitle] = spotlight.isEmpty ? artworkFirst(fallback).prefix(7).map { item in
                var visible = item
                visible.plot = homePlot(for: item)
                return visible
            } : []
            selections[languages] = RecommendationSelection(
                highlights: spotlight.isEmpty ? fallbackHighlights : artworkFirst(spotlight),
                french: curated[0], american: curated[1], discoveries: curated[2], wellRated: fallback
            )
        }
        return Recommendations(selections: selections, editorialCopy: editorialCopy)
    }

    private struct Candidate {
        let item: MediaTitle
        let audio: Set<HomeAudioLanguage>
    }

    @concurrent private static func fallback(
        _ titles: [MediaTitle], choices: [Set<HomeAudioLanguage>], catalog: Catalog, excluding excluded: Set<TitleID>
    ) async -> [Set<HomeAudioLanguage>: [MediaTitle]] {
        var candidates: [(rank: (score: Double, index: Int32), audio: Set<HomeAudioLanguage>)] = []
        for (index, item) in titles.enumerated() {
            if index.isMultiple(of: 2_048), Task.isCancelled { return [:] }
            guard let rating = item.rating, (7...10).contains(rating), !item.isAdult,
                  item.posterURL != nil || item.backdropURL != nil, !excluded.contains(item.id) else { continue }
            let audio = availableAudio(for: item, original: nil, catalog: catalog)
            guard !audio.isEmpty, hasLatinTitle(item.title) else { continue }
            let score = rating * 1_000 + (item.posterURL == nil ? 0 : 10) + Double(min(item.variants.count, 9))
            candidates.append(((score, Int32(index)), audio))
        }
        return Dictionary(uniqueKeysWithValues: choices.map { languages in
            let eligible = candidates.lazy.filter { !$0.audio.isDisjoint(with: languages) }.map(\.rank)
            let indices = CatalogBuilder.topIndices(eligible, count: 24)
            return (languages, indices.map { titles[Int($0)] })
        })
    }

    private static func homePlot(for title: MediaTitle) -> String? {
        ProviderSynopsis.preferredFrenchOrEnglish(
            from: [title.plot] + title.variants.prefix(12).map { $0.movie?.plot ?? $0.series?.plot }
        )
    }

    private static let frenchDubs: Set<String> = ["VF", "VFF", "VFQ", "VFI", "VF2", "TRUEFRENCH"]
    private static let frenchTags = frenchDubs.union(["FR", "FRA", "FRENCH"])
    private static let englishTags: Set<String> = ["EN", "ENG", "ENGLISH"]
    private static let otherLanguageTags: Set<String> = [
        "AR", "ARA", "DE", "GER", "DEU", "IT", "ITA", "ES", "ESP", "SPA", "PT", "POR", "NL", "NLD", "NED",
        "TR", "TUR", "PL", "POL", "RU", "RUS", "IND", "HIN", "URD", "PER", "FAS", "JPN", "KOR", "CHN",
        "SWE", "NOR", "DNK", "DEN", "FIN", "GRE", "GRC", "ROM", "ROU", "HUN", "CZE", "SVK", "UKR", "VNM",
    ]
    private static let originalTags: Set<String> = ["VO", "VOST", "VOSTFR", "VOSTA", "SUBFRENCH"]

    private static func availableAudio(
        for item: MediaTitle, original: HomeAudioLanguage?, catalog: Catalog
    ) -> Set<HomeAudioLanguage> {
        let hasCategoryEvidence = !catalog.indexes.categoryLanguages.isEmpty
        var result: Set<HomeAudioLanguage> = []
        for variant in item.variants {
            let tags = variant.tags
            if tags.isEmpty, !hasCategoryEvidence {
                if let original { result.insert(original) }
                continue
            }
            let isOriginal = tags.contains(where: originalTags.contains)
            let hasFrenchTag = tags.contains(where: frenchTags.contains)
            let hasEnglishTag = tags.contains(where: englishTags.contains)
            if hasFrenchTag && (!isOriginal || tags.contains(where: frenchDubs.contains)) {
                result.insert(.french)
            }
            if hasEnglishTag {
                result.insert(.english)
            }
            if !hasFrenchTag, !hasEnglishTag {
                if tags.contains(where: otherLanguageTags.contains) { continue }
                if isOriginal {
                    if let original { result.insert(original) }
                } else {
                    let languages = catalog.providerLanguages(for: variant)
                    result.formUnion(languages.compactMap(HomeAudioLanguage.init(rawValue:)))
                    if languages.isEmpty, let original { result.insert(original) }
                }
            } else if isOriginal, let original {
                result.insert(original)
            }
            if result == HomeAudioLanguage.defaults { break }
        }
        return result
    }

    private static func hasLatinTitle(_ title: String) -> Bool {
        var hasLetters = false
        for scalar in title.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x41...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: hasLetters = true
            default: return false
            }
        }
        return hasLetters
    }

    private static func artworkFirst(_ titles: [MediaTitle]) -> [MediaTitle] {
        titles.filter { $0.backdropURL != nil }
            + titles.filter { $0.backdropURL == nil && $0.posterURL != nil }
            + titles.filter { $0.backdropURL == nil && $0.posterURL == nil }
    }

    private static func interleaved(_ shelves: [[MediaTitle]], limit: Int) -> [MediaTitle] {
        var result: [MediaTitle] = []
        for index in 0..<(shelves.map(\.count).max() ?? 0) {
            for shelf in shelves where index < shelf.count {
                result.append(shelf[index])
                if result.count == limit { return result }
            }
        }
        return result
    }
}

/// The first name is the canonical presentation label. Aliases may be original or localized names.
/// A release year disambiguates remakes. Only distinctive names are eligible for undated matching.
struct EditorialTitle: Sendable {
    let name: String
    let originalLanguage: HomeAudioLanguage?
    let kind: MediaKind
    let aliasKeys: [String]
    let dated: [TitleID]
    let undated: [TitleID]
    let year: Int

    init(
        _ kind: MediaKind, _ year: Int, _ name: String, _ aliases: String...,
        originalLanguage: HomeAudioLanguage? = .english, allowUndated: Bool = false
    ) {
        let keys = ([name] + aliases).map(TitleNormalizer.key)
        self.name = name
        self.kind = kind
        self.aliasKeys = keys
        self.originalLanguage = originalLanguage
        self.year = year
        dated = keys.map { TitleID(kind: kind, normalizedTitle: $0, year: year) }
        undated = allowUndated ? keys.map { TitleID(kind: kind, normalizedTitle: $0, year: nil) } : []
    }

    func matches(in catalog: Catalog) -> [MediaTitle] {
        var seen: Set<TitleID> = []
        return dated.compactMap { catalog.title($0) }.filter { $0.year == year && !$0.isAdult && seen.insert($0.id).inserted }
            + undated.compactMap { catalog.title($0) }.filter { $0.year == nil && !$0.isAdult && seen.insert($0.id).inserted }
    }
}
