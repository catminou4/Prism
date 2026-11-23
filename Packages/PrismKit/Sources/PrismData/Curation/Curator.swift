import Foundation
import PrismCore

/// Which page a feed is composed for.
public enum CurationScope: String, Hashable, Sendable {
    case home, movies, series

    var kinds: [MediaKind] {
        switch self {
        case .home: [.movie, .series]
        case .movies: [.movie]
        case .series: [.series]
        }
    }

    var kind: MediaKind? {
        switch self {
        case .home: nil
        case .movies: .movie
        case .series: .series
        }
    }
}

/// What the user did on this Mac. Used only locally to personalise the feed.
public struct CurationProfile: Hashable, Sendable {
    public var watchlist: [TitleID]
    /// Most recent first: history and titles in progress.
    public var watched: [TitleID]
    public var dismissed: Set<TitleID>

    public init(watchlist: [TitleID] = [], watched: [TitleID] = [], dismissed: Set<TitleID> = []) {
        self.watchlist = Array(watchlist.prefix(24))
        self.watched = Array(watched.prefix(32))
        self.dismissed = dismissed
    }

    var isEmpty: Bool { watchlist.isEmpty && watched.isEmpty }
}

/// A "see all" destination: the full ranked list behind a shelf.
public struct CurationQuery: Hashable, Sendable {
    public enum Facet: Hashable, Sendable {
        case top
        case newReleases
        case forYou
        case because(TitleID)
        case genre(CanonicalGenre)
        case platform(StreamingPlatform)
        case acclaimed
        case classics
        case french
        case hiddenGems
        /// All-time reach: the works most providers carry in most languages.
        case popular
        /// Best ratings backed by wide distribution.
        case topRated
        /// First releases in the decade starting that year (1980, 1990…).
        case decade(Int)
        /// Sagas, cinematic universes and collections.
        case franchise
        /// Offered in 4K / UHD.
        case uhd
        /// Asian cinema, K-dramas and anime-adjacent live action.
        case asian
        /// Everything eligible, best first (small catalogues and "Voir tout").
        case discover
    }

    public var kind: MediaKind?
    public var facet: Facet
    public var title: String

    public init(kind: MediaKind?, facet: Facet, title: String) {
        self.kind = kind
        self.facet = facet
        self.title = title
    }
}

public struct CuratedShelf: Identifiable, Sendable, Hashable {
    public enum Style: Sendable, Hashable {
        case poster
        /// Top 10 with large rank numbers.
        case ranked
    }

    public let id: String
    public let title: String
    public let subtitle: String?
    public let style: Style
    public let items: [MediaTitle]
    public let seeAll: CurationQuery?
}

/// A hero entry with its editorial label pill ("Nouveauté", "N° 1 des séries"…).
public struct CuratedHighlight: Identifiable, Sendable, Hashable {
    public let title: MediaTitle
    public let label: String?
    public var id: TitleID { title.id }
}

/// A browse tile: one canonical genre with the artwork of its best title.
public struct GenreTile: Identifiable, Sendable, Hashable {
    public let genre: CanonicalGenre
    public let kind: MediaKind?
    public let count: Int
    public let artworkURL: URL?
    public var id: String { "\(kind?.rawValue ?? "all"):\(genre.rawValue)" }
}

public struct CuratedFeed: Sendable {
    public static let empty = CuratedFeed(highlights: [], shelves: [], genres: [])

    public let highlights: [CuratedHighlight]
    public let shelves: [CuratedShelf]
    public let genres: [GenreTile]

    public var isEmpty: Bool { highlights.isEmpty && shelves.isEmpty }
}

/// Composes Apple TV-style pages from the whole catalogue: a few dozen relevant titles out of
/// hundreds of thousands, organised in editorial shelves that rotate every day.
public enum Curator {
    /// Shelves get at most this many cards.
    static let shelfSize = 20

    @concurrent
    public static func feed(
        scope: CurationScope, catalog: Catalog, index: CurationIndex, recommendations: Recommendations,
        languages: Set<HomeAudioLanguage>, profile: CurationProfile, trending: [MediaKind: [TitleID]] = [:],
        now: Date = .now
    ) async -> CuratedFeed {
        guard !index.isEmpty else { return .empty }
        var builder = FeedBuilder(
            catalog: catalog, index: index, recommendations: recommendations, languages: languages,
            profile: profile, day: Int(now.timeIntervalSince1970 / 86_400)
        )
        return builder.compose(scope: scope, trending: trending)
    }

    /// The full ranked list behind a shelf ("Voir tout").
    @concurrent
    public static func collection(
        _ query: CurationQuery, catalog: Catalog, index: CurationIndex, recommendations: Recommendations,
        languages: Set<HomeAudioLanguage>, profile: CurationProfile, limit: Int = 400, now: Date = .now
    ) async -> [MediaTitle] {
        guard !index.isEmpty else { return [] }
        var builder = FeedBuilder(
            catalog: catalog, index: index, recommendations: recommendations, languages: languages,
            profile: profile, day: Int(now.timeIntervalSince1970 / 86_400)
        )
        builder.used.removeAll()
        return builder.titles(for: query, limit: limit)
    }
}

// MARK: - Builder

