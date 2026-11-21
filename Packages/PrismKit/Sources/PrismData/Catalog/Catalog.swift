import Foundation
import PrismCore

/// The merged, indexed, immutable snapshot of every enabled source that the UI reads.
///
/// Built off the main actor by `CatalogBuilder`. Every lookup is O(1) (dictionaries built once);
/// per-category item lists are precomputed index arrays.
public struct Catalog: Sendable {
    public static let empty = Catalog(
        sources: [], channels: [], movies: [], series: [],
        liveCategories: [], movieCategories: [], seriesCategories: [],
        indexes: Indexes()
    )

    public let sources: [Source]
    /// Sorted by number ascending (channels without number last), then name.
    public let channels: [ChannelGroup]
    /// Sorted by `addedAt` descending, then title.
    public let movies: [MediaTitle]
    /// Sorted by `addedAt` descending, then title.
    public let series: [MediaTitle]
    /// Sorted by `sortIndex` (first source order, then appearance).
    public let liveCategories: [CategoryGroup]
    public let movieCategories: [CategoryGroup]
    public let seriesCategories: [CategoryGroup]

    let indexes: Indexes

    /// Lookup tables, built once by `CatalogBuilder`.
    struct Indexes: Sendable {
        var sourceIndex: [SourceID: Int] = [:]
        var categories: [String: PrismCore.Category] = [:]
        var hasTaggedEditions = false
        var categoryLanguages: [String: Set<String>] = [:]
        /// Category group id → (kind, index in the kind's category array).
        var categoryGroups: [String: GroupRef] = [:]
        /// Raw category id → category group id.
        var categoryToGroup: [String: String] = [:]
        var movieByTitleID: [TitleID: Int] = [:]
        var seriesByTitleID: [TitleID: Int] = [:]
        var channelByGroupID: [String: Int] = [:]
        /// Movie variant content id → index in `movies`.
        var movieByContent: [ContentID: Int] = [:]
        /// Series variant content id → index in `series`.
        var seriesByContent: [ContentID: Int] = [:]
        /// Channel variant content id → index in `channels`.
        var channelByContent: [ContentID: Int] = [:]
        /// Category group id → indices in the matching kind array (catalog order).
        var groupMembers: [String: [Int32]] = [:]
        /// Precomputed hero candidates, best first.
        var featuredMovies: [Int32] = []
        var featuredSeries: [Int32] = []
        /// Precomputed rating ranking (only rated titles), best first.
        var topRatedMovies: [Int32] = []
        var topRatedSeries: [Int32] = []
    }

    struct GroupRef: Sendable, Hashable {
        var kind: MediaKind
        var index: Int
    }

    init(
        sources: [Source], channels: [ChannelGroup], movies: [MediaTitle], series: [MediaTitle],
        liveCategories: [CategoryGroup], movieCategories: [CategoryGroup], seriesCategories: [CategoryGroup],
        indexes: Indexes
    ) {
        self.sources = sources
        self.channels = channels
        self.movies = movies
        self.series = series
        self.liveCategories = liveCategories
        self.movieCategories = movieCategories
        self.seriesCategories = seriesCategories
        self.indexes = indexes
    }

    public var isEmpty: Bool { channels.isEmpty && movies.isEmpty && series.isEmpty }

    // MARK: - Lookups

    public func source(_ id: SourceID) -> Source? {
        indexes.sourceIndex[id].map { sources[$0] }
    }

    public func category(_ id: String) -> PrismCore.Category? {
        indexes.categories[id]
    }

    /// Declared language labels from this edition's provider category (ISO 639-1).
    public func providerLanguages(for variant: MediaVariant) -> Set<String> {
        guard !indexes.categoryLanguages.isEmpty else { return [] }
        let category: (id: String?, kind: MediaKind) = switch variant {
        case .movie(let movie): (movie.categoryID, .movie)
        case .series(let series): (series.categoryID, .series)
        }
        guard let id = category.id else { return [] }
        // Older imports can carry the native category ID instead of the canonical reference.
        let prefix = "\(variant.sourceID.rawValue):\(category.kind.rawValue):"
        let canonicalID = id.hasPrefix(prefix) ? id : prefix + id
        return indexes.categoryLanguages[canonicalID] ?? []
    }

    public func categoryGroup(_ id: String) -> CategoryGroup? {
        guard let ref = indexes.categoryGroups[id] else { return nil }
        return categoryGroups(ref.kind)[ref.index]
    }

    /// The category group containing a raw (per-source) category id.
    public func categoryGroup(containingCategory categoryID: String) -> CategoryGroup? {
        indexes.categoryToGroup[categoryID].flatMap { categoryGroup($0) }
    }

    /// Category groups of a kind (`.live`, `.movie`, `.series`).
    public func categoryGroups(_ kind: MediaKind) -> [CategoryGroup] {
        switch kind {
        case .live: liveCategories
        case .movie: movieCategories
        case .series, .episode: seriesCategories
        }
    }

    public func title(_ id: TitleID) -> MediaTitle? {
        if let index = indexes.movieByTitleID[id] { return movies[index] }
        if let index = indexes.seriesByTitleID[id] { return series[index] }
        return nil
    }

    public func channelGroup(_ id: String) -> ChannelGroup? {
        indexes.channelByGroupID[id].map { channels[$0] }
    }

    /// The next or previous channel in catalog order, wrapping at either end.
    public func adjacentChannel(to id: String, forward: Bool) -> ChannelGroup? {
        guard channels.count > 1, let index = indexes.channelByGroupID[id] else { return nil }
        return channels[(index + (forward ? 1 : channels.count - 1)) % channels.count]
    }

