import Foundation
import PrismCore

public struct DiscoveryShelves: Sendable {
    public static let empty = DiscoveryShelves()

    public let recommended: [MediaTitle]
    public let trending: [MediaTitle]
    public let localHighlights: [MediaTitle]

    public init(recommended: [MediaTitle] = [], trending: [MediaTitle] = [], localHighlights: [MediaTitle] = []) {
        self.recommended = recommended
        self.trending = trending
        self.localHighlights = localHighlights
    }
}

public struct DiscoveryProfile: Hashable, Sendable {
    public let watchlist: [TitleID]
    public let watched: [TitleID]

    public init(watchlist: [TitleID] = [], watched: [TitleID] = []) {
        self.watchlist = Array(watchlist.prefix(12))
        self.watched = Array(watched.prefix(24))
    }
}

public enum DiscoveryBuilder {
    /// Rank once over the playable snapshot, off the UI actor. Watch history is used on this device only.
    @concurrent
    public static func local(
        for kind: MediaKind, in catalog: Catalog, recommendations: Recommendations,
        languages: Set<HomeAudioLanguage>, profile: DiscoveryProfile, now: Date = .now
    ) async -> DiscoveryShelves {
        let catalogTitles: [MediaTitle]
        switch kind {
        case .movie: catalogTitles = catalog.movies
        case .series: catalogTitles = catalog.series
        case .episode, .live: return .empty
        }
        let eligibleLanguages = languages.isEmpty ? HomeAudioLanguage.defaults : languages
        let affinity = affinityByGenre(profile, in: catalog)
        let known = Set((profile.watchlist + profile.watched).compactMap { catalog.title($0)?.id })
        let hasLanguageEvidence = catalog.indexes.hasTaggedEditions || !catalog.indexes.categoryLanguages.isEmpty
        let demo = !catalog.sources.isEmpty && catalog.sources.allSatisfy(DemoContent.isDemo)
        let titles = if hasLanguageEvidence || demo {
            catalogTitles
        } else {
            recommendations.editorialCopy.keys.sorted { $0.rawValue < $1.rawValue }
                .compactMap { catalog.title($0) }.filter { $0.kind == kind }
        }
        let currentYear = Calendar(identifier: .gregorian).component(.year, from: now)
        var ranked: [RankedTitle] = []
        for (index, title) in titles.enumerated() {
            if index.isMultiple(of: 2_048), Task.isCancelled { return .empty }
            guard !title.isAdult, title.primary != nil, title.posterURL != nil || title.backdropURL != nil else { continue }
            if demo {
                guard RecommendationBuilder.hasLatinTitle(recommendations.editorialCopy[title.id]?.title ?? title.title)
                else { continue }
            } else {
                guard recommendations.localizedName(for: title, in: catalog, languages: eligibleLanguages) != nil
                else { continue }
            }
            let local = localScore(for: title, now: now, currentYear: currentYear)
            let matchingGenres = affinity.isEmpty || known.contains(title.id) ? 0 : genreAffinity(for: title, from: affinity)
            let personal = matchingGenres > 0 ? matchingGenres * 4 + local : nil
            ranked.append(RankedTitle(index: Int32(index), local: local, personal: personal))
        }
        let recommended = CatalogBuilder.topIndices(ranked.lazy.compactMap { rank in
            rank.personal.map { (score: $0, index: rank.index) }
        }, count: 18)
        let alreadyRecommended = Set(recommended)
        let local = CatalogBuilder.topIndices(ranked.lazy.filter { !alreadyRecommended.contains($0.index) }.map {
            (score: $0.local, index: $0.index)
        }, count: 18)
        func presentedTitle(at index: Int32) -> MediaTitle {
            let title = titles[Int(index)]
            var item = recommendations.named(title)
            if !demo, let name = recommendations.localizedName(for: title, in: catalog, languages: eligibleLanguages) {
                item.title = name
            }
            return item
        }
        return DiscoveryShelves(recommended: recommended.map(presentedTitle), localHighlights: local.map(presentedTitle))
    }