struct FeedBuilder {
    let catalog: Catalog
    let index: CurationIndex
    let recommendations: Recommendations
    let languages: Set<HomeAudioLanguage>
    let audioMask: UInt8
    let profile: CurationProfile
    let day: Int
    var used: Set<TitleID> = []
    private var affinity = Affinity()
    /// Memoized candidate scans, one per (kind set, facet): `used` never feeds them and every
    /// other input is fixed for the builder's lifetime, so repeated shelf/"voir tout" lookups
    /// extend a scan instead of re-filtering the whole ranking.
    private var candidateScans: [CandidateKey: CandidateScan] = [:]
    /// Per-kind scan context, built once per feed: the ranking positions that can still produce
    /// candidates (language and dismissal filters are fixed for the builder's lifetime).
    /// Facet scans neither re-filter nor re-hash elements. Facet membership bitmaps come from
    /// `CurationIndex` (`facetMask`), precomputed once per catalogue.
    private var kindPools: [MediaKind: [Int32]] = [:]

    init(
        catalog: Catalog, index: CurationIndex, recommendations: Recommendations, languages: Set<HomeAudioLanguage>,
        profile: CurationProfile, day: Int
    ) {
        self.catalog = catalog
        self.index = index
        self.recommendations = recommendations
        let languages = languages.isEmpty ? HomeAudioLanguage.defaults : languages
        self.languages = languages
        audioMask = (languages.contains(.french) ? 1 : 0) | (languages.contains(.english) ? 2 : 0)
        self.profile = profile
        self.day = day
        used = profile.dismissed
        affinity = Affinity(profile: profile, catalog: catalog, index: index)
    }

    private var currentYear: Int { index.currentYear }
    /// Demo, a single M3U list: too few titles for distribution or release-year signals to mean much.
    /// Delegates to the index so facet masks and facet scores can never disagree on the threshold.
    private var isSmall: Bool { index.isSmallCatalog }
    /// Small catalogues still deserve full shelves.
    private var minimumShelf: Int { isSmall ? 4 : 8 }

    // MARK: Composition

