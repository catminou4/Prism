import Foundation
import PrismCore

public struct CatalogBuildOptions: Sendable, Hashable {
    /// Drops adult items and adult categories.
    public var hideAdult: Bool
    /// Canonical IDs of categories hidden for individual sources, including their variants.
    public var hiddenCategoryIDs: Set<String>

    public init(hideAdult: Bool = false, hiddenCategoryIDs: Set<String> = []) {
        self.hideAdult = hideAdult
        self.hiddenCategoryIDs = hiddenCategoryIDs
    }
}

/// Merges per-source catalogs into one grouped, indexed `Catalog`.
public enum CatalogBuilder {
    /// Groups variants across and inside sources. `sources` order = priority. Disabled sources are excluded.
    @concurrent
    public static func build(sources: [Source], catalogs: [SourceCatalog], options: CatalogBuildOptions = .init()) async -> Catalog {
        let enabled = sources.filter(\.isEnabled)
        var priority: [SourceID: Int] = [:]
        for (index, source) in enabled.enumerated() where priority[source.id] == nil {
            priority[source.id] = index
        }
        // One catalog per enabled source, in priority order.
        var catalogBySource: [SourceID: SourceCatalog] = [:]
        for catalog in catalogs where priority[catalog.sourceID] != nil && catalogBySource[catalog.sourceID] == nil {
            catalogBySource[catalog.sourceID] = catalog
        }
        let ordered = enabled.compactMap { catalogBySource[$0.id] }
        let context = Context(catalogs: ordered, priority: priority, options: options)

        // Normalization keys, then grouping — kept in one scope so the per-item key strings
        // are released when grouping finishes instead of living until `build` returns.
        let (movieGroups, seriesGroups, channelGrouping) = await groupedTitles(ordered: ordered, context: context)
        guard !Task.isCancelled else { return .empty }
        let movies = movieGroups.titles, series = seriesGroups.titles, channels = channelGrouping.groups

        // Categories and rankings are independent: build them concurrently.
        async let liveCategories = categoryGroups(kind: .live, context: context, memberCategoryIDs: channelGrouping.categoryIDs)
        async let movieCategories = categoryGroups(kind: .movie, context: context, memberCategoryIDs: movieGroups.categoryIDs)
        async let seriesCategories = categoryGroups(kind: .series, context: context, memberCategoryIDs: seriesGroups.categoryIDs)
        async let featuredMovies = featuredRanking(movies)
        async let featuredSeries = featuredRanking(series)
        async let topRatedMovies = ratingRanking(movies)
        async let topRatedSeries = ratingRanking(series)

        var indexes = Catalog.Indexes()
        for (index, source) in enabled.enumerated() { indexes.sourceIndex[source.id] = index }
        indexes.categories = context.categories
        indexes.hasTaggedEditions = movieGroups.hasTaggedEditions || seriesGroups.hasTaggedEditions
        for category in context.categories.values where category.kind == .movie || category.kind == .series {
            let languages = ProviderCategoryLanguage.codes(in: category.rawName)
            if !languages.isEmpty { indexes.categoryLanguages[category.id] = languages }
        }
        // Provider-language labels per variant, resolved once: `providerLanguages(for:)` sits on
        // hot audio paths and would otherwise interpolate category prefixes on every call.
        if !indexes.categoryLanguages.isEmpty {
            var languages: [ContentID: Set<String>] = [:]
            for title in movies {
                for variant in title.variants { collectProviderLanguages(variant, categoryLanguages: indexes.categoryLanguages, into: &languages) }
            }
            for title in series {
                for variant in title.variants { collectProviderLanguages(variant, categoryLanguages: indexes.categoryLanguages, into: &languages) }
            }
            indexes.providerLanguages = languages
        }
        indexes.movieByTitleID = movieGroups.titleIndex
        indexes.movieByContent = movieGroups.contentIndex
        indexes.seriesByTitleID = seriesGroups.titleIndex
        indexes.seriesByContent = seriesGroups.contentIndex
        indexes.channelByGroupID = channelGrouping.groupIndex
        indexes.channelByContent = channelGrouping.contentIndex
        let categoryResults = await [liveCategories, movieCategories, seriesCategories]
        for result in categoryResults {
            indexes.categoryToGroup.merge(result.categoryToGroup) { first, _ in first }
            indexes.groupMembers.merge(result.members) { first, _ in first }
            for (offset, group) in result.groups.enumerated() {
                indexes.categoryGroups[group.id] = Catalog.GroupRef(kind: group.kind, index: offset)
            }
        }
        indexes.featuredMovies = await featuredMovies
        indexes.featuredSeries = await featuredSeries
        indexes.topRatedMovies = await topRatedMovies
        indexes.topRatedSeries = await topRatedSeries

        return Catalog(
            sources: enabled, channels: channels, movies: movies, series: series,
            liveCategories: categoryResults[0].groups, movieCategories: categoryResults[1].groups,
            seriesCategories: categoryResults[2].groups, indexes: indexes
        )
    }

    /// Normalization keys (one String per raw item, the expensive part on 150k+ items) followed
    /// by grouping of all three kinds concurrently. Kept in one scope so `keys` is released when
    /// this returns instead of living until `build` returns (audit C5 memory peak).
    private static func groupedTitles(
        ordered: [SourceCatalog], context: Context
    ) async -> (movies: MediaGroups, series: MediaGroups, channels: ChannelGroups) {
        async let movieKeys = parallelKeys(ordered.map(\.movies)) { mediaKey(title: $0.title, rawName: $0.rawName, id: $0.id) }
        async let seriesKeys = parallelKeys(ordered.map(\.series)) { mediaKey(title: $0.title, rawName: $0.rawName, id: $0.id) }
        async let channelKeys = parallelKeys(ordered.map(\.channels)) { channelKey($0) }
        let keys = await (movies: movieKeys, series: seriesKeys, channels: channelKeys)
        guard !Task.isCancelled else { return (MediaGroups(), MediaGroups(), ChannelGroups()) }

        // Grouping: each kind concurrently; title construction is itself chunked in parallel.
        async let movieTitles = groupMedia(kind: .movie, lists: ordered.map(\.movies), keys: keys.movies, context: context)
        async let seriesTitles = groupMedia(kind: .series, lists: ordered.map(\.series), keys: keys.series, context: context)
        async let channelGroups = groupChannels(lists: ordered.map(\.channels), keys: keys.channels, context: context)
        return await (movieTitles, seriesTitles, channelGroups)
    }

