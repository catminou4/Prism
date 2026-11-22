import Foundation
import PrismCore

/// What Prism knows about one grouped title, computed once per catalogue snapshot.
///
/// IPTV providers rarely send reliable metadata, but they leak strong signals: how many language
/// editions and sources carry a work (international distribution ≈ popularity), how their
/// categories are named (platforms, genres, "Top IMDb", "New releases"…), the TMDB rating they copy,
/// release years and when the title was added. Signals are blended into one relevance score.
public struct TitleSignals: Sendable, Hashable {
    public var genres: GenreSet = []
    public var platforms: PlatformSet = []
    public var flags: TraitFlags = []
    /// Bit 0: French audio, bit 1: English audio, bit 2: no language evidence at all.
    var audio: UInt8 = 0
    /// Distinct language editions and sources carrying the work.
    public var editions: UInt8 = 0
    /// Bayesian-adjusted rating on a 0…10 scale (prior 6.3 when unrated).
    public var quality: Float = 0
    /// General relevance used for every ranking (≈ 0…1.2).
    public var score: Float = 0
    /// Passes the quality gate: artwork, plausible name, not a clip, a cam or an adult title.
    public var isEligible = false
    public var year: Int16 = 0
    var addedDay: Int32 = 0
    var isEditorial = false

    static let unknownAudio: UInt8 = 4

    /// Titles without any language hint stay eligible: excluding them would empty whole
    /// provider sections ("NETFLIX | Thriller") because their neighbours carry language tags.
    func matches(audio languages: UInt8) -> Bool { audio & (languages | Self.unknownAudio) != 0 }
}

/// Per-catalogue signals and rankings used by `Curator`.
public struct CurationIndex: Sendable {
    public static let empty = CurationIndex(
        movies: [], series: [], movieRanking: [], seriesRanking: [], currentYear: 2026,
        hasLanguageEvidence: false, catalogDay: 0, isBuilt: false
    )

    let movies: [TitleSignals]
    let series: [TitleSignals]
    /// Eligible indices, best first.
    let movieRanking: [Int32]
    let seriesRanking: [Int32]
    let currentYear: Int
    let hasLanguageEvidence: Bool
    /// Most recent `addedAt` day in the catalogue (freshness is relative to the provider's clock).
    let catalogDay: Int32
    /// `false` only for the placeholder used while the real index is being built.
    public var isBuilt = true

    public var isEmpty: Bool { movieRanking.isEmpty && seriesRanking.isEmpty }

    func signals(_ kind: MediaKind) -> [TitleSignals] { kind == .series ? series : movies }
    func ranking(_ kind: MediaKind) -> [Int32] { kind == .series ? seriesRanking : movieRanking }

    public func signals(for title: MediaTitle, in catalog: Catalog) -> TitleSignals? {
        switch title.kind {
        case .movie: catalog.indexes.movieByTitleID[title.id].flatMap { movies.indices.contains($0) ? movies[$0] : nil }
        case .series: catalog.indexes.seriesByTitleID[title.id].flatMap { series.indices.contains($0) ? series[$0] : nil }
        case .live, .episode: nil
        }
    }

    // MARK: - Build

    @concurrent
    public static func build(catalog: Catalog, recommendations: Recommendations, now: Date = .now) async -> CurationIndex {
        let calendar = Calendar(identifier: .gregorian)
        let currentYear = calendar.component(.year, from: now)
        let hasLanguageEvidence = catalog.indexes.hasTaggedEditions || !catalog.indexes.categoryLanguages.isEmpty
        var categoryTraits: [String: CategoryTraits] = [:]
        for category in catalog.indexes.categories.values where category.kind == .movie || category.kind == .series {
            categoryTraits[category.id] = CurationTaxonomy.traits(forCategory: category.name, currentYear: currentYear)
        }
        let editorial = Set(recommendations.editorialCopy.keys)
        let latest = (catalog.movies.lazy.compactMap(\.addedAt).max() ?? now).timeIntervalSince1970
        let catalogDay = Int32(latest / 86_400)
        let context = Context(
            catalog: catalog, recommendations: recommendations, categoryTraits: categoryTraits, editorial: editorial,
            currentYear: currentYear, catalogDay: catalogDay, hasLanguageEvidence: hasLanguageEvidence
        )
        async let movies = signals(for: catalog.movies, context: context)
        async let series = signals(for: catalog.series, context: context)
        let (movieSignals, seriesSignals) = await (movies, series)
        return CurationIndex(
            movies: movieSignals, series: seriesSignals,
            movieRanking: ranking(movieSignals), seriesRanking: ranking(seriesSignals),
            currentYear: currentYear, hasLanguageEvidence: hasLanguageEvidence, catalogDay: catalogDay
        )
    }