    mutating func compose(scope: CurationScope, trending: [MediaKind: [TitleID]]) -> CuratedFeed {
        var shelves: [CuratedShelf] = []
        let kind = scope.kind
        let kinds = scope.kinds

        // Hero first: it reserves its titles so shelves below show something else.
        let highlights = composeHighlights(scope: scope, trending: trending)
        for item in highlights { used.insert(item.title.id) }
        // Top 10 charts may repeat hero titles: a ranking is information, not a recommendation.
        var charts: [CuratedShelf] = []
        for chartKind in kinds {
            let ids = trending[chartKind] ?? []
            let items = ids.isEmpty ? top(chartKind, count: 10) : chart(from: ids, kind: chartKind, count: 10)
            guard items.count >= min(5, minimumShelf) else { continue }
            let title = chartKind == .movie ? "Top 10 des films" : "Top 10 des séries"
            charts.append(CuratedShelf(
                id: "top-\(chartKind.rawValue)", title: title,
                subtitle: ids.isEmpty ? "Les plus populaires dans vos sources" : "Tendances de la semaine",
                style: .ranked, items: items.map(present), seeAll: CurationQuery(kind: chartKind, facet: .top, title: title)
            ))
        }

        var personal: [CuratedShelf] = []
        if !profile.isEmpty {
            let forYou = take(CurationQuery(kind: kind, facet: .forYou, title: "Pour vous"), count: Curator.shelfSize)
            if forYou.count >= min(6, minimumShelf) {
                personal.append(shelf("for-you", "Pour vous", subtitle: "D’après ce que vous regardez", forYou,
                                      query: CurationQuery(kind: kind, facet: .forYou, title: "Pour vous")))
            }
            for (offset, seed) in becauseSeeds(kinds: kinds, limit: 2).enumerated() {
                let name = present(seed).title
                let query = CurationQuery(kind: seed.kind, facet: .because(seed.id), title: "Parce que vous avez regardé \(name)")
                let items = take(query, count: Curator.shelfSize)
                if items.count >= min(6, minimumShelf) {
                    personal.append(shelf(offset == 0 ? "because" : "because-\(offset)", query.title, subtitle: nil, items, query: query))
                }
            }
        }

        let newTitle = switch scope {
        case .home: "Nouveautés"
        case .movies: "Nouveaux films"
        case .series: "Nouvelles séries"
        }
        let newQuery = CurationQuery(kind: kind, facet: .newReleases, title: newTitle)
        let fresh = take(newQuery, count: Curator.shelfSize)

        shelves.append(contentsOf: personal.prefix(1))
        if !fresh.isEmpty { shelves.append(shelf("new", newTitle, subtitle: "Sorties récentes disponibles dans vos sources", fresh, query: newQuery)) }
        shelves.append(contentsOf: charts.prefix(1))

        // Platforms and genres rotate daily so the page stays alive without becoming random.
        let platforms = rotatingPlatforms(kind: kind, limit: scope == .home ? 2 : 4)
        let genres = rotatingGenres(kind: kind, limit: scope == .home ? 4 : 8)
        var editorial: [CuratedShelf] = []
        for platform in platforms {
            let title = "Le meilleur de \(platform.name)"
            let query = CurationQuery(kind: kind, facet: .platform(platform), title: title)
            let items = take(query, count: Curator.shelfSize)
            if items.count >= minimumShelf { editorial.append(shelf("platform-\(platform.rawValue)", title, subtitle: nil, items, query: query)) }
        }
        var genreShelves: [CuratedShelf] = []
        for genre in genres {
            let title = genre.shelfTitle(for: kind)
            let query = CurationQuery(kind: kind, facet: .genre(genre), title: title)
            let items = take(query, count: Curator.shelfSize)
            if items.count >= minimumShelf { genreShelves.append(shelf("genre-\(genre.rawValue)", title, subtitle: nil, items, query: query)) }
        }

        let acclaimedQuery = CurationQuery(kind: kind, facet: .acclaimed, title: "Primés et acclamés")
        let acclaimed = take(acclaimedQuery, count: Curator.shelfSize)
        let frenchTitle = scope == .series ? "Séries françaises" : "Cinéma français"
        let frenchQuery = CurationQuery(kind: kind, facet: .french, title: frenchTitle)
        let french = languages.contains(.french) ? take(frenchQuery, count: Curator.shelfSize) : []
        let popularTitle = switch scope {
        case .home: "Les incontournables"
        case .movies: "Les films incontournables"
        case .series: "Les séries incontournables"
        }
        let popularQuery = CurationQuery(kind: kind, facet: .popular, title: popularTitle)
        let popular = take(popularQuery, count: Curator.shelfSize)
        let classicsQuery = CurationQuery(kind: kind, facet: .classics, title: "Les grands classiques")
        let gemsQuery = CurationQuery(kind: kind, facet: .hiddenGems, title: "Pépites à découvrir")

        shelves.append(contentsOf: charts.dropFirst())
        shelves.append(contentsOf: personal.dropFirst())
        if popular.count >= minimumShelf {
            shelves.append(shelf("popular", popularTitle, subtitle: "Ce que tout le monde a vu, ou devrait voir", popular, query: popularQuery))
        }
        if let first = editorial.first { shelves.append(first) }
        shelves.append(contentsOf: genreShelves.prefix(2))
        if acclaimed.count >= minimumShelf { shelves.append(shelf("acclaimed", acclaimedQuery.title, subtitle: "Oscars, Césars, Emmys et chefs-d’œuvre", acclaimed, query: acclaimedQuery)) }
        if french.count >= minimumShelf { shelves.append(shelf("french", frenchTitle, subtitle: nil, french, query: frenchQuery)) }
        if scope != .home {
            let topRatedQuery = CurationQuery(kind: kind, facet: .topRated, title: "Les mieux notés")
            let topRated = take(topRatedQuery, count: Curator.shelfSize)
            if topRated.count >= minimumShelf {
                shelves.append(shelf("top-rated", topRatedQuery.title, subtitle: "Les meilleures notes du public", topRated, query: topRatedQuery))
            }
        }
        shelves.append(contentsOf: editorial.dropFirst().prefix(1))
        // Themes that give a long page its rhythm: one rotates in on Home, all show on Films and Séries.
        var themes: [CuratedShelf] = []
        let franchiseTitle = scope == .series ? "Univers et franchises" : "Sagas et univers"
        let franchiseQuery = CurationQuery(kind: kind, facet: .franchise, title: franchiseTitle)
        let franchise = take(franchiseQuery, count: Curator.shelfSize)
        if franchise.count >= minimumShelf { themes.append(shelf("franchise", franchiseTitle, subtitle: nil, franchise, query: franchiseQuery)) }
        for decade in rotatingDecades(kind: kind, limit: scope == .home ? 1 : 2) {
            let title = Self.decadeTitle(decade)
            let query = CurationQuery(kind: kind, facet: .decade(decade), title: title)
            let items = take(query, count: Curator.shelfSize)
            if items.count >= minimumShelf { themes.append(shelf("decade-\(decade)", title, subtitle: nil, items, query: query)) }
        }
        let asianTitle = scope == .series ? "K-dramas et séries asiatiques" : "Cinéma asiatique"
        let asianQuery = CurationQuery(kind: kind, facet: .asian, title: asianTitle)
        let asian = take(asianQuery, count: Curator.shelfSize)
        if asian.count >= minimumShelf { themes.append(shelf("asian", asianTitle, subtitle: nil, asian, query: asianQuery)) }
        let uhdQuery = CurationQuery(kind: kind, facet: .uhd, title: "En 4K")
        let uhd = take(uhdQuery, count: Curator.shelfSize)
        if uhd.count >= minimumShelf { themes.append(shelf("uhd", uhdQuery.title, subtitle: "Image Ultra HD", uhd, query: uhdQuery)) }
        if scope == .home {
            shelves.append(contentsOf: rotated(themes, window: themes.count).prefix(1))
            shelves.append(contentsOf: genreShelves.dropFirst(2))
        } else {
            // Alternate genres and themes so neighbouring rows never feel alike.
            var genres = genreShelves.dropFirst(2).makeIterator()
            for theme in themes {
                if let genre = genres.next() { shelves.append(genre) }
                shelves.append(theme)
            }
            while let genre = genres.next() { shelves.append(genre) }
            shelves.append(contentsOf: editorial.dropFirst(2))
        }
        let gems = take(gemsQuery, count: Curator.shelfSize)
        if gems.count >= minimumShelf { shelves.append(shelf("gems", gemsQuery.title, subtitle: "Très bien notés, moins connus", gems, query: gemsQuery)) }
        let classics = take(classicsQuery, count: Curator.shelfSize)
        if classics.count >= minimumShelf { shelves.append(shelf("classics", classicsQuery.title, subtitle: nil, classics, query: classicsQuery)) }
        // Whatever the facets could not place is still worth showing on a sparse page.
        if shelves.count < 4 {
            let discoverQuery = CurationQuery(kind: kind, facet: .discover, title: "À découvrir")
            let rest = take(discoverQuery, count: Curator.shelfSize)
            if !rest.isEmpty { shelves.append(shelf("discover", discoverQuery.title, subtitle: nil, rest, query: discoverQuery)) }
        }

        return CuratedFeed(highlights: highlights, shelves: shelves, genres: genreTiles(kind: kind))
    }