    /// Records the declared language labels of one variant (empty when its category has none),
    /// using the same canonical-category resolution as `Catalog.providerLanguages(for:)`.
    private static func collectProviderLanguages(
        _ variant: MediaVariant, categoryLanguages: [String: Set<String>], into result: inout [ContentID: Set<String>]
    ) {
        let category: (id: String?, kind: MediaKind) = switch variant {
        case .movie(let movie): (movie.categoryID, .movie)
        case .series(let series): (series.categoryID, .series)
        }
        guard let id = category.id else {
            result[variant.id] = []
            return
        }
        // Older imports can carry the native category ID instead of the canonical reference.
        let prefix = "\(variant.sourceID.rawValue):\(category.kind.rawValue):"
        let canonicalID = id.hasPrefix(prefix) ? id : prefix + id
        result[variant.id] = categoryLanguages[canonicalID] ?? []
    }

    // MARK: - Context

    struct Context: Sendable {
        let catalogs: [SourceCatalog]
        let priority: [SourceID: Int]
        let options: CatalogBuildOptions
        /// Visible categories, by canonical ID.
        let categories: [String: PrismCore.Category]
        /// The common one-category case shares Set storage across all titles in that category.
        let singleCategorySets: [String: Set<String>]
        /// Per catalog and kind: raw category reference (canonical id or native id) → resolution.
        let resolvers: [[MediaKind: [String: ResolvedCategory]]]

        init(catalogs: [SourceCatalog], priority: [SourceID: Int], options: CatalogBuildOptions) {
            self.catalogs = catalogs
            self.priority = priority
            self.options = options
            var categories: [String: PrismCore.Category] = [:]
            var resolvers: [[MediaKind: [String: ResolvedCategory]]] = []
            for catalog in catalogs {
                var resolver: [MediaKind: [String: ResolvedCategory]] = [:]
                for category in catalog.categories {
                    let isAdult = category.isAdult || TitleNormalizer.isAdult(category.rawName)
                    let hidden = options.hiddenCategoryIDs.contains(category.id) || (options.hideAdult && isAdult)
                    if !hidden {
                        var visible = category
                        visible.isAdult = isAdult
                        categories[category.id] = visible
                    }
                    let resolved = ResolvedCategory(visibleID: hidden ? nil : category.id, isAdult: isAdult, isHidden: hidden)
                    resolver[category.kind, default: [:]][category.id] = resolved
                    if resolver[category.kind]?[category.nativeID] == nil {
                        resolver[category.kind, default: [:]][category.nativeID] = resolved
                    }
                }
                // Xtream can return items after an incomplete category-list response.
                // Apply saved preferences to their native or canonical references in that case as well.
                if !options.hiddenCategoryIDs.isEmpty {
                    for kind in [MediaKind.live, .movie, .series] {
                        let prefix = "\(catalog.sourceID.rawValue):\(kind.rawValue):"
                        for id in options.hiddenCategoryIDs where id.hasPrefix(prefix) {
                            let nativeID = String(id.dropFirst(prefix.count))
                            let hidden = ResolvedCategory(visibleID: nil, isAdult: false, isHidden: true)
                            if resolver[kind]?[id] == nil { resolver[kind, default: [:]][id] = hidden }
                            if resolver[kind]?[nativeID] == nil { resolver[kind, default: [:]][nativeID] = hidden }
                        }
                    }
                }
                resolvers.append(resolver)
            }
            self.categories = categories
            self.singleCategorySets = Dictionary(uniqueKeysWithValues: categories.keys.map { ($0, Set([$0])) })
            self.resolvers = resolvers
        }

        func resolver(catalog: Int, kind: MediaKind) -> [String: ResolvedCategory] {
            resolvers[catalog][kind] ?? [:]
        }
    }

    struct ResolvedCategory: Sendable {
        /// Canonical category ID, `nil` when the category is hidden.
        var visibleID: String?
        var isAdult: Bool
        var isHidden: Bool
    }

    // MARK: - Keys

    static func mediaKey(title: String, rawName: String, id: ContentID) -> String {
        let key = TitleNormalizer.key(title)
        if !key.isEmpty { return key }
        let raw = TitleNormalizer.key(rawName)
        return raw.isEmpty ? "#" + id.rawValue : raw
    }

    static func channelKey(_ channel: Channel) -> String {
        let key = TitleNormalizer.key(channel.name)
        if !key.isEmpty { return key }
        let raw = TitleNormalizer.key(channel.rawName)
        return raw.isEmpty ? "#" + channel.id.rawValue : raw
    }

