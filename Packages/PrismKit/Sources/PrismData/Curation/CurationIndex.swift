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
    /// Provider rating × 10 (0 when unrated), before calibration: perfect scores mean few votes.
    var rating10: UInt8 = 0
    var addedDay: Int32 = 0
    var isEditorial = false
    /// `isEditorial` and the editorial copy gives the work a French name — the `.french`
    /// facet's second condition, resolved once here instead of per scanned element.
    var frenchEditorial = false

    static let unknownAudio: UInt8 = 4

    /// Titles without any language hint stay eligible: excluding them would empty whole
    /// provider sections ("NETFLIX | Thriller") because their neighbours carry language tags.
    func matches(audio languages: UInt8) -> Bool { audio & (languages | Self.unknownAudio) != 0 }
}

/// Key of a precomputed facet-membership bitmap: one bit per catalogue index, per kind.
struct FacetMaskKey: Hashable, Sendable {
    var kind: MediaKind
    var facet: CurationQuery.Facet
}

/// Per-catalogue signals and rankings used by `Curator`.
public struct CurationIndex: Sendable {
    public static let empty = CurationIndex(
        movies: [], series: [], movieRanking: [], seriesRanking: [], currentYear: 2026,
        hasLanguageEvidence: false, catalogDay: 0, facetMasks: [:], isBuilt: false
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
    /// Precomputed facet-membership bitmaps over catalogue indices (see `facetMasks(kind:facet:)`).
    let facetMasks: [FacetMaskKey: [UInt64]]
    /// `false` only for the placeholder used while the real index is being built.
    public var isBuilt = true

    public var isEmpty: Bool { movieRanking.isEmpty && seriesRanking.isEmpty }

    func signals(_ kind: MediaKind) -> [TitleSignals] { kind == .series ? series : movies }
    func ranking(_ kind: MediaKind) -> [Int32] { kind == .series ? seriesRanking : movieRanking }

    /// Same threshold `FeedBuilder.isSmall` applies: tiny catalogues get relaxed shelves.
    var isSmallCatalog: Bool { movieRanking.count + seriesRanking.count < 400 }

    /// Precomputed membership bitmap for (kind, facet), or `nil` when the facet has no mask
    /// (`.forYou`, `.because`, and `.decade` values outside the rotating set scan normally).
    func facetMask(kind: MediaKind, facet: CurationQuery.Facet) -> [UInt64]? {
        facetMasks[FacetMaskKey(kind: kind, facet: facet)]
    }

    /// Signal-only facet membership: every condition that depends just on `TitleSignals` and
    /// index-level constants — the single guard implementation shared by the bitmap build and
    /// `FeedBuilder.member`, so a bit test can never disagree with `score`.
    static func facetMember(
        _ signal: TitleSignals, kind: MediaKind, facet: CurationQuery.Facet,
        currentYear: Int, catalogDay: Int32, isSmall: Bool
    ) -> Bool {
        let isGeneral = signal.flags.isDisjoint(with: [.kids, .regional])
        let year = Int(signal.year)
        switch facet {
        case .top:
            // A chart is about reach first: international distribution, then quality and freshness.
            return isGeneral && (isSmall || (year >= currentYear - 2 && signal.editions >= 3))
        case .newReleases:
            let isRecent = year >= currentYear - 1 || (signal.flags.contains(.newRelease) && year >= currentYear - 2)
            // Small lists have few recent releases: what the provider added this month is the news.
            let justAdded = isSmall && signal.addedDay > 0 && catalogDay - signal.addedDay <= 30
            return isGeneral && (isRecent || justAdded)
        case .genre(let genre):
            guard signal.genres.contains(genre), !signal.flags.contains(.regional) else { return false }
            if signal.flags.contains(.kids), genre != .family, genre != .animation { return false }
            return true
        case .platform(let platform):
            return signal.platforms.contains(platform) && isGeneral
        case .acclaimed:
            guard !signal.flags.contains(.regional), !signal.flags.contains(.kids) else { return false }
            let isCanon = signal.flags.contains(.canon)
            return isCanon || (signal.quality >= 7.0 && signal.editions >= 2
                  && (signal.flags.contains(.acclaimed) || signal.isEditorial || (signal.quality >= 7.8 && signal.editions >= 10)))
        case .classics:
            return isGeneral && year > 0 && year <= currentYear - 25
                && (signal.quality >= 6.9 || signal.flags.contains(.canon))
        case .french:
            return (signal.flags.contains(.frenchOrigin) || signal.frenchEditorial) && !signal.flags.contains(.kids)
        case .hiddenGems:
            // Well rated but not everywhere. Near-perfect provider ratings are a handful of votes,
            // and seasonal TV films are not what anyone means by a gem.
            return isGeneral && signal.quality >= 7.0 && (2...6).contains(signal.editions) && year >= currentYear - 20
                && (70...90).contains(signal.rating10) && !signal.flags.contains(.christmas) && !signal.flags.contains(.canon)
                && (!signal.genres.contains(.family) || signal.genres.contains(.animation))
        case .popular:
            return isGeneral && (isSmall || signal.editions >= 4 || signal.flags.contains(.canon))
        case .topRated:
            // Provider ratings come without vote counts. Averages above 9 for films, and above 9 for
            // series (rounded to whole points), are nearly always a handful of votes.
            let plausible: ClosedRange<UInt8> = kind == .series ? 80...90 : 72...89
            return isGeneral && (isSmall || signal.editions >= 3 || signal.flags.contains(.canon))
                && (signal.quality >= 7.2 || signal.flags.contains(.canon)) && plausible.contains(signal.rating10)
        case .decade(let start):
            return isGeneral && year >= start && year < start + 10
        case .franchise:
            return isGeneral && signal.flags.contains(.franchise)
        case .uhd:
            return isGeneral && signal.flags.contains(.uhd)
        case .asian:
            return (signal.flags.contains(.asian) || signal.genres.contains(.anime) && kind == .movie)
                && !signal.flags.contains(.kids) && !signal.flags.contains(.regional)
        case .discover:
            return !signal.flags.contains(.regional)
        case .forYou, .because:
            // Handled by `FeedBuilder` (profile/seed state); unreachable from mask construction
            // and from `FeedBuilder.member`, which intercepts these cases first.
            return true
        }
    }

    func facetMember(_ signal: TitleSignals, kind: MediaKind, facet: CurationQuery.Facet) -> Bool {
        Self.facetMember(
            signal, kind: kind, facet: facet,
            currentYear: currentYear, catalogDay: catalogDay, isSmall: isSmallCatalog
        )
    }

    public func signals(for title: MediaTitle, in catalog: Catalog) -> TitleSignals? {
        switch title.kind {
        case .movie: catalog.indexes.movieByTitleID[title.id].flatMap { movies.indices.contains($0) ? movies[$0] : nil }
        case .series: catalog.indexes.seriesByTitleID[title.id].flatMap { series.indices.contains($0) ? series[$0] : nil }
        case .live, .episode: nil
        }
    }

    // MARK: - Build

    // Recommendation input is deliberately limited to `editorialCopy` (canonical names and
    // original-language hints). The catalog-wide fallback selections are not read here, which
    // is what allows launch publication to build this index once while fallback recommendations
    // are still completing in the background.
    @concurrent
    public static func build(catalog: Catalog, recommendations: Recommendations, now: Date = .now) async -> CurationIndex {
        let calendar = Calendar(identifier: .gregorian)
        let currentYear = calendar.component(.year, from: now)
        let hasLanguageEvidence = catalog.indexes.hasTaggedEditions || !catalog.indexes.categoryLanguages.isEmpty
        var categoryTraits: [String: CategoryTraits] = [:]
        for category in catalog.indexes.categories.values where category.kind == .movie || category.kind == .series {
            categoryTraits[category.id] = CurationTaxonomy.traits(forCategory: category.name, currentYear: currentYear)
        }
        let canon = await AcclaimedSelection.matches(in: catalog)
        let latest = (catalog.movies.lazy.compactMap(\.addedAt).max() ?? now).timeIntervalSince1970
        let catalogDay = Int32(latest / 86_400)
        let context = Context(
            catalog: catalog, recommendations: recommendations, categoryTraits: categoryTraits,
            canon: canon, currentYear: currentYear, catalogDay: catalogDay, hasLanguageEvidence: hasLanguageEvidence
        )
        async let movies = signals(for: catalog.movies, context: context)
        async let series = signals(for: catalog.series, context: context)
        var (movieSignals, seriesSignals) = await (movies, series)
        var movieRanking = ranking(movieSignals)
        var seriesRanking = ranking(seriesSignals)
        // Conservative degraded mode: providers without any artwork would leave a whole kind
        // without eligible titles and every shelf empty. When that happens, relax only the
        // artwork clause — the UI already renders monogram placeholders for missing art.
        if movieRanking.isEmpty, !catalog.movies.isEmpty {
            relaxArtworkEligibility(titles: catalog.movies, signals: &movieSignals, context: context)
            movieRanking = ranking(movieSignals)
        }
        if seriesRanking.isEmpty, !catalog.series.isEmpty {
            relaxArtworkEligibility(titles: catalog.series, signals: &seriesSignals, context: context)
            seriesRanking = ranking(seriesSignals)
        }
        let masks = await buildFacetMasks(
            movies: movieSignals, series: seriesSignals,
            movieRanking: movieRanking, seriesRanking: seriesRanking,
            currentYear: currentYear, catalogDay: catalogDay
        )
        return CurationIndex(
            movies: movieSignals, series: seriesSignals,
            movieRanking: movieRanking, seriesRanking: seriesRanking,
            currentYear: currentYear, hasLanguageEvidence: hasLanguageEvidence, catalogDay: catalogDay,
            facetMasks: masks
        )
    }

    struct Context: Sendable {
        let catalog: Catalog
        let recommendations: Recommendations
        let categoryTraits: [String: CategoryTraits]
        let canon: Set<TitleID>
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
        // Indexed reads: iterating `variants` copies each payload struct (see `availableAudio`).
        for index in title.variants.indices.prefix(48) {
            sources.insert(title.variants[index].sourceID)
            for tag in title.variants[index].tags where isLanguageTag(tag) { languages.insert(tag) }
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
        // One lookup replaces the `editorial` set probe: `editorialCopy` keys are exactly
        // the editorial set, and the French-name clause feeds `TitleSignals.frenchEditorial`.
        if let copy = context.recommendations.editorialCopy[title.id] {
            result.isEditorial = true
            result.frenchEditorial = copy.originalLanguage == .french
        }
        if context.canon.contains(title.id) { result.flags.insert([.canon, .acclaimed]) }
        if let rating = title.rating, rating > 0, rating <= 10 { result.rating10 = UInt8((rating * 10).rounded()) }
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

    private static func isEligible(_ title: MediaTitle, signals: TitleSignals, requiresArtwork: Bool = true) -> Bool {
        guard !title.isAdult,
              !requiresArtwork || title.$posterURL != nil || title.$backdropURL != nil,
              title.year != nil || title.rating != nil,
              signals.flags.isDisjoint(with: [.lowQualityRelease, .episodeLike, .religious, .sportEvent]) else { return false }
        if RecommendationBuilder.hasLatinTitle(title.title) { return true }
        return title.variants.prefix(6).contains { RecommendationBuilder.hasLatinTitle($0.title) }
    }

    /// Second pass used only when a kind's ranking came out empty (artwork-less providers):
    /// re-runs the eligibility gate without the artwork clause and rescores what passes.
    private static func relaxArtworkEligibility(titles: [MediaTitle], signals: inout [TitleSignals], context: Context) {
        for (offset, title) in titles.enumerated() where !signals[offset].isEligible {
            guard isEligible(title, signals: signals[offset], requiresArtwork: false) else { continue }
            signals[offset].isEligible = true
            signals[offset].score = score(signals[offset], title: title, context: context)
        }
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
        if signals.flags.contains(.canon) { score += 0.05 }
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

    /// Facets whose membership is a pure function of `TitleSignals` and index constants and that
    /// the UI actually queries: everything except `.forYou`/`.because` (per-builder state) and
    /// `.decade` outside the rotating set (arbitrary start years fall back to the score scan).
    private static let maskableFacets: [CurationQuery.Facet] = [
        .top, .newReleases, .acclaimed, .classics, .french, .hiddenGems, .popular, .topRated,
        .franchise, .uhd, .asian, .discover,
    ] + CanonicalGenre.allCases.map { .genre($0) }
      + StreamingPlatform.allCases.map { .platform($0) }
      + [1970, 1980, 1990, 2000, 2010].map { .decade($0) }

    /// Lookup slots into `maskableFacets` for the mask build. Grouped facets are only evaluated
    /// for members the signal actually carries — `facetMember` returns `false` for an absent
    /// genre/platform, and a year falls in at most one decade bucket — so skipping the rest is
    /// exact, not an approximation. Scalars have no membership precondition and always run.
    private struct MaskFacetSlots {
        struct Slot {
            var index: Int
            var facet: CurationQuery.Facet
        }
        var always: [Slot] = []
        var byGenre: [Int: Slot] = [:]
        var byPlatform: [Int: Slot] = [:]
        var byDecadeStart: [Int: Slot] = [:]
    }

    private static let maskFacetSlots: MaskFacetSlots = {
        var slots = MaskFacetSlots()
        for (index, facet) in maskableFacets.enumerated() {
            let slot = MaskFacetSlots.Slot(index: index, facet: facet)
            switch facet {
            case .genre(let genre): slots.byGenre[genre.rawValue] = slot
            case .platform(let platform): slots.byPlatform[platform.rawValue] = slot
            case .decade(let start): slots.byDecadeStart[start] = slot
            default: slots.always.append(slot)
            }
        }
        return slots
    }()

    /// One bitmap per (kind, maskable facet): a bit per eligible catalogue index whose signals
    /// pass `facetMember`. Built once per index — every feed and "voir tout" page then scans
    /// pools with a bit test instead of re-running the guard per element.
    ///
    /// Jobs are contiguous chunks of each kind's ranking: a chunk loads every signal once and
    /// evaluates all facets for it (per-(kind, facet) jobs would reload the same signals ~46×
    /// and thrash the cache). Partial bitmaps merge back with a bitwise OR — order-free.
    @concurrent
    private static func buildFacetMasks(
        movies: [TitleSignals], series: [TitleSignals],
        movieRanking: [Int32], seriesRanking: [Int32],
        currentYear: Int, catalogDay: Int32
    ) async -> [FacetMaskKey: [UInt64]] {
        let isSmall = movieRanking.count + seriesRanking.count < 400
        let facets = maskableFacets
        let slots = maskFacetSlots
        let chunkSize = 8_192
        var jobs: [(kind: MediaKind, signals: [TitleSignals], ranking: ArraySlice<Int32>, jobIndex: Int)] = []
        for (kind, signals, ranking) in [(MediaKind.movie, movies, movieRanking), (.series, series, seriesRanking)] {
            var lower = 0
            while lower < ranking.count {
                let upper = min(lower + chunkSize, ranking.count)
                jobs.append((kind, signals, ranking[lower..<upper], jobs.count))
                lower = upper
            }
        }
        let parts: [(kind: MediaKind, jobIndex: Int, partial: [[UInt64]])] =
            await withTaskGroup(of: (Int, MediaKind, [[UInt64]]).self) { group in
                for job in jobs {
                    group.addTask {
                        let wordCount = (job.signals.count + 63) / 64
                        var partial = [[UInt64]](repeating: [UInt64](repeating: 0, count: wordCount), count: facets.count)
                        for titleIndex in job.ranking {
                            let signal = job.signals[Int(titleIndex)]
                            let bit = Int(titleIndex)
                            // Scalar facets run unconditionally; genre/platform facets only for
                            // members the signal carries, and at most one decade bucket can hold
                            // the year. Every skipped slot is one `facetMember` would reject.
                            for slot in slots.always {
                                guard facetMember(
                                    signal, kind: job.kind, facet: slot.facet,
                                    currentYear: currentYear, catalogDay: catalogDay, isSmall: isSmall
                                ) else { continue }
                                partial[slot.index][bit >> 6] |= UInt64(1) << UInt64(bit & 63)
                            }
                            var genreBits = signal.genres.rawValue
                            while genreBits != 0 {
                                let raw = genreBits.trailingZeroBitCount
                                genreBits &= genreBits - 1
                                guard let slot = slots.byGenre[raw], facetMember(
                                    signal, kind: job.kind, facet: slot.facet,
                                    currentYear: currentYear, catalogDay: catalogDay, isSmall: isSmall
                                ) else { continue }
                                partial[slot.index][bit >> 6] |= UInt64(1) << UInt64(bit & 63)
                            }
                            var platformBits = signal.platforms.rawValue
                            while platformBits != 0 {
                                let raw = platformBits.trailingZeroBitCount
                                platformBits &= platformBits - 1
                                guard let slot = slots.byPlatform[Int(raw)], facetMember(
                                    signal, kind: job.kind, facet: slot.facet,
                                    currentYear: currentYear, catalogDay: catalogDay, isSmall: isSmall
                                ) else { continue }
                                partial[slot.index][bit >> 6] |= UInt64(1) << UInt64(bit & 63)
                            }
                            if signal.year >= 1_970 {
                                let bucket = (Int(signal.year) / 10) * 10
                                if let slot = slots.byDecadeStart[bucket], facetMember(
                                    signal, kind: job.kind, facet: slot.facet,
                                    currentYear: currentYear, catalogDay: catalogDay, isSmall: isSmall
                                ) {
                                    partial[slot.index][bit >> 6] |= UInt64(1) << UInt64(bit & 63)
                                }
                            }
                        }
                        return (job.jobIndex, job.kind, partial)
                    }
                }
                var collected = [(MediaKind, [[UInt64]])?](repeating: nil, count: jobs.count)
                for await (jobIndex, kind, partial) in group { collected[jobIndex] = (kind, partial) }
                return collected.enumerated().compactMap { index, part in
                    part.map { (jobs[index].kind, index, $0.1) }
                }
            }
        // OR-merge the per-chunk partial bitmaps into one words array per (kind, facet).
        var masks: [FacetMaskKey: [UInt64]] = [:]
        masks.reserveCapacity(2 * facets.count)
        for (kind, signals, _) in [(MediaKind.movie, movies, movieRanking), (.series, series, seriesRanking)] {
            let wordCount = (signals.count + 63) / 64
            let kindParts = parts.filter { $0.kind == kind }.sorted { $0.jobIndex < $1.jobIndex }
            for (facetIndex, facet) in facets.enumerated() {
                var words = [UInt64](repeating: 0, count: wordCount)
                for (_, _, partial) in kindParts {
                    let source = partial[facetIndex]
                    for word in words.indices { words[word] |= source[word] }
                }
                masks[FacetMaskKey(kind: kind, facet: facet)] = words
            }
        }
        return masks
    }

    private static let nonLanguageTags: Set<String> = [
        "4K", "UHD", "HD", "FHD", "SD", "HEVC", "H265", "X265", "H264", "X264", "3D", "CAM", "HDCAM",
        "SUB", "SUBS", "DUB", "MULTI", "MULTI-SUB", "VOSTFR", "VOST", "VO", "HDR", "DV", "AI", "NF",
        "IMAX", "REMUX", "BLURAY",
        // Codec, container and release-quality tags describe the file, not an audio language.
        "AAC", "AC3", "EAC3", "DTS", "DTSHD", "TRUEHD", "ATMOS", "10BIT", "50FPS", "60FPS",
        "DVDRIP", "BDRIP", "WEBRIP", "WEBDL", "WEB-DL", "HDRIP", "MP4", "MKV", "AVI", "TS", "HDTS", "HDTC", "TSHD",
        "PROPER", "REPACK", "NTSC", "PAL", "UNRATED", "SDR", "HQ", "LQ", "BACKUP", "BKP",
        "HDLIGHT", "4KLIGHT",
    ]

    /// `true` when provider tags/categories give any evidence about the title's audio:
    /// any tag that is not about picture quality, or a language-named category.
    /// Internal so the pre-index Home seed applies the same unknown-audio rule as the index.
    static func hasLanguageHints(_ title: MediaTitle, catalog: Catalog) -> Bool {
        title.variants.indices.prefix(16).contains { index in
            title.variants[index].tags.contains { !pictureTags.contains($0) }
                || !catalog.providerLanguages(for: title.variants[index]).isEmpty
        }
    }

    private static let pictureTags: Set<String> = [
        "4K", "UHD", "HD", "FHD", "SD", "HEVC", "H265", "X265", "3D", "HDR", "DV", "IMAX", "REMUX", "BLURAY", "AI", "NF",
        "CAM", "HDCAM",
    ]

    private static func isLanguageTag(_ tag: String) -> Bool {
        let bytes = tag.utf8
        let count = bytes.count
        guard count >= 2 && count <= 7, !nonLanguageTags.contains(tag) else { return false }
        // Language codes never contain digits: "HDR10", "BD50", "2024", "60FPS" are release tags.
        return !bytes.contains { $0 >= 0x30 && $0 <= 0x39 }
    }
}