    private func shelf(_ id: String, _ title: String, subtitle: String?, _ items: [MediaTitle], query: CurationQuery?) -> CuratedShelf {
        CuratedShelf(id: id, title: title, subtitle: subtitle, style: .poster, items: items, seeAll: query)
    }

    // MARK: Hero

    private mutating func composeHighlights(scope: CurationScope, trending: [MediaKind: [TitleID]]) -> [CuratedHighlight] {
        var result: [CuratedHighlight] = []
        var picked: Set<TitleID> = []
        func add(_ title: MediaTitle?, label: String?) {
            guard let title, result.count < 6, picked.insert(title.id).inserted else { return }
            result.append(CuratedHighlight(title: present(title), label: label))
        }
        let kinds = scope.kinds
        // 1. The current number one of each kind.
        for kind in kinds {
            let leader = (trending[kind]).flatMap { chart(from: $0, kind: kind, count: 1).first } ?? top(kind, count: 1).first
            // A "number one" needs a real chart behind it; small lists only get a spotlight.
            add(leader, label: isSmall && trending[kind] == nil ? "À la une" : (kind == .movie ? "N° 1 des films" : "N° 1 des séries"))
        }
        // 2. The best fresh releases, with artwork wide enough to carry a hero.
        let fresh = titles(for: CurationQuery(kind: scope.kind, facet: .newReleases, title: ""), limit: 40)
        for title in rotated(fresh.filter { $0.$backdropURL != nil } + fresh.filter { $0.$backdropURL == nil }, window: 8).prefix(4) {
            add(title, label: (title.year ?? 0) >= currentYear - 1 ? "Nouveauté" : "Ajouté récemment")
        }
        // 3. A personal pick, then an acclaimed one.
        if !profile.isEmpty, let mine = titles(for: CurationQuery(kind: scope.kind, facet: .forYou, title: ""), limit: 6).first {
            add(mine, label: "Pour vous")
        }
        for title in rotated(titles(for: CurationQuery(kind: scope.kind, facet: .acclaimed, title: ""), limit: 24), window: 24) {
            if result.count >= 6 { break }
            add(title, label: "Acclamé par la critique")
        }
        // Sparse signals (small or metadata-poor catalogues): the best titles with wide artwork.
        if result.count < 4 {
            let best = titles(for: CurationQuery(kind: scope.kind, facet: .discover, title: ""), limit: 24)
            for title in rotated(best.filter { $0.$backdropURL != nil } + best.filter { $0.$backdropURL == nil }, window: 6) {
                if result.count >= 5 { break }
                add(title, label: nil)
            }
        }
        return result
    }

    // MARK: Selection

    /// Picks the next `count` unused titles for a shelf and marks them used.
    mutating func take(_ query: CurationQuery, count: Int) -> [MediaTitle] {
        var result: [MediaTitle] = []
        var genreCounts: [CanonicalGenre: Int] = [:]
        // Earlier shelves and the genre cap skip many of the best candidates: look deep enough
        // that late rows on long pages still fill up.
        for candidate in candidates(for: query, limit: count * 12) {
            let title = titleAt(candidate.kind, candidate.index)
            guard !used.contains(title.id) else { continue }
            // Diversity: outside genre shelves, no lead genre takes more than a third of the row.
            if !query.facet.isGenre, let lead = index.signals(candidate.kind)[Int(candidate.index)].genres.genres.first {
                if genreCounts[lead, default: 0] >= max(4, count / 3) { continue }
                genreCounts[lead, default: 0] += 1
            }
            let presented = present(title)
            guard RecommendationBuilder.hasLatinTitle(presented.title) else { continue }
            result.append(presented)
            used.insert(title.id)
            if result.count == count { break }
        }
        return result
    }

    /// Ranked titles matching a query (presented names), not deduplicated against other shelves.
    mutating func titles(for query: CurationQuery, limit: Int) -> [MediaTitle] {
        var result: [MediaTitle] = []
        for candidate in candidates(for: query, limit: limit + limit / 4 + 4) {
            let presented = present(titleAt(candidate.kind, candidate.index))
            guard RecommendationBuilder.hasLatinTitle(presented.title) else { continue }
            result.append(presented)
            if result.count == limit { break }
        }
        return result
    }

    struct Candidate {
        let score: Float
        let kind: MediaKind
        let index: Int32
    }

    /// Cache key for memoized candidate scans: kind set and facet fully determine the filtered
    /// ranking; `limit` only controls how deep the scan is extended.
    private struct CandidateKey: Hashable {
        var kind: MediaKind?
        var facet: CurationQuery.Facet
    }