    static func parallelKeys<T: Sendable>(_ lists: [[T]], key: @escaping @Sendable (T) -> String) async -> [[String]] {
        let total = lists.reduce(0) { $0 + $1.count }
        guard total > 0 else { return lists.map { _ in [] } }
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 12))
        let chunk = max(2_048, total / (workers * 2))
        return await withTaskGroup(of: (Int, Int, [String]).self) { group in
            for (listIndex, list) in lists.enumerated() {
                var start = 0
                while start < list.count {
                    let end = min(start + chunk, list.count)
                    let lower = start
                    group.addTask {
                        guard !Task.isCancelled else { return (listIndex, lower, []) }
                        return (listIndex, lower, list[lower..<end].map(key))
                    }
                    start = end
                }
            }
            var result = lists.map { [String](repeating: "", count: $0.count) }
            for await (listIndex, lower, keys) in group {
                result[listIndex].replaceSubrange(lower..<(lower + keys.count), with: keys)
            }
            return result
        }
    }

    // MARK: - Item resolution

    /// Per-item resolution shared by media and channel grouping, computed once in parallel:
    /// visibility after category filtering, the visible category id, the adult flag and the
    /// grouping shard (key hash). `categories`/`adult` keep the sequential defaults for skipped
    /// items so downstream lookups stay index-aligned.
    struct ResolvedItems: Sendable {
        var categories: [[String?]]
        var adult: [[Bool]]
        var visible: [[Bool]]
        var shards: [[UInt8]]
        var shardCount: Int
        var hasTaggedEditions: Bool
        var hasTMDBIdentity: Bool
    }

    /// One resolved range of a catalog, merged back by position.
    private struct ResolvedPart: Sendable {
        var catalog: Int
        var lower: Int
        var categories: [String?]
        var adult: [Bool]
        var visible: [Bool]
        var shards: [UInt8]
        var taggedEditions: Bool
        var tmdbIdentity: Bool
    }

    /// Resolves category visibility, adult flags and shard assignment for every item in
    /// parallel chunks (per catalog), preserving the exact sequential per-item decisions.
    static func resolveItems<V: Sendable>(
        _ lists: [[V]], keys: [[String]], context: Context, kind: MediaKind,
        categoryID: @escaping @Sendable (V) -> String?,
        isAdult: @escaping @Sendable (V) -> Bool,
        tags: @escaping @Sendable (V) -> [String],
        tmdbID: @escaping @Sendable (V) -> Int?
    ) async -> ResolvedItems {
        let total = lists.reduce(0) { $0 + $1.count }
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 12))
        let shardCount = max(1, min(workers, 8))
        var result = ResolvedItems(
            categories: lists.map { [String?](repeating: nil, count: $0.count) },
            adult: lists.map { [Bool](repeating: false, count: $0.count) },
            visible: lists.map { [Bool](repeating: false, count: $0.count) },
            shards: lists.map { [UInt8](repeating: 0, count: $0.count) },
            shardCount: shardCount,
            hasTaggedEditions: false, hasTMDBIdentity: false
        )
        guard total > 0 else { return result }
        let chunk = max(2_048, total / (workers * 2))
        let parts: [ResolvedPart] = await withTaskGroup(of: ResolvedPart.self) { group in
            for (catalogIndex, list) in lists.enumerated() {
                var start = 0
                while start < list.count {
                    let lower = start, upper = min(start + chunk, list.count)
                    group.addTask {
                        let resolver = context.resolver(catalog: catalogIndex, kind: kind)
                        var cats = [String?](repeating: nil, count: upper - lower)
                        var adultFlags = [Bool](repeating: false, count: upper - lower)
                        var visibleFlags = [Bool](repeating: false, count: upper - lower)
                        var shardIDs = [UInt8](repeating: 0, count: upper - lower)
                        var tagged = false
                        var tmdb = false
                        for index in lower..<upper {
                            let item = list[index]
                            let category = categoryID(item).flatMap { resolver[$0] }
                            let adult = isAdult(item) || category?.isAdult == true
                            let hidden = category?.isHidden == true || (adult && context.options.hideAdult)
                            let offset = index - lower
                            visibleFlags[offset] = !hidden
                            guard !hidden else { continue }
                            cats[offset] = category?.visibleID
                            adultFlags[offset] = adult
                            if !tagged, !tags(item).isEmpty { tagged = true }
                            if !tmdb, let id = tmdbID(item), id > 0 { tmdb = true }
                            shardIDs[offset] = UInt8(StableHash.fnv1a64(keys[catalogIndex][index]) % UInt64(shardCount))
                        }
                        return ResolvedPart(
                            catalog: catalogIndex, lower: lower, categories: cats, adult: adultFlags,
                            visible: visibleFlags, shards: shardIDs,
                            taggedEditions: tagged, tmdbIdentity: tmdb
                        )
                    }
                    start = upper
                }
            }
            var collected: [ResolvedPart] = []
            for await part in group { collected.append(part) }
            return collected
        }
        for part in parts {
            let catalog = part.catalog
            let count = part.categories.count
            result.categories[catalog].replaceSubrange(part.lower..<(part.lower + count), with: part.categories)
            result.adult[catalog].replaceSubrange(part.lower..<(part.lower + count), with: part.adult)
            result.visible[catalog].replaceSubrange(part.lower..<(part.lower + count), with: part.visible)
            result.shards[catalog].replaceSubrange(part.lower..<(part.lower + count), with: part.shards)
            result.hasTaggedEditions = result.hasTaggedEditions || part.taggedEditions
            result.hasTMDBIdentity = result.hasTMDBIdentity || part.tmdbIdentity
        }
        return result
    }

    // MARK: - Movies & series

    struct Ref: Hashable {
        var catalog: Int32
        var item: Int32
    }

    /// Grouping output with its lookup tables (built from flat id arrays to avoid copying titles).
    struct MediaGroups: Sendable {
        var titles: [MediaTitle] = []
        var titleIndex: [TitleID: Int] = [:]
        var contentIndex: [ContentID: Int] = [:]
        /// Category ids per title, in `titles` order.
        var categoryIDs: [Set<String>] = []
        var hasTaggedEditions = false
    }

    /// One key-hash shard's grouping output.
    private struct MediaShard: Sendable {
        var shard: Int
        var groups: [MediaGroup]
    }

    /// Per-chunk output of the parallel title construction.
    private struct BuiltChunk: Sendable {
        var lower: Int
        var titles: [MediaTitle] = []
        var added: [Double] = []
    }

    struct NameIdentity: Hashable, Sendable {
        var key: String
        var year: Int?

        func id(kind: MediaKind) -> TitleID {
            TitleID(kind: kind, normalizedTitle: key, year: year)
        }
    }

    struct MediaGroup: Sendable {
        var name: NameIdentity
        var refs: [Ref]
        var aliases: [NameIdentity] = []
        var tmdbID: Int? = nil
        var ambiguousName = false

        func id(kind: MediaKind) -> TitleID {
            if let tmdbID, ambiguousName || !aliases.isEmpty {
                return TitleID(kind: kind, tmdbID: tmdbID)
            }
            if ambiguousName {
                return TitleID(kind: kind, normalizedTitle: "#unknown:\(name.key)", year: name.year)
            }
            return name.id(kind: kind)
        }
    }

    static func groupMedia<V: GroupableMedia>(kind: MediaKind, lists: [[V]], keys: [[String]], context: Context) async -> MediaGroups {
        let total = lists.reduce(0) { $0 + $1.count }
        guard total > 0 else { return MediaGroups() }
        let categoryKind: MediaKind = kind == .series ? .series : .movie

        // Category/adult resolution and shard assignment run once, in parallel. Grouping is then
        // sharded by key hash: every variant of a work shares its key, so each shard sees
        // complete grouping information and the shards merge back in deterministic order.
        let resolved = await resolveItems(
            lists, keys: keys, context: context, kind: categoryKind,
            categoryID: { $0.categoryID }, isAdult: { $0.isAdult }, tags: { $0.tags }, tmdbID: { $0.tmdbID }
        )
        guard !Task.isCancelled else { return MediaGroups() }

        let shards: [MediaShard] = await withTaskGroup(of: MediaShard.self) { group in
            for shard in 0..<resolved.shardCount {
                group.addTask {
                    var datedGroups: [NameIdentity: Int] = [:]
                    /// Normalized title → its only dated group, or -1 when several years exist.
                    var yearsByKey: [String: Int] = [:]
                    var undatedGroups: [String: Int] = [:]
                    var mediaGroups: [MediaGroup] = []
                    var pendingNoYear: [(key: String, ref: Ref)] = []
                    for (catalogIndex, list) in lists.enumerated() {
                        for (itemIndex, item) in list.enumerated() {
                            guard resolved.visible[catalogIndex][itemIndex],
                                  Int(resolved.shards[catalogIndex][itemIndex]) == shard else { continue }
                            let key = keys[catalogIndex][itemIndex]
                            let ref = Ref(catalog: Int32(catalogIndex), item: Int32(itemIndex))
                            guard let year = item.year else {
                                pendingNoYear.append((key, ref))
                                continue
                            }
                            let dated = NameIdentity(key: key, year: year)
                            if let group = datedGroups[dated] {
                                mediaGroups[group].refs.append(ref)
                            } else {
                                let group = mediaGroups.count
                                mediaGroups.append(MediaGroup(name: dated, refs: [ref]))
                                datedGroups[dated] = group
                                yearsByKey[key] = yearsByKey[key] == nil ? group : -1
                            }
                        }
                    }
                    // A variant without a year joins the only dated group with the same key;
                    // otherwise an undated group.
                    for (key, ref) in pendingNoYear {
                        if let group = yearsByKey[key], group >= 0 {
                            mediaGroups[group].refs.append(ref)
                        } else if let group = undatedGroups[key] {
                            mediaGroups[group].refs.append(ref)
                        } else {
                            let group = mediaGroups.count
                            mediaGroups.append(MediaGroup(name: NameIdentity(key: key, year: nil), refs: [ref]))
                            undatedGroups[key] = group
                        }
                    }
                    return MediaShard(shard: shard, groups: mediaGroups)
                }
            }
            var parts: [MediaShard] = []
            for await part in group { parts.append(part) }
            return parts.sorted { $0.shard < $1.shard }
        }
        guard !Task.isCancelled else { return MediaGroups() }

        // Restore the sequential order — dated groups by first encounter, then undated ones —
        // so editorial aliases and identity reconciliation see the same input as before.
        var dated: [MediaGroup] = []
        var undated: [MediaGroup] = []
        for part in shards {
            for group in part.groups {
                if group.name.year != nil { dated.append(group) } else { undated.append(group) }
            }
        }
        func birthOrder(_ lhs: MediaGroup, _ rhs: MediaGroup) -> Bool {
            let a = lhs.refs.first ?? Ref(catalog: Int32.max, item: Int32.max)
            let b = rhs.refs.first ?? Ref(catalog: Int32.max, item: Int32.max)
            return a.catalog != b.catalog ? a.catalog < b.catalog : a.item < b.item
        }
        dated.sort(by: birthOrder)
        undated.sort(by: birthOrder)
        var mediaGroups: [MediaGroup] = []
        mediaGroups.reserveCapacity(dated.count + undated.count)
        mediaGroups.append(contentsOf: dated)
        mediaGroups.append(contentsOf: undated)

        var datedGroups: [NameIdentity: Int] = Dictionary(minimumCapacity: mediaGroups.count)
        for (index, group) in mediaGroups.enumerated() where group.name.year != nil {
            datedGroups[group.name] = index
        }

        // Build titles in parallel chunks (variant sorting + metadata merge).
        let namedGroups = mergeEditorialAliases(mediaGroups, datedGroups: datedGroups, kind: kind, lists: lists)
        let frozenGroups = resolved.hasTMDBIdentity ? await reconcileMediaIdentities(namedGroups, lists: lists) : namedGroups
        let groupCount = frozenGroups.count
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 12))
        let chunk = max(2_048, groupCount / (workers * 2))
        let frozenCategories = resolved.categories, frozenAdult = resolved.adult
        let chunks: [BuiltChunk] = await withTaskGroup(of: BuiltChunk.self) { group in
            var start = 0
            while start < groupCount {
                let lower = start, upper = min(start + chunk, groupCount)
                group.addTask {
                    var built = BuiltChunk(lower: lower)
                    guard !Task.isCancelled else { return built }
                    built.titles.reserveCapacity(upper - lower)
                    built.added.reserveCapacity(upper - lower)
                    var cleanedGenreLists: [[String]: [String]] = [:]
                    for index in lower..<upper {
                        let offer = frozenGroups[index]
                        var refs = offer.refs
                        if refs.count > 1 {
                            refs.sort { lhs, rhs in
                                variantPrecedes(lists[Int(lhs.catalog)][Int(lhs.item)], rhs: lists[Int(rhs.catalog)][Int(rhs.item)], context: context)
                            }
                        }
                        let title = makeTitle(
                            id: offer.id(kind: kind), kind: kind, year: offer.name.year, refs: refs, lists: lists,
                            categories: frozenCategories, categorySets: context.singleCategorySets, adult: frozenAdult,
                            cleanedGenreLists: &cleanedGenreLists
                        )
                        built.added.append(title.addedAt?.timeIntervalSinceReferenceDate ?? -.infinity)
                        built.titles.append(title)
                    }
                    return built
                }
                start = upper
            }
            var parts: [BuiltChunk] = []
            for await part in group { parts.append(part) }
            return parts.sorted { $0.lower < $1.lower }
        }
        guard !Task.isCancelled else { return MediaGroups() }
        let added = chunks.flatMap(\.added)

        // Order: addedAt desc, then normalized title, then year.
        let order = await parallelSortedIndices(count: groupCount) { lhs, rhs in
            let a = added[lhs], b = added[rhs]
            if a != b { return a > b }
            let left = frozenGroups[lhs], right = frozenGroups[rhs]
            if left.name.key != right.name.key { return left.name.key < right.name.key }
            if left.name.year != right.name.year { return (left.name.year ?? .min) < (right.name.year ?? .min) }
            return (left.tmdbID ?? 0) < (right.tmdbID ?? 0)
        }
        guard !Task.isCancelled else { return MediaGroups() }

        @Sendable func title(at offset: Int) -> MediaTitle {
            chunks[offset / chunk].titles[offset % chunk]
        }
        async let titles = order.map { title(at: $0) }
        async let categories = order.map { title(at: $0).categoryIDs }
        async let titleIndex: [TitleID: Int] = {
            var index: [TitleID: Int] = Dictionary(minimumCapacity: groupCount)
            // Canonical ids first: an alias or translated name must never overwrite another
            // group's real title mapping.
            for (position, group) in order.enumerated() {
                index[title(at: group).id] = position
            }
            for (position, group) in order.enumerated() {
                let media = frozenGroups[group]
                if !media.ambiguousName, !media.aliases.isEmpty {
                    let nameID = media.name.id(kind: kind)
                    if index[nameID] == nil { index[nameID] = position }
                }
                for alias in media.aliases where index[alias.id(kind: kind)] == nil {
                    index[alias.id(kind: kind)] = position
                }
                if let tmdbID = media.tmdbID {
                    let id = TitleID(kind: kind, tmdbID: tmdbID)
                    if index[id] == nil { index[id] = position }
                }
            }
            return index
        }()
        async let contentIndex: [ContentID: Int] = {
            // One entry per variant: the grouped refs are exactly the visible items.
            var index: [ContentID: Int] = Dictionary(minimumCapacity: frozenGroups.reduce(0) { $0 + $1.refs.count })
            for (position, group) in order.enumerated() {
                for variant in title(at: group).variants { index[variant.id] = position }
            }
            return index
        }()
        return await MediaGroups(
            titles: titles, titleIndex: titleIndex, contentIndex: contentIndex,
            categoryIDs: categories, hasTaggedEditions: resolved.hasTaggedEditions
        )
    }

    /// Link known translations only when the exact release year agrees and provider IDs don't conflict.
    /// Saved versions keep resolving through the old grouping keys.
    private static func mergeEditorialAliases<V: GroupableMedia>(
        _ groups: [MediaGroup], datedGroups: [NameIdentity: Int], kind: MediaKind, lists: [[V]]
    ) -> [MediaGroup] {
        var replacements: [Int: MediaGroup] = [:]
        var removed: Set<Int> = []
        for shelf in EditorialSelection.shelves {
            for entry in shelf where entry.kind == kind {
                var offsets: [Int] = []
                for key in entry.aliasKeys {
                    guard let offset = datedGroups[NameIdentity(key: key, year: entry.year)],
                          !removed.contains(offset), replacements[offset] == nil, !offsets.contains(offset)
                    else { continue }
                    offsets.append(offset)
                }
                guard offsets.count > 1, let first = offsets.first else { continue }
                var trustedIDs: Set<Int> = []
                for offset in offsets {
                    for ref in groups[offset].refs {
                        if let id = lists[Int(ref.catalog)][Int(ref.item)].tmdbID, id > 0 { trustedIDs.insert(id) }
                        if trustedIDs.count > 1 { break }
                    }
                    if trustedIDs.count > 1 { break }
                }
                guard trustedIDs.count <= 1 else { continue }
                var merged = groups[first]
                for offset in offsets.dropFirst() {
                    merged.refs.append(contentsOf: groups[offset].refs)
                    merged.aliases.append(groups[offset].name)
                    removed.insert(offset)
                }
                replacements[first] = merged
            }
        }
        guard !removed.isEmpty else { return groups }
        return groups.indices.compactMap { index in
            removed.contains(index) ? nil : replacements[index] ?? groups[index]
        }
    }

    /// Trusted provider IDs link translations, and keep homonyms separate even in the same year.
    /// A provider without an ID joins by name only when that bucket points to one identity.
    /// Large inputs reconcile in contiguous chunks (same per-chunk logic) merged in order, which
    /// preserves the exact sequential output: refs and aliases keep first-appearance order.
    static func reconcileMediaIdentities<V: GroupableMedia>(_ groups: [MediaGroup], lists: [[V]]) async -> [MediaGroup] {
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        guard groups.count >= 8_192, workers > 1 else {
            return reconcileMediaIdentitiesChunk(groups, lists: lists)
        }
        let chunk = (groups.count + workers - 1) / workers
        let parts: [[MediaGroup]] = await withTaskGroup(of: (Int, [MediaGroup]).self) { group in
            for lower in stride(from: 0, to: groups.count, by: chunk) {
                let upper = min(lower + chunk, groups.count)
                group.addTask {
                    (lower, reconcileMediaIdentitiesChunk(Array(groups[lower..<upper]), lists: lists))
                }
            }
            var collected: [(Int, [MediaGroup])] = []
            for await part in group { collected.append(part) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        // Ordered merge applying the same identity rules across chunk boundaries.
        var result: [MediaGroup] = []
        result.reserveCapacity(groups.count)
        var byTMDBID: [Int: Int] = [:]
        for part in parts {
            for group in part {
                guard let tmdbID = group.tmdbID, tmdbID > 0 else {
                    result.append(group)
                    continue
                }
                if let index = byTMDBID[tmdbID] {
                    result[index].refs.append(contentsOf: group.refs)
                    if !group.ambiguousName { result[index].aliases.append(group.name) }
                    result[index].aliases.append(contentsOf: group.aliases)
                } else {
                    byTMDBID[tmdbID] = result.count
                    result.append(group)
                }
            }
        }
        return result
    }

    /// The reconciliation pass itself, run sequentially or once per chunk.
    private static func reconcileMediaIdentitiesChunk<V: GroupableMedia>(_ groups: [MediaGroup], lists: [[V]]) -> [MediaGroup] {
        var result: [MediaGroup] = []
        result.reserveCapacity(groups.count)
        var byTMDBID: [Int: Int] = [:]

        func addIdentified(_ group: MediaGroup, tmdbID: Int) {
            if let index = byTMDBID[tmdbID] {
                result[index].refs.append(contentsOf: group.refs)
                if !group.ambiguousName { result[index].aliases.append(group.name) }
                result[index].aliases.append(contentsOf: group.aliases)
            } else {
                byTMDBID[tmdbID] = result.count
                result.append(group)
            }
        }

        for group in groups {
            if group.refs.count == 1, let ref = group.refs.first {
                guard let id = lists[Int(ref.catalog)][Int(ref.item)].tmdbID, id > 0 else {
                    result.append(group)
                    continue
                }
                var identified = group
                identified.tmdbID = id
                addIdentified(identified, tmdbID: id)
                continue
            }

            var identified: [Int: [Ref]] = [:]
            var unidentified: [Ref] = []
            for ref in group.refs {
                if let id = lists[Int(ref.catalog)][Int(ref.item)].tmdbID, id > 0 {
                    identified[id, default: []].append(ref)
                } else {
                    unidentified.append(ref)
                }
            }

            switch identified.count {
            case 0:
                result.append(group)
            case 1:
                if let id = identified.keys.first {
                    var linked = group
                    linked.tmdbID = id
                    addIdentified(linked, tmdbID: id)
                }
            default:
                for id in identified.keys.sorted() {
                    guard let refs = identified[id] else { continue }
                    addIdentified(MediaGroup(name: group.name, refs: refs, tmdbID: id, ambiguousName: true), tmdbID: id)
                }
                if !unidentified.isEmpty {
                    result.append(MediaGroup(name: group.name, refs: unidentified, ambiguousName: true))
                }
            }
        }
        return result
    }

    /// Sorts `0..<count` with `areInIncreasingOrder`: chunks sorted concurrently, then merged.
    static func parallelSortedIndices(count: Int, by areInIncreasingOrder: @escaping @Sendable (Int, Int) -> Bool) async -> [Int] {
        guard count > 1 else { return Array(0..<count) }
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        guard count >= 8_192, workers > 1 else { return (0..<count).sorted(by: areInIncreasingOrder) }
        let chunk = (count + workers - 1) / workers
        var runs: [[Int]] = await withTaskGroup(of: (Int, [Int]).self) { group in
            for lower in stride(from: 0, to: count, by: chunk) {
                let upper = min(lower + chunk, count)
                group.addTask { (lower, (lower..<upper).sorted(by: areInIncreasingOrder)) }
            }
            var parts: [(Int, [Int])] = []
            for await part in group { parts.append(part) }
            return parts.sorted { $0.0 < $1.0 }.map(\.1)
        }
        while runs.count > 1 {
            let current = runs
            runs = await withTaskGroup(of: (Int, [Int]).self) { group in
                for pair in stride(from: 0, to: current.count, by: 2) {
                    group.addTask {
                        guard pair + 1 < current.count else { return (pair, current[pair]) }
                        return (pair, merge(current[pair], current[pair + 1], by: areInIncreasingOrder))
                    }
                }
                var parts: [(Int, [Int])] = []
                for await part in group { parts.append(part) }
                return parts.sorted { $0.0 < $1.0 }.map(\.1)
            }
        }
        return runs.first ?? []
    }

    /// Stable merge of two sorted runs (ties keep `left` first).
    static func merge(_ left: [Int], _ right: [Int], by areInIncreasingOrder: (Int, Int) -> Bool) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(left.count + right.count)
        var i = 0, j = 0
        while i < left.count && j < right.count {
            if areInIncreasingOrder(right[j], left[i]) {
                result.append(right[j]); j += 1
            } else {
                result.append(left[i]); i += 1
            }
        }
        result.append(contentsOf: left[i...])
        result.append(contentsOf: right[j...])
        return result
    }

    static func variantPrecedes<V: GroupableMedia>(_ lhs: V, rhs: V, context: Context) -> Bool {
        let pl = context.priority[lhs.sourceID] ?? .max, pr = context.priority[rhs.sourceID] ?? .max
        if pl != pr { return pl < pr }
        if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
        let ll = lhs.rawName.utf8.count, lr = rhs.rawName.utf8.count
        if ll != lr { return ll < lr }
        return lhs.id < rhs.id
    }

    static func makeTitle<V: GroupableMedia>(
        id: TitleID, kind: MediaKind, year: Int?, refs: [Ref], lists: [[V]],
        categories: [[String?]], categorySets: [String: Set<String>], adult: [[Bool]],
        cleanedGenreLists: inout [[String]: [String]]
    ) -> MediaTitle {
        let first = lists[Int(refs[0].catalog)][Int(refs[0].item)]
        if refs.count == 1 {
            let ref = refs[0]
            let rating = first.rating.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            var single = MediaTitle(
                id: id,
                kind: kind, title: first.title, year: year ?? first.year, variants: [first.mediaVariant],
                plot: cleanPlot(first.plot),
                genres: cleanGenres(first.genres, cache: &cleanedGenreLists), rating: rating, addedAt: first.addedAt,
                categoryIDs: categories[Int(ref.catalog)][Int(ref.item)].flatMap { categorySets[$0] } ?? [],
                isAdult: adult[Int(ref.catalog)][Int(ref.item)]
            )
            // Artwork addresses are shared with the variant as text, never re-parsed.
            single.$posterURL = first.posterText
            single.$backdropURL = first.backdropText
            return single
        }
        var variants: [MediaVariant] = []
        variants.reserveCapacity(refs.count)
        var title = first.title
        var bestNaturalness = TextFolding.naturalnessScore(first.title)
        var resolvedYear = year
        var poster: String?
        var backdrop: String?
        var plot: String?
        var plotLength = 0
        var genres: [String] = []
        var seenGenres: Set<String> = []
        var rating: Double?
        var addedAt: Date?
        var categoryIDs: Set<String> = []
        var isAdult = false

        for (offset, ref) in refs.enumerated() {
            let item = lists[Int(ref.catalog)][Int(ref.item)]
            variants.append(item.mediaVariant)
            if offset > 0, item.title != title {
                let score = TextFolding.naturalnessScore(item.title)
                if score > bestNaturalness {
                    bestNaturalness = score
                    title = item.title
                }
            }
            if resolvedYear == nil { resolvedYear = item.year }
            if poster == nil { poster = item.posterText }
            if backdrop == nil { backdrop = item.backdropText }
            if let candidate = cleanPlot(item.plot), candidate.utf8.count > plotLength {
                plot = candidate
                plotLength = candidate.utf8.count
            }
            for genre in cleanGenres(item.genres, cache: &cleanedGenreLists) {
                if seenGenres.insert(TextFolding.fold(genre)).inserted { genres.append(genre) }
            }
            if let value = item.rating, value.isFinite, value > 0 { rating = max(rating ?? 0, value) }
            if let date = item.addedAt { addedAt = max(addedAt ?? date, date) }
            if let category = categories[Int(ref.catalog)][Int(ref.item)] {
                if categoryIDs.isEmpty {
                    categoryIDs = categorySets[category] ?? [category]
                } else if !categoryIDs.contains(category) {
                    categoryIDs.insert(category)
                }
            }
            if adult[Int(ref.catalog)][Int(ref.item)] { isAdult = true }
        }

        var grouped = MediaTitle(
            id: id,
            kind: kind, title: title, year: resolvedYear, variants: variants,
            plot: plot, genres: genres,
            rating: rating, addedAt: addedAt, categoryIDs: categoryIDs, isAdult: isAdult
        )
        grouped.$posterURL = poster
        grouped.$backdropURL = backdrop
        return grouped
    }

    static func trimmed(_ text: String) -> String {
        guard let first = text.unicodeScalars.first, let last = text.unicodeScalars.last else { return text }
        if CharacterSet.whitespacesAndNewlines.contains(first) || CharacterSet.whitespacesAndNewlines.contains(last) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    static func cleanPlot(_ plot: String?) -> String? {
        ProviderSynopsis.cleaned(plot)
    }

    static func cleanGenres(_ genres: [String], cache: inout [[String]: [String]]) -> [String] {
        guard !genres.isEmpty else { return [] }
        if let cleaned = cache[genres] { return cleaned }
        let cleaned = cleanGenres(genres)
        if cache.count < 256 { cache[genres] = cleaned }
        return cleaned
    }

    private static func cleanGenres(_ genres: [String]) -> [String] {
        if genres.count == 1, let only = genres.first {
            let value = trimmed(only)
            return value.isEmpty ? [] : [value]
        }
        var seen: Set<String> = []
        var result: [String] = []
        for genre in genres {
            let value = trimmed(genre)
            guard !value.isEmpty else { continue }
            if seen.insert(TextFolding.fold(value)).inserted { result.append(value) }
        }
        return result
    }

    // MARK: - Channels

    struct ChannelGroups: Sendable {
        var groups: [ChannelGroup] = []
        var groupIndex: [String: Int] = [:]
        var contentIndex: [ContentID: Int] = [:]
        var categoryIDs: [Set<String>] = []
    }

    static func groupChannels(lists: [[Channel]], keys: [[String]], context: Context) async -> ChannelGroups {
        let total = lists.reduce(0) { $0 + $1.count }
        guard total > 0 else { return ChannelGroups() }

        // Same sharded grouping as media: every channel sharing a key lands in one shard, each
        // shard builds finished groups, and the merged list is sorted once. The sort key
        // (number, id) is total, so the result matches the sequential pass exactly.
        let resolved = await resolveItems(
            lists, keys: keys, context: context, kind: .live,
            categoryID: { $0.categoryID }, isAdult: { $0.isAdult }, tags: { $0.tags }, tmdbID: { _ in nil }
        )
        guard !Task.isCancelled else { return ChannelGroups() }

        let parts: [[ChannelGroup]] = await withTaskGroup(of: (Int, [ChannelGroup]).self) { group in
            for shard in 0..<resolved.shardCount {
                group.addTask {
                    var groupIndex: [String: Int] = [:]
                    var groupKeys: [String] = []
                    var members: [[Channel]] = []
                    var categoryIDs: [Set<String>] = []
                    var adultFlags: [Bool] = []
                    for (catalogIndex, list) in lists.enumerated() {
                        for (itemIndex, channel) in list.enumerated() {
                            guard resolved.visible[catalogIndex][itemIndex],
                                  Int(resolved.shards[catalogIndex][itemIndex]) == shard else { continue }
                            let key = keys[catalogIndex][itemIndex]
                            let group: Int
                            if let existing = groupIndex[key] {
                                group = existing
                            } else {
                                group = groupKeys.count
                                groupIndex[key] = group
                                groupKeys.append(key)
                                members.append([])
                                categoryIDs.append([])
                                adultFlags.append(false)
                            }
                            members[group].append(channel)
                            if let visible = resolved.categories[catalogIndex][itemIndex] { categoryIDs[group].insert(visible) }
                            if resolved.adult[catalogIndex][itemIndex] { adultFlags[group] = true }
                        }
                    }

                    var groups: [ChannelGroup] = []
                    groups.reserveCapacity(groupKeys.count)
                    for group in groupKeys.indices {
                        var variants = members[group]
                        if variants.count > 1 {
                            variants.sort { lhs, rhs in
                                let pl = context.priority[lhs.sourceID] ?? .max, pr = context.priority[rhs.sourceID] ?? .max
                                if pl != pr { return pl < pr }
                                if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
                                let ll = lhs.rawName.utf8.count, lr = rhs.rawName.utf8.count
                                if ll != lr { return ll < lr }
                                return lhs.id < rhs.id
                            }
                        }
                        var name = variants[0].name
                        if variants.count > 1 {
                            var best = TextFolding.naturalnessScore(name)
                            for variant in variants.dropFirst() where variant.name != name {
                                let score = TextFolding.naturalnessScore(variant.name)
                                if score > best { best = score; name = variant.name }
                            }
                        }
                        let number = variants.lazy.compactMap(\.number).min()
                        var channelGroup = ChannelGroup(
                            id: groupKeys[group],
                            name: name,
                            number: number,
                            epgID: variants.lazy.compactMap { $0.epgID?.isEmpty == false ? $0.epgID : nil }.first,
                            variants: variants,
                            categoryIDs: categoryIDs[group],
                            isAdult: adultFlags[group]
                        )
                        channelGroup.$logoURL = variants.lazy.compactMap(\.$logoURL).first
                        groups.append(channelGroup)
                    }
                    return (shard, groups)
                }
            }
            var collected: [(Int, [ChannelGroup])] = []
            for await part in group { collected.append(part) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        guard !Task.isCancelled else { return ChannelGroups() }

        var groups: [ChannelGroup] = []
        groups.reserveCapacity(parts.reduce(0) { $0 + $1.count })
        for part in parts { groups.append(contentsOf: part) }

        // Sort: number asc (nil last), then name key.
        var order = Array(groups.indices)
        order.sort { lhs, rhs in
            let a = groups[lhs].number, b = groups[rhs].number
            if a != b {
                guard let a else { return false }
                guard let b else { return true }
                return a < b
            }
            return groups[lhs].id < groups[rhs].id
        }
        var output = ChannelGroups()
        output.groups = order.map { groups[$0] }
        output.categoryIDs = order.map { groups[$0].categoryIDs }
        output.groupIndex = Dictionary(minimumCapacity: order.count)
        output.contentIndex = Dictionary(minimumCapacity: groups.reduce(0) { $0 + $1.variants.count })
        for (position, group) in order.enumerated() {
            output.groupIndex[groups[group].id] = position
            for channel in groups[group].variants { output.contentIndex[channel.id] = position }
        }
        return output
    }

    // MARK: - Categories

    struct CategoryResult: Sendable {
        var groups: [CategoryGroup] = []
        var categoryToGroup: [String: String] = [:]
        var members: [String: [Int32]] = [:]
    }

    static func categoryGroups(kind: MediaKind, context: Context, memberCategoryIDs: [Set<String>]) -> CategoryResult {
        var output = CategoryResult()
        var groups: [CategoryGroup] = []
        var groupByKey: [String: Int] = [:]
        var naturalness: [Int] = []
        for catalog in context.catalogs {
            let categories = catalog.categories.enumerated()
                .filter { $0.element.kind == kind }
                .sorted { $0.element.sortIndex != $1.element.sortIndex ? $0.element.sortIndex < $1.element.sortIndex : $0.offset < $1.offset }
                .map(\.element)
            for category in categories {
                guard let visible = context.categories[category.id] else { continue }
                let nameKey = TitleNormalizer.key(visible.name)
                let groupID = nameKey.isEmpty ? "\(kind.rawValue):#\(visible.id)" : "\(kind.rawValue):\(nameKey)"
                output.categoryToGroup[visible.id] = groupID
                if let existing = groupByKey[groupID] {
                    groups[existing].categoryIDs.append(visible.id)
                    if visible.isAdult { groups[existing].isAdult = true }
                    let score = TextFolding.naturalnessScore(visible.name)
                    if score > naturalness[existing] {
                        naturalness[existing] = score
                        groups[existing].name = visible.name
                    }
                } else {
                    groupByKey[groupID] = groups.count
                    naturalness.append(TextFolding.naturalnessScore(visible.name))
                    groups.append(CategoryGroup(
                        id: groupID, kind: kind, name: visible.name, categoryIDs: [visible.id],
                        itemCount: 0, isAdult: visible.isAdult, sortIndex: groups.count
                    ))
                }
            }
        }
        guard !groups.isEmpty else { return output }

        var members = [[Int32]](repeating: [], count: groups.count)
        for (index, categoryIDs) in memberCategoryIDs.enumerated() where !categoryIDs.isEmpty {
            if categoryIDs.count == 1, let only = categoryIDs.first {
                if let groupID = output.categoryToGroup[only], let group = groupByKey[groupID] {
                    members[group].append(Int32(index))
                }
                continue
            }
            var seen: Set<Int> = []
            for categoryID in categoryIDs {
                guard let groupID = output.categoryToGroup[categoryID], let group = groupByKey[groupID] else { continue }
                if seen.insert(group).inserted { members[group].append(Int32(index)) }
            }
        }
        // Titles are visited in catalog order, so every member list is already sorted.

        var result: [CategoryGroup] = []
        result.reserveCapacity(groups.count)
        for (offset, var group) in groups.enumerated() where !members[offset].isEmpty {
            group.itemCount = members[offset].count
            group.sortIndex = result.count
            output.members[group.id] = members[offset]
            result.append(group)
        }
        output.groups = result
        return output
    }

    // MARK: - Rankings

    static func featuredRanking(_ titles: [MediaTitle], poolSize: Int = 60) -> [Int32] {
        guard !titles.isEmpty else { return [] }
        let newest = titles.lazy.compactMap(\.addedAt).max()
        var scored: [(score: Double, index: Int32)] = []
        scored.reserveCapacity(titles.count)
        for (index, title) in titles.enumerated() {
            var score = 0.0
            if title.$backdropURL != nil { score += 100 }
            if title.$posterURL != nil {
                score += (title.plot?.utf8.count ?? 0) >= 40 ? 40 : 10
            } else if (title.plot?.utf8.count ?? 0) >= 40 {
                score += 5
            }
            if let rating = title.rating { score += min(max(rating, 0), 10) * 2 }
            if let newest, let added = title.addedAt {
                let days = max(0, newest.timeIntervalSince(added) / 86_400)
                score += max(0, 30 - days / 6)
            }
            score += Double(min(title.variants.count, 4))
            if title.isAdult { score -= 1_000 }
            scored.append((score, Int32(index)))
        }
        return topIndices(scored, count: poolSize)
    }

    static func ratingRanking(_ titles: [MediaTitle], poolSize: Int = 300) -> [Int32] {
        var scored: [(score: Double, index: Int32)] = []
        for (index, title) in titles.enumerated() {
            guard let rating = title.rating, rating > 0, !title.isAdult else { continue }
            var score = min(rating, 10) * 1_000
            if title.$posterURL != nil { score += 10 }
            score += Double(min(title.variants.count, 9))
            scored.append((score, Int32(index)))
        }
        return topIndices(scored, count: poolSize)
    }

    /// Deterministic top-k (score desc, then index asc) without sorting the whole array.
    static func topIndices(_ scored: some Sequence<(score: Double, index: Int32)>, count: Int) -> [Int32] {
        var top: [(score: Double, index: Int32)] = []
        top.reserveCapacity(count + 1)
        for entry in scored {
            if top.count == count, let last = top.last, !(entry.score > last.score) { continue }
            var low = 0, high = top.count
            while low < high {
                let mid = (low + high) / 2
                let other = top[mid]
                if other.score > entry.score || (other.score == entry.score && other.index < entry.index) {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            top.insert(entry, at: low)
            if top.count > count { top.removeLast() }
        }
        return top.map(\.index)
    }
}

// MARK: - Groupable media

/// Common surface of `Movie` and `Series` used by the grouping code.
protocol GroupableMedia: Sendable {
    var id: ContentID { get }
    var sourceID: SourceID { get }
    var title: String { get }
    var rawName: String { get }
    var year: Int? { get }
    var tmdbID: Int? { get }
    var quality: VideoQuality { get }
    var posterURL: URL? { get }
    var backdropURL: URL? { get }
    /// Artwork addresses as stored (no parsing).
    var posterText: String? { get }
    var backdropText: String? { get }
    var plot: String? { get }
    var genres: [String] { get }
    var rating: Double? { get }
    var addedAt: Date? { get }
    var categoryID: String? { get }
    var tags: [String] { get }
    var isAdult: Bool { get }
    var mediaVariant: MediaVariant { get }
}

extension Movie: GroupableMedia {
    var mediaVariant: MediaVariant { .movie(self) }
    var posterText: String? { $posterURL }
    var backdropText: String? { $backdropURL }
}

extension Series: GroupableMedia {
    var mediaVariant: MediaVariant { .series(self) }
    var posterText: String? { $posterURL }
    var backdropText: String? { $backdropURL }
}