    /// Retain TMDB's order only for works the user can play with the selected audio preferences.
    @concurrent
    public static func trending(
        _ chart: [TMDBTrend], for kind: MediaKind, in catalog: Catalog,
        recommendations: Recommendations, languages: Set<HomeAudioLanguage>
    ) async -> [MediaTitle] {
        guard kind == .movie || kind == .series else { return [] }
        let languages = languages.isEmpty ? HomeAudioLanguage.defaults : languages
        var result: [MediaTitle] = []
        var seen: Set<TitleID> = []
        for entry in chart {
            if Task.isCancelled { return [] }
            guard let title = match(entry, kind: kind, in: catalog), title.primary != nil, !title.isAdult,
                  !seen.contains(title.id) else { continue }
            let original = entry.originalLanguage ?? recommendations.editorialCopy[title.id]?.originalLanguage
            let audio = RecommendationBuilder.availableAudio(for: title, original: original, catalog: catalog)
            guard !audio.isDisjoint(with: languages) else { continue }
            var item = recommendations.named(title)
            if RecommendationBuilder.hasLatinTitle(entry.title) { item.title = entry.title }
            guard RecommendationBuilder.hasLatinTitle(item.title) else { continue }
            item.backdropURL = entry.images.backdropURL ?? item.backdropURL
            item.posterURL = entry.images.posterURL ?? item.posterURL
            item.plot = ProviderSynopsis.preferredFrenchOrEnglish(from: [entry.overview, item.plot])
            seen.insert(title.id)
            result.append(item)
            if result.count == 18 { break }
        }
        return result
    }

    private struct RankedTitle {
        let index: Int32
        let local: Double
        let personal: Double?
    }

    private static func match(_ entry: TMDBTrend, kind: MediaKind, in catalog: Catalog) -> MediaTitle? {
        if let identified = catalog.title(TitleID(kind: kind, tmdbID: entry.id)) { return identified }
        guard let year = entry.year else { return nil }
        let keys = Set([entry.title, entry.originalTitle].compactMap { name in
            name.map(TitleNormalizer.key)
        }).filter { !$0.isEmpty }
        var found: MediaTitle?
        for key in keys {
            let id = TitleID(kind: kind, normalizedTitle: key, year: year)
            guard let candidate = catalog.title(id), candidate.year == year else { continue }
            let knownIDs = candidate.variants.lazy.compactMap { $0.movie?.tmdbID ?? $0.series?.tmdbID }
            guard !knownIDs.contains(where: { $0 > 0 && $0 != entry.id }) else { continue }
            if let found, found.id != candidate.id { return nil }
            found = candidate
        }
        return found
    }

    private static func localScore(for title: MediaTitle, now: Date, currentYear: Int) -> Double {
        let rating = title.rating.flatMap { (1...10).contains($0) ? $0 : nil } ?? 5.5
        let added = title.addedAt.map { now.timeIntervalSince($0) / 86_400 } ?? 90
        let freshness = added >= -1 ? max(0, 1 - max(0, added) / 60) * 2.5 : 0
        let age = title.year.map { currentYear - $0 } ?? 10
        let recentRelease = (0...3).contains(age) ? Double(4 - age) * 0.35 : 0
        let firstSource = title.primary?.sourceID
        let multipleProviders = title.variants.dropFirst().contains { $0.sourceID != firstSource } ? 1.6 : 0
        let artwork = title.backdropURL != nil ? 0.5 : 0
        return rating + freshness + recentRelease + multipleProviders + artwork
    }

    private static func affinityByGenre(_ profile: DiscoveryProfile, in catalog: Catalog) -> [String: Double] {
        var affinity: [String: Double] = [:]
        for (list, weight) in [(profile.watchlist, 1.0), (profile.watched, 1.5)] {
            for (offset, id) in list.enumerated() {
                guard let title = catalog.title(id), !title.isAdult else { continue }
                for genre in Set(title.genres.map(genreKey)) where !genre.isEmpty {
                    affinity[genre, default: 0] += weight / (1 + Double(offset) / 4)
                }
            }
        }
        return affinity
    }

    private static func genreAffinity(for title: MediaTitle, from affinity: [String: Double]) -> Double {
        guard !title.genres.isEmpty else { return 0 }
        return title.genres.lazy.map { affinity[genreKey($0)] ?? 0 }.max() ?? 0
    }

    private static func genreKey(_ name: String) -> String {
        switch TitleNormalizer.key(name) {
        case "drama": "drame"
        case "comedy": "comedie"
        case "mystery": "mystere"
        case "adventure": "aventure"
        case "horror": "horreur"
        case "history": "histoire"
        case "documentary": "documentaire"
        case "family": "familial"
        case "war": "guerre"
        case "fantasy": "fantastique"
        case "musical", "music": "musique"
        case let key: key
        }
    }
}