    /// One (kind set, facet) scan: per-kind filtered candidates kept in ranking order plus how
    /// far each kind's eligible pool has been consumed. `seed` is the resolved `.because` anchor.
    private struct CandidateScan {
        struct KindScan {
            var kind: MediaKind
            var candidates: [Candidate] = []
            var rankPosition = 0
            var exhausted = false
        }
        var kinds: [KindScan]
        var seed: (id: TitleID, kind: MediaKind, signals: TitleSignals)?
        var seedChecked = false

        init(kinds: [MediaKind]) {
            self.kinds = kinds.map { KindScan(kind: $0) }
        }
    }

    /// Ranked catalogue positions matching a query, before presentation.
    /// Scans are memoized per (kind set, facet) and extended lazily to the depth each limit
    /// needs; results are identical to rescanning because nothing but `limit` varies between
    /// calls on the same query.
    mutating func candidates(for query: CurationQuery, limit: Int) -> [Candidate] {
        let key = CandidateKey(kind: query.kind, facet: query.facet)
        var scan = candidateScans[key] ?? CandidateScan(kinds: query.kind.map { [$0] } ?? [.movie, .series])
        let poolLimit = limit * 4 + 40
        let followsGeneral = query.facet.followsGeneralScore

        // The "because" seed resolves once per scan; an unresolvable seed yields no candidates.
        if case .because = query.facet, !scan.seedChecked {
            scan.seedChecked = true
            if case .because(let id) = query.facet,
               let title = catalog.title(id), let signals = index.signals(for: title, in: catalog) {
                scan.seed = (title.id, title.kind, signals)
            }
        }
        if case .because = query.facet, scan.seed == nil {
            candidateScans[key] = scan
            return []
        }
        let seed = scan.seed

        // Extend each kind's filtered scan to the depth this request needs (or to exhaustion
        // for facets that do not follow the general ranking). The pool already applied the
        // language/dismissal filters; the facet bitmap skips elements `member` would reject,
        // so every visited element only needs its facet score.
        let usesJitter = query.facet.usesJitter
        for kindIndex in scan.kinds.indices {
            let target = followsGeneral ? poolLimit : Int.max
            guard !scan.kinds[kindIndex].exhausted,
                  scan.kinds[kindIndex].candidates.count < target else { continue }
            let kind = scan.kinds[kindIndex].kind
            let pool = kindPool(for: kind)
            let mask = index.facetMask(kind: kind, facet: query.facet)
            let signals = index.signals(kind)
            while scan.kinds[kindIndex].rankPosition < pool.count,
                  scan.kinds[kindIndex].candidates.count < target {
                let titleIndex = pool[scan.kinds[kindIndex].rankPosition]
                scan.kinds[kindIndex].rankPosition += 1
                if let mask {
                    let bit = Int(titleIndex)
                    guard mask[bit >> 6] & (UInt64(1) << UInt64(bit & 63)) != 0 else { continue }
                }
                // Daily rotation noise is a pure hash: computing it inline beats a random
                // access into a catalog-sized Float table (and its allocation) per feed.
                guard let facetScore = score(
                    signals[Int(titleIndex)], kind: kind, index: titleIndex,
                    jitter: usesJitter ? noise(kind: kind, index: titleIndex) * 0.035 : 0,
                    for: query.facet, seed: seed
                ) else { continue }
                scan.kinds[kindIndex].candidates.append(Candidate(score: facetScore, kind: kind, index: titleIndex))
            }
            scan.kinds[kindIndex].exhausted = scan.kinds[kindIndex].rankPosition >= pool.count
        }
        candidateScans[key] = scan

        // Candidates kept per kind once merged: prefix-bounded for general-ranking facets,
        // exhaustive otherwise.
        var merged = 0
        for kindScan in scan.kinds {
            merged += followsGeneral ? min(kindScan.candidates.count, poolLimit) : kindScan.candidates.count
        }
        if merged > limit {
            return Self.topCandidates(scan.kinds, followsGeneral: followsGeneral, poolLimit: poolLimit, limit: limit)
        }
        var scored: [Candidate] = []
        scored.reserveCapacity(merged)
        for kindScan in scan.kinds {
            if followsGeneral {
                // Rankings are sorted by the general score: once enough candidates are seen for
                // facets that mostly follow it, the long tail cannot win.
                scored.append(contentsOf: kindScan.candidates.prefix(poolLimit))
            } else {
                scored.append(contentsOf: kindScan.candidates)
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : ($0.kind.rawValue, $0.index) < ($1.kind.rawValue, $1.index) }
        return scored
    }

    /// Ranking context of one kind, built on first use and shared by every facet scan:
    /// the ranking's catalogue indices in ranking order after the builder-constant
    /// language/dismissal filters.
    private mutating func kindPool(for kind: MediaKind) -> [Int32] {
        if let pool = kindPools[kind] { return pool }
        let ranking = index.ranking(kind)
        let signals = index.signals(kind)
        // Dismissed titles as catalogue indices: `TitleID` lookups happen once per kind instead
        // of a string hash per scanned element per facet.
        var dismissed: Set<Int32>?
        if !profile.dismissed.isEmpty {
            let lookup = kind == .series ? catalog.indexes.seriesByTitleID : catalog.indexes.movieByTitleID
            var set = Set<Int32>()
            set.reserveCapacity(profile.dismissed.count)
            for id in profile.dismissed {
                if let position = lookup[id] { set.insert(Int32(position)) }
            }
            dismissed = set
        }
        let checksLanguage = index.hasLanguageEvidence
        let hasDismissed = dismissed?.isEmpty == false
        let pool: [Int32]
        if !checksLanguage && !hasDismissed {
            pool = ranking
        } else {
            pool = ranking.filter { titleIndex in
                (!checksLanguage || signals[Int(titleIndex)].matches(audio: audioMask))
                    && !(dismissed?.contains(titleIndex) ?? false)
            }
        }
        kindPools[kind] = pool
        return pool
    }

    /// Top `limit` candidates across the per-kind pools, best first. Equivalent to running
    /// `CatalogBuilder.topIndices` over the concatenated pools — candidates are visited in scan
    /// order and equal scores keep that order — without materializing the merge.
    private static func topCandidates(
        _ kinds: [CandidateScan.KindScan], followsGeneral: Bool, poolLimit: Int, limit: Int
    ) -> [Candidate] {
        guard limit > 0 else { return [] }
        var top: [Candidate] = []
        top.reserveCapacity(limit + 1)
        for kindScan in kinds {
            let pool: ArraySlice<Candidate>
            if followsGeneral {
                pool = kindScan.candidates.prefix(poolLimit)
            } else {
                pool = kindScan.candidates[...]
            }
            for candidate in pool {
                if top.count == limit, candidate.score <= top[top.count - 1].score { continue }
                var low = 0, high = top.count
                while low < high {
                    let mid = (low + high) / 2
                    if top[mid].score >= candidate.score { low = mid + 1 } else { high = mid }
                }
                top.insert(candidate, at: low)
                if top.count > limit { top.removeLast() }
            }
        }
        return top
    }

    /// Facet membership: every rejection condition of the former `score`. Signal-only facets
    /// delegate to `CurationIndex.facetMember` — the same guard its precomputed bitmaps encode,
    /// so a bit test can never disagree with what `score` would return.
    private func member(
        _ signal: TitleSignals, kind: MediaKind, index titleIndex: Int32,
        for facet: CurationQuery.Facet,
        seed: (id: TitleID, kind: MediaKind, signals: TitleSignals)?
    ) -> Bool {
        switch facet {
        case .forYou:
            let isGeneral = signal.flags.isDisjoint(with: [.kids, .regional])
            guard isGeneral, !affinity.isEmpty, !affinity.known.contains(titleKey(kind, titleIndex)) else { return false }
            return affinity.match(signal) > 0.15
        case .because:
            guard let seed, seed.kind == kind, seed.id != titleAt(kind, titleIndex).id,
                  signal.flags.contains(.kids) == seed.signals.flags.contains(.kids), !signal.flags.contains(.regional)
            else { return false }
            return Self.similarity(seed.signals, signal) > 0.25
        default:
            return index.facetMember(signal, kind: kind, facet: facet)
        }
    }

    /// Facet-specific score, or `nil` when the title does not belong to the facet (`member` holds
    /// every rejection condition). `jitter` is the title's daily rotation noise, computed inline
    /// by the caller for jitter-using facets.
    private func score(
        _ signal: TitleSignals, kind: MediaKind, index titleIndex: Int32, jitter: Float,
        for facet: CurationQuery.Facet,
        seed: (id: TitleID, kind: MediaKind, signals: TitleSignals)?
    ) -> Float? {
        guard member(signal, kind: kind, index: titleIndex, for: facet, seed: seed) else { return nil }
        let year = Int(signal.year)
        switch facet {
        case .top:
            let quality = min(max((signal.quality - 5.6) / 2.8, 0), 1)
            let freshness: Float = year >= currentYear ? 1 : (year == currentYear - 1 ? 0.75 : (year == currentYear - 2 ? 0.45 : 0.2))
            return 0.55 * reach(signal) + 0.3 * quality + 0.15 * freshness
        case .newReleases, .platform, .french, .franchise, .uhd, .asian, .discover:
            return signal.score + jitter
        case .forYou:
            // `member` applied the > 0.15 gate; `match` is pure, so recomputing gives the same value.
            return signal.score * 0.6 + affinity.match(signal) * 0.5 + jitter
        case .because:
            guard let seed else { return nil } // unreachable: `member` verified the seed
            let similarity = Self.similarity(seed.signals, signal)
            return similarity * 0.65 + signal.score * 0.45
        case .genre:
            // Titles whose genre list is short are the genre's purest representatives.
            let purity = 1 / Float(max(signal.genres.count, 1))
            return signal.score + 0.05 * purity + jitter
        case .acclaimed:
            let isCanon = signal.flags.contains(.canon)
            return signal.quality / 10 + 0.2 * reach(signal) + (isCanon ? 0.25 : 0) + (signal.isEditorial ? 0.08 : 0) + jitter
        case .classics:
            return signal.quality / 10 + 0.35 * reach(signal) + (signal.flags.contains(.canon) ? 0.2 : 0)
                + (signal.flags.contains(.classic) ? 0.04 : 0) + jitter
        case .hiddenGems:
            return signal.quality / 10 + 0.05 * reach(signal) + jitter
        case .popular:
            let quality = min(max((signal.quality - 5.6) / 2.8, 0), 1)
            return 0.55 * reach(signal) + 0.3 * quality + (signal.flags.contains(.canon) ? 0.22 : 0) + jitter
        case .topRated:
            return signal.quality / 10 + 0.15 * reach(signal) + (signal.flags.contains(.canon) ? (kind == .series ? 0.2 : 0.1) : 0) + jitter
        case .decade:
            let quality = min(max((signal.quality - 5.6) / 2.8, 0), 1)
            return 0.5 * quality + 0.4 * reach(signal) + (signal.flags.contains(.canon) ? 0.15 : 0) + jitter
        }
    }

    private func reach(_ signal: TitleSignals) -> Float {
        min(log2(1 + Float(signal.editions)) / 4, 1)
    }

    static func decadeTitle(_ start: Int) -> String {
        start >= 2000 ? "Les années \(start)" : "Les années \(start % 100)"
    }

    // MARK: Charts

    private mutating func top(_ kind: MediaKind, count: Int) -> [MediaTitle] {
        titles(for: CurationQuery(kind: kind, facet: .top, title: ""), limit: count)
    }

    /// TMDB weekly chart filtered to playable, eligible titles in the user's languages.
    private func chart(from ids: [TitleID], kind: MediaKind, count: Int) -> [MediaTitle] {
        var result: [MediaTitle] = []
        for id in ids {
            guard let title = catalog.title(id), title.kind == kind, !profile.dismissed.contains(id),
                  let signal = index.signals(for: title, in: catalog), signal.isEligible,
                  signal.matches(audio: audioMask) || !index.hasLanguageEvidence else { continue }
            result.append(title)
            if result.count == count { break }
        }
        return result
    }

    // MARK: Rotation

    private mutating func rotatingPlatforms(kind: MediaKind?, limit: Int) -> [StreamingPlatform] {
        let available = StreamingPlatform.allCases.filter { platform in
            candidates(for: CurationQuery(kind: kind, facet: .platform(platform), title: ""), limit: 12).count >= 12
        }
        return Array(rotated(available, window: available.count).prefix(limit))
    }

    /// Decades with a real choice of titles, rotated daily.
    private mutating func rotatingDecades(kind: MediaKind?, limit: Int) -> [Int] {
        let decades = (kind == .series ? [1990, 2000, 2010] : [1970, 1980, 1990, 2000, 2010]).filter { decade in
            candidates(for: CurationQuery(kind: kind, facet: .decade(decade), title: ""), limit: minimumShelf * 2).count >= minimumShelf * 2
        }
        return Array(rotated(decades, window: decades.count).prefix(limit))
    }

    private func rotatingGenres(kind: MediaKind?, limit: Int) -> [CanonicalGenre] {
        var genres = CanonicalGenre.editorialRotation
        if kind == .series { genres.removeAll { $0 == .war || $0 == .western } }
        if kind == .movie { genres.append(.family) }
        return Array(rotated(genres, window: genres.count).prefix(limit))
    }

    /// Deterministic daily permutation of the first `window` elements (the rest keeps its order).
    func rotated<T>(_ items: [T], window: Int) -> [T] {
        guard items.count > 1, window > 1 else { return items }
        let head = items.prefix(window).enumerated().map { offset, item in
            (key: Self.mix(UInt64(day) &* 0x9E37_79B9 &+ UInt64(offset) &* 0x85EB_CA6B), item: item)
        }
        return head.sorted { $0.key < $1.key }.map(\.item) + items.dropFirst(window)
    }

    private func noise(kind: MediaKind, index: Int32) -> Float {
        let value = Self.mix(UInt64(day) &* 31 &+ UInt64(UInt32(bitPattern: index)) &* 2_654_435_761 &+ (kind == .series ? 7 : 0))
        return Float(value % 10_000) / 10_000
    }

    static func mix(_ input: UInt64) -> UInt64 {
        var x = input &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        return x ^ (x >> 31)
    }

    // MARK: Personalisation

    /// The most recent distinct watches with enough genre information to find neighbours.
    private func becauseSeeds(kinds: [MediaKind], limit: Int) -> [MediaTitle] {
        var result: [MediaTitle] = []
        var seenGenres: Set<GenreSet> = []
        for id in profile.watched {
            guard let title = catalog.title(id), kinds.contains(title.kind), !result.contains(where: { $0.id == title.id }),
                  let signal = index.signals(for: title, in: catalog), signal.genres.count > 0,
                  // Two rows about the same kind of story would show the same titles.
                  seenGenres.insert(signal.genres).inserted else { continue }
            result.append(title)
            if result.count == limit { break }
        }
        return result
    }

    static func similarity(_ lhs: TitleSignals, _ rhs: TitleSignals) -> Float {
        let shared = lhs.genres.intersection(rhs.genres).count
        let union = max(lhs.genres.union(rhs.genres).count, 1)
        let genres = Float(shared) / Float(union)
        let platform: Float = lhs.platforms.isDisjoint(with: rhs.platforms) ? 0 : 0.12
        let era: Float = lhs.year > 0 && rhs.year > 0 ? max(0, 1 - Float(abs(Int(lhs.year) - Int(rhs.year))) / 25) * 0.12 : 0
        let origin: Float = lhs.flags.contains(.frenchOrigin) == rhs.flags.contains(.frenchOrigin) ? 0.04 : 0
        return genres * 0.72 + platform + era + origin
    }

    // MARK: Browse tiles

    private func genreTiles(kind: MediaKind?) -> [GenreTile] {
        let genreCount = CanonicalGenre.allCases.count
        var counts = [Int](repeating: 0, count: genreCount)
        // A few of the best titles per genre, so that tiles can avoid repeating the same artwork.
        var best = [[(kind: MediaKind, index: Int32)]](repeating: [], count: genreCount)
        for kind in kind.map({ [$0] }) ?? [.movie, .series] {
            let signals = index.signals(kind)
            // Rankings are best first: the first titles seen for a genre are its best.
            for titleIndex in index.ranking(kind) {
                let signal = signals[Int(titleIndex)]
                guard !index.hasLanguageEvidence || signal.matches(audio: audioMask),
                      !signal.flags.contains(.regional), signal.genres.rawValue != 0 else { continue }
                var bits = signal.genres.rawValue
                while bits != 0 {
                    let genre = bits.trailingZeroBitCount
                    bits &= bits - 1
                    counts[genre] += 1
                    if best[genre].count < 4 { best[genre].append((kind, titleIndex)) }
                }
            }
        }
        var tiles: [GenreTile] = []
        var usedArtwork: Set<TitleID> = []
        let genres = CanonicalGenre.allCases
            .filter { $0 != .sport && counts[$0.rawValue] >= minimumShelf / 2 + 1 && !best[$0.rawValue].isEmpty }
            .sorted { counts[$0.rawValue] > counts[$1.rawValue] }
        for genre in genres {
            let picks = best[genre.rawValue].map { titleAt($0.kind, $0.index) }
            let title = picks.first { !usedArtwork.contains($0.id) } ?? picks[0]
            usedArtwork.insert(title.id)
            tiles.append(GenreTile(genre: genre, kind: kind, count: counts[genre.rawValue], artworkURL: title.backdropURL ?? title.posterURL))
        }
        return tiles
    }

    // MARK: Helpers

    private func titleAt(_ kind: MediaKind, _ index: Int32) -> MediaTitle {
        kind == .series ? catalog.series[Int(index)] : catalog.movies[Int(index)]
    }

    private func titleKey(_ kind: MediaKind, _ index: Int32) -> Int64 {
        (kind == .series ? 1 << 40 : 0) | Int64(index)
    }

    /// The user's preferred name for a title (localized official name when known).
    func present(_ title: MediaTitle) -> MediaTitle {
        var item = recommendations.named(title)
        if let name = recommendations.localizedName(for: title, in: catalog, languages: languages) {
            item.title = name
        }
        return item
    }

    /// Genre and platform weights learnt from the profile.
    private struct Affinity {
        var genres: [Float] = Array(repeating: 0, count: CanonicalGenre.allCases.count)
        var platforms: [Float] = Array(repeating: 0, count: StreamingPlatform.allCases.count)
        var known: Set<Int64> = []
        var total: Float = 0

        var isEmpty: Bool { total == 0 }

        init() {}

        init(profile: CurationProfile, catalog: Catalog, index: CurationIndex) {
            for (list, weight) in [(profile.watched, Float(1.5)), (profile.watchlist, Float(1))] {
                for (offset, id) in list.enumerated() {
                    guard let title = catalog.title(id) else { continue }
                    let position: Int?
                    switch title.kind {
                    case .movie: position = catalog.indexes.movieByTitleID[title.id]
                    case .series: position = catalog.indexes.seriesByTitleID[title.id]
                    default: position = nil
                    }
                    guard let position, let signal = index.signals(for: title, in: catalog) else { continue }
                    known.insert((title.kind == .series ? 1 << 40 : 0) | Int64(position))
                    let decay = weight / (1 + Float(offset) / 5)
                    for genre in signal.genres.genres { genres[genre.rawValue] += decay }
                    for platform in signal.platforms.platforms { platforms[platform.rawValue] += decay * 0.5 }
                    total += decay
                }
            }
        }

        func match(_ signal: TitleSignals) -> Float {
            guard total > 0 else { return 0 }
            var value: Float = 0
            for genre in signal.genres.genres { value += genres[genre.rawValue] }
            value /= total * Float(max(signal.genres.count, 1)).squareRoot()
            for platform in signal.platforms.platforms { value += platforms[platform.rawValue] / total * 0.3 }
            return min(value, 1.2)
        }
    }
}

extension CurationQuery.Facet {
    var isGenre: Bool {
        if case .genre = self { true } else { false }
    }

    /// Facets whose order is close to the general ranking can stop scanning early.
    var followsGeneralScore: Bool {
        switch self {
        case .top, .newReleases, .platform, .french, .discover, .franchise, .uhd, .asian: true
        case .genre: false
        case .forYou, .because, .acclaimed, .classics, .hiddenGems, .popular, .topRated, .decade: false
        }
    }

    /// Facets whose score adds the daily rotation noise (`jitter` in `FeedBuilder.score`);
    /// the jitter table is only built when one of them scans.
    var usesJitter: Bool {
        switch self {
        case .top, .because: false
        case .newReleases, .forYou, .genre, .platform, .acclaimed, .classics, .french, .hiddenGems,
             .popular, .topRated, .decade, .franchise, .uhd, .asian, .discover: true
        }
    }
}