    struct Context: Sendable {
        let catalog: Catalog
        let recommendations: Recommendations
        let categoryTraits: [String: CategoryTraits]
        let editorial: Set<TitleID>
        let currentYear: Int
        let catalogDay: Int32
        let hasLanguageEvidence: Bool
    }

    @concurrent
    private static func signals(for titles: [MediaTitle], context: Context) async -> [TitleSignals] {
        let chunk = 8_192
        let ranges = stride(from: 0, to: titles.count, by: chunk).map { $0..<min($0 + chunk, titles.count) }
        return await withTaskGroup(of: (Int, [TitleSignals]).self) { group in
            for (offset, range) in ranges.enumerated() {
                group.addTask {
                    var genreCache: [String: GenreSet] = [:]
                    return (offset, range.map { signals(for: titles[$0], context: context, genreCache: &genreCache) })
                }
            }
            var parts = [[TitleSignals]](repeating: [], count: ranges.count)
            for await (offset, part) in group { parts[offset] = part }
            return parts.flatMap { $0 }
        }
    }

    static func signals(for title: MediaTitle, context: Context, genreCache: inout [String: GenreSet]) -> TitleSignals {
        var result = TitleSignals()
        var sawRegional = false
        var sawInternational = false
        for categoryID in title.categoryIDs {
            guard let traits = context.categoryTraits[categoryID] else { continue }
            result.genres.formUnion(traits.genres)
            result.platforms.formUnion(traits.platforms)
            result.flags.formUnion(traits.flags.subtracting([.regional, .international]))
            if traits.flags.contains(.regional) { sawRegional = true } else { sawInternational = true }
        }
        if sawRegional && !sawInternational { result.flags.insert(.regional) }
        for label in title.genres {
            if let cached = genreCache[label] {
                result.genres.formUnion(cached)
            } else {
                let genres = CurationTaxonomy.genres(forLabel: label)
                if genreCache.count < 2_048 { genreCache[label] = genres }
                result.genres.formUnion(genres)
            }
        }
        // Sport genre on films is a category artefact ("Sports" collection): keep it for events only.
        if result.flags.contains(.sportEvent), result.genres.count > 1 { result.flags.remove(.sportEvent) }
        if result.genres.contains(.anime) { result.genres.insert(.animation) }
        if result.flags.contains(.kids) { result.genres.insert(.family) }

        // Distribution breadth: language editions (tags) and additional sources.
        var languages: Set<String> = []
        var sources: Set<SourceID> = []
        for variant in title.variants.prefix(48) {
            sources.insert(variant.sourceID)
            for tag in variant.tags where isLanguageTag(tag) { languages.insert(tag) }
        }
        let editions = max(languages.count, 1) + max(sources.count - 1, 0)
        result.editions = UInt8(min(editions, 255))

        // Audio availability for the language preferences.
        if context.hasLanguageEvidence {
            let original = context.recommendations.editorialCopy[title.id]?.originalLanguage
            let audio = RecommendationBuilder.availableAudio(for: title, original: original, catalog: context.catalog)
            if audio.contains(.french) { result.audio |= 1 }
            if audio.contains(.english) { result.audio |= 2 }
            if audio.isEmpty, original == nil, !hasLanguageHints(title, catalog: context.catalog) {
                result.audio = TitleSignals.unknownAudio
            }
        } else {
            result.audio = 3
        }

        result.year = Int16(clamping: title.year ?? 0)
        result.addedDay = Int32((title.addedAt?.timeIntervalSince1970 ?? 0) / 86_400)
        result.isEditorial = context.editorial.contains(title.id)
        if CurationTaxonomy.looksLikeEpisode(title.title) { result.flags.insert(.episodeLike) }

        // Bayesian rating: wide distribution = more trustworthy rating.
        let prior: Float = 6.3
        let weight = 0.8 + 0.5 * Float(min(editions, 14))
        if let rating = title.rating, rating > 0.5, rating <= 10 {
            result.quality = (calibrated(Float(rating), kind: title.kind, editions: editions) * weight + prior * 2.5) / (weight + 2.5)
        } else {
            result.quality = prior - 0.4
        }

        result.isEligible = isEligible(title, signals: result)
        result.score = result.isEligible ? score(result, title: title, context: context) : 0
        return result
    }