    public func titles(in group: CategoryGroup) -> [MediaTitle] {
        guard let members = indexes.groupMembers[group.id] else { return [] }
        switch group.kind {
        case .movie: return members.map { movies[Int($0)] }
        case .series: return members.map { series[Int($0)] }
        case .live, .episode: return []
        }
    }

    public func channels(in group: CategoryGroup) -> [ChannelGroup] {
        guard group.kind == .live, let members = indexes.groupMembers[group.id] else { return [] }
        return members.map { channels[Int($0)] }
    }

    /// Movie or series variant id → grouped title id.
    public func titleID(containing content: ContentID) -> TitleID? {
        if let index = indexes.movieByContent[content] { return movies[index].id }
        if let index = indexes.seriesByContent[content] { return series[index].id }
        return nil
    }

    public func channelGroupID(containing content: ContentID) -> String? {
        indexes.channelByContent[content].map { channels[$0].id }
    }

    public func movie(_ id: ContentID) -> Movie? {
        guard let index = indexes.movieByContent[id] else { return nil }
        return movies[index].variants.lazy.compactMap(\.movie).first { $0.id == id }
    }

    public func series(_ id: ContentID) -> Series? {
        guard let index = indexes.seriesByContent[id] else { return nil }
        return series[index].variants.lazy.compactMap(\.series).first { $0.id == id }
    }

    public func channel(_ id: ContentID) -> Channel? {
        guard let index = indexes.channelByContent[id] else { return nil }
        return channels[index].variants.first { $0.id == id }
    }

    // MARK: - Shelves

    public func recentlyAdded(_ kind: MediaKind, limit: Int) -> [MediaTitle] {
        guard limit > 0 else { return [] }
        let list = kind == .movie ? movies : (kind == .series ? series : [])
        return Array(list.prefix(limit))
    }

    /// Hero candidates: items with a backdrop first, then poster + plot, recent and well rated;
    /// alternates movies and series. Deterministic for a given catalog.
    public func featured(limit: Int) -> [MediaTitle] {
        guard limit > 0 else { return [] }
        var result: [MediaTitle] = []
        result.reserveCapacity(limit)
        var m = indexes.featuredMovies.makeIterator()
        var s = indexes.featuredSeries.makeIterator()
        var movieTurn = true
        while result.count < limit {
            if movieTurn, let index = m.next() {
                result.append(movies[Int(index)])
            } else if !movieTurn, let index = s.next() {
                result.append(series[Int(index)])
            } else if let index = m.next() {
                result.append(movies[Int(index)])
            } else if let index = s.next() {
                result.append(series[Int(index)])
            } else {
                break
            }
            movieTurn.toggle()
        }
        return result
    }

    /// Titles sharing categories and genres with `title`, excluding itself. Deterministic.
    public func related(to title: MediaTitle, limit: Int) -> [MediaTitle] {
        guard limit > 0 else { return [] }
        let list = title.kind == .series ? series : movies
        guard !list.isEmpty else { return [] }
        let genres = Set(title.genres.map { TextFolding.fold($0) })
        let groupIDs = Set(title.categoryIDs.compactMap { indexes.categoryToGroup[$0] })

        var candidateHits: [Int32: Int] = [:]
        let perGroupScanLimit = 2_000
        for groupID in groupIDs.sorted() {
            guard let members = indexes.groupMembers[groupID] else { continue }
            for index in members.prefix(perGroupScanLimit) {
                candidateHits[index, default: 0] += 1
            }
        }
        if candidateHits.count < limit, !genres.isEmpty {
            // Small or missing categories: widen with genre matches among recent titles.
            for (offset, other) in list.prefix(5_000).enumerated() where candidateHits[Int32(offset)] == nil {
                if other.genres.contains(where: { genres.contains(TextFolding.fold($0)) }) {
                    candidateHits[Int32(offset)] = 0
                    if candidateHits.count >= limit * 4 { break }
                }
            }
        }

        var scored: [(score: Double, index: Int32)] = []
        scored.reserveCapacity(candidateHits.count)
        for (index, sharedGroups) in candidateHits {
            let other = list[Int(index)]
            guard other.id != title.id, title.isAdult || !other.isAdult else { continue }
            var score = Double(sharedGroups) * 2
            if !genres.isEmpty {
                let shared = other.genres.reduce(0) { $0 + (genres.contains(TextFolding.fold($1)) ? 1 : 0) }
                score += Double(shared) * 3
            }
            if other.posterURL != nil { score += 1 }
            if let rating = other.rating { score += min(max(rating, 0), 10) / 10 }
            scored.append((score, index))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return scored.prefix(limit).map { list[Int($0.index)] }
    }

    public func topRated(_ kind: MediaKind, limit: Int) -> [MediaTitle] {
        guard limit > 0 else { return [] }
        switch kind {
        case .movie: return indexes.topRatedMovies.prefix(limit).map { movies[Int($0)] }
        case .series: return indexes.topRatedSeries.prefix(limit).map { series[Int($0)] }
        case .live, .episode: return []
        }
    }

    /// Number of grouped items offering at least one variant from `source` (O(n), for settings screens).
    public func counts(for source: SourceID) -> ImportCounts {
        ImportCounts(
            channels: channels.reduce(0) { $0 + ($1.variants.contains { $0.sourceID == source } ? 1 : 0) },
            movies: movies.reduce(0) { $0 + ($1.variants.contains { $0.sourceID == source } ? 1 : 0) },
            series: series.reduce(0) { $0 + ($1.variants.contains { $0.sourceID == source } ? 1 : 0) }
        )
    }
}