    /// Provider ratings are TMDB averages copied without vote counts: a perfect 10 almost always
    /// means "a handful of votes". Series ratings are often rounded up to an integer.
    static func calibrated(_ rating: Float, kind: MediaKind, editions: Int) -> Float {
        if rating >= 9.6 { return 6.9 }
        if rating >= 9, editions <= 2 { return rating - 1.4 }
        if kind == .series, rating == rating.rounded() { return rating - 0.45 }
        return rating
    }

    private static func isEligible(_ title: MediaTitle, signals: TitleSignals) -> Bool {
        guard !title.isAdult, title.$posterURL != nil || title.$backdropURL != nil,
              title.year != nil || title.rating != nil,
              signals.flags.isDisjoint(with: [.lowQualityRelease, .episodeLike, .religious, .sportEvent]) else { return false }
        if RecommendationBuilder.hasLatinTitle(title.title) { return true }
        return title.variants.prefix(6).contains { RecommendationBuilder.hasLatinTitle($0.title) }
    }

    private static func score(_ signals: TitleSignals, title: MediaTitle, context: Context) -> Float {
        let quality = min(max((signals.quality - 5.6) / 2.8, 0), 1)
        let popularity = min(log2(1 + Float(signals.editions)) / 4, 1)
        let age = signals.year > 0 ? context.currentYear - Int(signals.year) : 12
        let freshness: Float = age <= 0 ? 1 : max(0, 1 - Float(age) / 6)
        let addedDays = signals.addedDay > 0 ? max(0, context.catalogDay - signals.addedDay) : 365
        let justAdded = max(0, 1 - Float(addedDays) / 45)
        var score = 0.44 * quality + 0.34 * popularity + 0.11 * freshness + 0.04 * justAdded
        if title.$backdropURL != nil { score += 0.02 }
        if title.plot?.isEmpty == false { score += 0.01 }
        if signals.flags.contains(.acclaimed) { score += 0.06 }
        if signals.isEditorial { score += 0.08 }
        if signals.flags.contains(.regional) { score -= 0.22 }
        if signals.flags.contains(.christmas) { score -= 0.04 }
        if signals.year == 0 { score -= 0.05 }
        if signals.audio == TitleSignals.unknownAudio { score -= 0.03 }
        return score
    }

    private static func ranking(_ signals: [TitleSignals]) -> [Int32] {
        var indices: [Int32] = []
        indices.reserveCapacity(signals.count / 2)
        for (index, signal) in signals.enumerated() where signal.isEligible { indices.append(Int32(index)) }
        indices.sort { lhs, rhs in
            let left = signals[Int(lhs)].score, right = signals[Int(rhs)].score
            return left != right ? left > right : lhs < rhs
        }
        return indices
    }

    private static let nonLanguageTags: Set<String> = [
        "4K", "UHD", "HD", "FHD", "SD", "HEVC", "H265", "X265", "3D", "CAM", "HDCAM", "SUB", "SUBS", "DUB", "MULTI",
        "MULTI-SUB", "VOSTFR", "VOST", "VO", "HDR", "DV", "AI", "NF", "IMAX", "REMUX", "BLURAY",
    ]

    /// Any tag that is not about picture quality, or a language-named category.
    private static func hasLanguageHints(_ title: MediaTitle, catalog: Catalog) -> Bool {
        title.variants.prefix(16).contains { variant in
            variant.tags.contains { !pictureTags.contains($0) } || !catalog.providerLanguages(for: variant).isEmpty
        }
    }

    private static let pictureTags: Set<String> = [
        "4K", "UHD", "HD", "FHD", "SD", "HEVC", "H265", "X265", "3D", "HDR", "DV", "IMAX", "REMUX", "BLURAY", "AI", "NF",
        "CAM", "HDCAM",
    ]

    private static func isLanguageTag(_ tag: String) -> Bool {
        let count = tag.utf8.count
        return count >= 2 && count <= 7 && !nonLanguageTags.contains(tag)
    }
}
