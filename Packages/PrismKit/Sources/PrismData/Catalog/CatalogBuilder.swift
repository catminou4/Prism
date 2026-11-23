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
        let groupedStart = ContinuousClock.now
        let (movieGroups, seriesGroups, channelGrouping) = await groupedTitles(ordered: ordered, context: context)
        BuildProfile.mark("groupedTitles (keys+grouping)", since: groupedStart)
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
        let indexesStart = ContinuousClock.now
        for (index, source) in enabled.enumerated() { indexes.sourceIndex[source.id] = index }
        indexes.categories = context.categories
        indexes.hasTaggedEditions = movieGroups.hasTaggedEditions || seriesGroups.hasTaggedEditions
        for category in context.categories.values where category.kind == .movie || category.kind == .series {
            let languages = ProviderCategoryLanguage.codes(in: category.rawName)
            if !languages.isEmpty { indexes.categoryLanguages[category.id] = languages }
        }
        // Provider-language labels per variant, resolved once: `providerLanguages(for:)` sits on
        // hot audio paths and would otherwise interpolate category prefixes on every call.
        let providerLangsStart = ContinuousClock.now
        if !indexes.categoryLanguages.isEmpty {
            let languageMaps = providerLanguageMaps(context: context, categoryLanguages: indexes.categoryLanguages)
            var languages: [ContentID: Set<String>] = [:]
            for title in movies {
                for variant in title.variants {
                    collectProviderLanguages(variant, languageMaps: languageMaps, categoryLanguages: indexes.categoryLanguages, into: &languages)
                }
            }
            for title in series {
                for variant in title.variants {
                    collectProviderLanguages(variant, languageMaps: languageMaps, categoryLanguages: indexes.categoryLanguages, into: &languages)
                }
            }
            indexes.providerLanguages = languages
        }
        BuildProfile.mark("providerLanguages", since: providerLangsStart)
        indexes.movieByTitleID = movieGroups.titleIndex
        indexes.movieByContent = movieGroups.contentIndex
        indexes.seriesByTitleID = seriesGroups.titleIndex
        indexes.seriesByContent = seriesGroups.contentIndex
        indexes.channelByGroupID = channelGrouping.groupIndex
        indexes.channelByContent = channelGrouping.contentIndex
        BuildProfile.mark("index assembly (sync)", since: indexesStart)
        let awaitStart = ContinuousClock.now
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
        BuildProfile.mark("categories+rankings (async)", since: awaitStart)

        let result = Catalog(
            sources: enabled, channels: channels, movies: movies, series: series,
            liveCategories: categoryResults[0].groups, movieCategories: categoryResults[1].groups,
            seriesCategories: categoryResults[2].groups, indexes: indexes
        )
        if let dumpPath = ProcessInfo.processInfo.environment["PRISM_CATALOG_DUMP"] {
            dumpCatalogForVerification(result, to: dumpPath)
        }
        return result
    }

    /// Normalization keys (one String per raw item, the expensive part on 150k+ items) followed
    /// by grouping of all three kinds concurrently. Kept in one scope so `keys` is released when
    /// this returns instead of living until `build` returns (audit C5 memory peak).
    private static func groupedTitles(
        ordered: [SourceCatalog], context: Context
    ) async -> (movies: MediaGroups, series: MediaGroups, channels: ChannelGroups) {
        let keysStart = ContinuousClock.now
        async let movieKeys = parallelKeys(ordered.map(\.movies), label: "keys.movies") { mediaKey(title: $0.title, rawName: $0.rawName, id: $0.id) }
        async let seriesKeys = parallelKeys(ordered.map(\.series), label: "keys.series") { mediaKey(title: $0.title, rawName: $0.rawName, id: $0.id) }
        async let channelKeys = parallelKeys(ordered.map(\.channels), label: "keys.channels") { channelKey($0) }
        let keys = await (movies: movieKeys, series: seriesKeys, channels: channelKeys)
        BuildProfile.mark("keys (all 3 parallel)", since: keysStart)
        guard !Task.isCancelled else { return (MediaGroups(), MediaGroups(), ChannelGroups()) }

        // Grouping: each kind concurrently; title construction is itself chunked in parallel.
        let groupStart = ContinuousClock.now
        async let movieTitles = groupMedia(kind: .movie, lists: ordered.map(\.movies), keys: keys.movies, context: context)
        async let seriesTitles = groupMedia(kind: .series, lists: ordered.map(\.series), keys: keys.series, context: context)
        async let channelGroups = groupChannels(lists: ordered.map(\.channels), keys: keys.channels, context: context)
        let result = await (movieTitles, seriesTitles, channelGroups)
        BuildProfile.mark("grouping (all 3 parallel)", since: groupStart)
        return result
    }

    /// Per source+kind category lookups for `collectProviderLanguages`: canonical category ids
    /// and native ids each map to the declared language labels, mirroring the syntactic
    /// canonicalization `Catalog.providerLanguages(for:)` performs per variant.
    struct ProviderLanguageMaps {
        /// `"<sourceID>:<kind>:"` prefix used to tell canonical ids from native ones.
        var prefix: String
        /// Canonical category id → languages (only consulted for prefixed ids).
        var canonical: [String: Set<String>]
        /// Native category id → languages (first registration wins, like `Context.resolvers`).
        var native: [String: Set<String>]
    }

    /// Builds the per-(source, kind) language maps once: ~#categories work instead of
    /// interpolating `"source:kind:"` prefixes for every one of ~250k variants.
    static func providerLanguageMaps(
        context: Context, categoryLanguages: [String: Set<String>]
    ) -> [SourceID: [MediaKind: ProviderLanguageMaps]] {
        var maps: [SourceID: [MediaKind: ProviderLanguageMaps]] = [:]
        for catalog in context.catalogs {
            for kind in [MediaKind.movie, .series] {
                var canonical: [String: Set<String>] = [:]
                var native: [String: Set<String>] = [:]
                for category in catalog.categories where category.kind == kind {
                    canonical[category.id] = categoryLanguages[category.id] ?? []
                }
                for category in catalog.categories where category.kind == kind {
                    if native[category.nativeID] == nil {
                        native[category.nativeID] = categoryLanguages[category.id] ?? []
                    }
                }
                maps[catalog.sourceID, default: [:]][kind] = ProviderLanguageMaps(
                    prefix: "\(catalog.sourceID.rawValue):\(kind.rawValue):",
                    canonical: canonical, native: native
                )
            }
        }
        return maps
    }

    /// Records the declared language labels of one variant (empty when its category has none),
    /// using the same canonical-category resolution as `Catalog.providerLanguages(for:)`.
    private static func collectProviderLanguages(
        _ variant: MediaVariant, languageMaps: [SourceID: [MediaKind: ProviderLanguageMaps]],
        categoryLanguages: [String: Set<String>], into result: inout [ContentID: Set<String>]
    ) {
        let category: (id: String?, kind: MediaKind) = switch variant {
        case .movie(let movie): (movie.categoryID, .movie)
        case .series(let series): (series.categoryID, .series)
        }
        guard let id = category.id else {
            result[variant.id] = []
            return
        }
        if let maps = languageMaps[variant.sourceID]?[category.kind] {
            // Same rule as before: a prefixed id is already canonical, anything else is native.
            result[variant.id] = id.hasPrefix(maps.prefix)
                ? (maps.canonical[id] ?? [])
                : (maps.native[id] ?? [])
        } else {
            // Defensive fallback (a variant whose source has no catalog entry): keep the
            // original syntactic canonicalization.
            let prefix = "\(variant.sourceID.rawValue):\(category.kind.rawValue):"
            let canonicalID = id.hasPrefix(prefix) ? id : prefix + id
            result[variant.id] = categoryLanguages[canonicalID] ?? []
        }
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

    static func parallelKeys<T: Sendable>(_ lists: [[T]], label: String = "", key: @escaping @Sendable (T) -> String) async -> [[String]] {
        let total = lists.reduce(0) { $0 + $1.count }
        guard total > 0 else { return lists.map { _ in [] } }
        let start = ContinuousClock.now
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 12))
        let chunk = max(2_048, total / (workers * 2))
        let result = await withTaskGroup(of: (Int, Int, [String]).self) { group in
            for (listIndex, list) in lists.enumerated() {
                var start = 0
                while start < list.count {
                    let end = min(start + chunk, list.count)
                    let lower = start
                    group.addTask {
                        guard !Task.isCancelled else { return (listIndex, lower, []) }
                        // Indexed loop, not `map`: the sequence iterator hands out an owned
                        // copy of every element (a full `Movie` copy + its retains); the
                        // subscript passes a borrow to `key`.
                        var keys: [String] = []
                        keys.reserveCapacity(end - lower)
                        for index in lower..<end { keys.append(key(list[index])) }
                        return (listIndex, lower, keys)
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
        BuildProfile.mark(label, since: start)
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

    /// Per-chunk output of the parallel title construction.
    private struct BuiltChunk: Sendable {
        var lower: Int
        var titles: [MediaTitle] = []
        var added: [Double] = []
        var elapsed: Double = 0
        var refsProcessed: Int = 0
        var multiVariant: Int = 0
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
        let label = kind == .movie ? "movies" : "series"
        let phaseStart = ContinuousClock.now

        var datedGroups: [NameIdentity: Int] = Dictionary(minimumCapacity: total)
        /// Normalized title → its only dated group, or -1 when several years exist.
        var yearsByKey: [String: Int] = Dictionary(minimumCapacity: total)
        var undatedGroups: [String: Int] = [:]
        var mediaGroups: [MediaGroup] = []
        mediaGroups.reserveCapacity(total)
        var pendingNoYear: [(key: String, ref: Ref)] = []
        var resolvedCategories: [[String?]] = []
        var adultFlags: [[Bool]] = []
        var hasTMDBIdentity = false
        var hasTaggedEditions = false

        for (catalogIndex, list) in lists.enumerated() {
            var cats = [String?](repeating: nil, count: list.count)
            var adult = [Bool](repeating: false, count: list.count)
            let resolver = context.resolver(catalog: catalogIndex, kind: categoryKind)
            let listKeys = keys[catalogIndex]
            for (itemIndex, item) in list.enumerated() {
                let category = item.categoryID.flatMap { resolver[$0] }
                let isAdult = item.isAdult || category?.isAdult == true
                if category?.isHidden == true || (isAdult && context.options.hideAdult) { continue }
                if !hasTaggedEditions, !item.tags.isEmpty { hasTaggedEditions = true }
                adult[itemIndex] = isAdult
                cats[itemIndex] = category?.visibleID
                if !hasTMDBIdentity, let tmdbID = item.tmdbID, tmdbID > 0 { hasTMDBIdentity = true }
                let key = listKeys[itemIndex]
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
            resolvedCategories.append(cats)
            adultFlags.append(adult)
        }
        // A variant without a year joins the only dated group with the same key; otherwise an undated group.
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
        BuildProfile.mark("\(label) group-loop", since: phaseStart)

        // Build titles in parallel chunks (variant sorting + metadata merge).
        guard !Task.isCancelled else { return MediaGroups() }
        let mergeStart = ContinuousClock.now
        let namedGroups = mergeEditorialAliases(mediaGroups, datedGroups: datedGroups, kind: kind, lists: lists)
        BuildProfile.mark("\(label) editorial-aliases", since: mergeStart)
        let reconcileStart = ContinuousClock.now
        let frozenGroups = hasTMDBIdentity ? await reconcileMediaIdentities(namedGroups, lists: lists) : namedGroups
        BuildProfile.mark("\(label) reconcile-ids", since: reconcileStart)
        let groupCount = frozenGroups.count
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 12))
        let chunk = max(2_048, groupCount / (workers * 2))
        let frozenCategories = resolvedCategories, frozenAdult = adultFlags
        let plotsCleaned = context.catalogs.map(\.plotsCleaned)
        // Variant ordering hoisted out of the comparator: every item of a catalog shares its
        // sourceID, so priority is a per-catalog array lookup, and the name byte length is
        // computed once per item instead of twice per comparison.
        let catalogPriority = context.catalogs.map { context.priority[$0.sourceID] ?? .max }
        let nameLengths = lists.map { list in list.map { $0.rawName.utf8.count } }
        let chunksStart = ContinuousClock.now
        let chunks: [BuiltChunk] = await withTaskGroup(of: BuiltChunk.self) { group in
            var start = 0
            while start < groupCount {
                let lower = start, upper = min(start + chunk, groupCount)
                group.addTask {
                    var built = BuiltChunk(lower: lower)
                    let chunkStart = ContinuousClock.now
                    guard !Task.isCancelled else { return built }
                    built.titles.reserveCapacity(upper - lower)
                    built.added.reserveCapacity(upper - lower)
                    var cleanedGenreLists: [[String]: [String]] = [:]
                    for index in lower..<upper {
                        let offer = frozenGroups[index]
                        built.refsProcessed += offer.refs.count
                        if offer.refs.count > 1 { built.multiVariant += 1 }
                        var refs = offer.refs
                        if refs.count > 1 {
                            refs.sort { lhs, rhs in
                                let lhsCatalog = Int(lhs.catalog), rhsCatalog = Int(rhs.catalog)
                                let lhsPriority = catalogPriority[lhsCatalog], rhsPriority = catalogPriority[rhsCatalog]
                                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                                // Field reads through the subscripts, never `let item = lists[…][…]`:
                                // binding the element copies the whole struct (~15 retains on
                                // strings shared catalogue-wide by `shareRepeatedValues`, contended
                                // across the parallel chunks) — that copy was ~45 % of build CPU.
                                let lhsItem = Int(lhs.item), rhsItem = Int(rhs.item)
                                let lhsQuality = lists[lhsCatalog][lhsItem].quality, rhsQuality = lists[rhsCatalog][rhsItem].quality
                                if lhsQuality != rhsQuality { return lhsQuality > rhsQuality }
                                let lhsLength = nameLengths[lhsCatalog][lhsItem], rhsLength = nameLengths[rhsCatalog][rhsItem]
                                if lhsLength != rhsLength { return lhsLength < rhsLength }
                                return lists[lhsCatalog][lhsItem].id < lists[rhsCatalog][rhsItem].id
                            }
                        }
                        let title = makeTitle(
                            id: offer.id(kind: kind), kind: kind, year: offer.name.year, refs: refs, lists: lists,
                            categories: frozenCategories, categorySets: context.singleCategorySets, adult: frozenAdult,
                            plotsCleaned: plotsCleaned, cleanedGenreLists: &cleanedGenreLists
                        )
                        built.added.append(title.addedAt?.timeIntervalSinceReferenceDate ?? -.infinity)
                        built.titles.append(title)
                    }
                    let e = ContinuousClock.now - chunkStart
                    built.elapsed = Double(e.components.seconds) * 1_000 + Double(e.components.attoseconds) / 1e15
                    return built
                }
                start = upper
            }
            var parts: [BuiltChunk] = []
            for await part in group { parts.append(part) }
            return parts.sorted { $0.lower < $1.lower }
        }
        BuildProfile.mark("\(label) makeTitle chunks", since: chunksStart)
        if BuildProfile.enabled {
            let refs = chunks.reduce(0) { $0 + $1.refsProcessed }
            let multi = chunks.reduce(0) { $0 + $1.multiVariant }
            let times = chunks.map(\.elapsed).sorted(by: >)
            let slowest = times.prefix(4).map { String(format: "%.0f", $0) }.joined(separator: ",")
            FileHandle.standardError.write(Data("[profile] \(label) chunks: \(chunks.count) chunks, \(refs) refs, \(multi) multi-variant; slowest ms: \(slowest)\n".utf8))
        }
        guard !Task.isCancelled else { return MediaGroups() }
        let added = chunks.flatMap(\.added)

        // Order: addedAt desc, then normalized title, then year.
        let sortStart = ContinuousClock.now
        let order = await parallelSortedIndices(count: groupCount) { lhs, rhs in
            let a = added[lhs], b = added[rhs]
            if a != b { return a > b }
            let left = frozenGroups[lhs], right = frozenGroups[rhs]
            if left.name.key != right.name.key { return left.name.key < right.name.key }
            if left.name.year != right.name.year { return (left.name.year ?? .min) < (right.name.year ?? .min) }
            return (left.tmdbID ?? 0) < (right.tmdbID ?? 0)
        }
        BuildProfile.mark("\(label) sort order", since: sortStart)
        guard !Task.isCancelled else { return MediaGroups() }

        let finalStart = ContinuousClock.now

        @Sendable func title(at offset: Int) -> MediaTitle {
            chunks[offset / chunk].titles[offset % chunk]
        }
        async let titles = order.map { title(at: $0) }
        async let categories = order.map { title(at: $0).categoryIDs }
        async let titleIndex: [TitleID: Int] = {
            var index: [TitleID: Int] = Dictionary(minimumCapacity: groupCount)
            for (position, group) in order.enumerated() {
                let media = frozenGroups[group]
                let id = title(at: group).id
                index[id] = position
                if !media.ambiguousName, !media.aliases.isEmpty { index[media.name.id(kind: kind)] = position }
                for alias in media.aliases { index[alias.id(kind: kind)] = position }
                if let tmdbID = media.tmdbID { index[TitleID(kind: kind, tmdbID: tmdbID)] = position }
            }
            return index
        }()
        async let contentIndex: [ContentID: Int] = {
            var index: [ContentID: Int] = Dictionary(minimumCapacity: total)
            for (position, group) in order.enumerated() {
                for variant in title(at: group).variants { index[variant.id] = position }
            }
            return index
        }()
        let result = await MediaGroups(
            titles: titles, titleIndex: titleIndex, contentIndex: contentIndex,
            categoryIDs: categories, hasTaggedEditions: hasTaggedEditions
        )
        BuildProfile.mark("\(label) final indexes", since: finalStart)
        return result
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
        let partsStart = ContinuousClock.now
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
        BuildProfile.mark("reconcile chunks (\(groups.count) groups)", since: partsStart)
        let mergeStart = ContinuousClock.now
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
        BuildProfile.mark("reconcile merge", since: mergeStart)
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

            // Most multi-variant groups share zero or one provider id: detect that without
            // allocating the per-id buckets (only conflicting ids need the full split below).
            var singleID: Int? = nil
            var conflicting = false
            for ref in group.refs {
                guard let id = lists[Int(ref.catalog)][Int(ref.item)].tmdbID, id > 0 else { continue }
                if singleID == nil {
                    singleID = id
                } else if id != singleID {
                    conflicting = true
                    break
                }
            }
            if !conflicting {
                guard let id = singleID else {
                    result.append(group)
                    continue
                }
                var linked = group
                linked.tmdbID = id
                addIdentified(linked, tmdbID: id)
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

            for id in identified.keys.sorted() {
                guard let refs = identified[id] else { continue }
                addIdentified(MediaGroup(name: group.name, refs: refs, tmdbID: id, ambiguousName: true), tmdbID: id)
            }
            if !unidentified.isEmpty {
                result.append(MediaGroup(name: group.name, refs: unidentified, ambiguousName: true))
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

    static func makeTitle<V: GroupableMedia>(
        id: TitleID, kind: MediaKind, year: Int?, refs: [Ref], lists: [[V]],
        categories: [[String?]], categorySets: [String: Set<String>], adult: [[Bool]],
        plotsCleaned: [Bool] = [], cleanedGenreLists: inout [[String]: [String]]
    ) -> MediaTitle {
        /// Catalogues imported with `SourceCatalog.cleaningPlots()` already hold
        /// `ProviderSynopsis.cleaned` output: the selection below uses it as-is.
        func isClean(_ ref: Ref) -> Bool {
            let index = Int(ref.catalog)
            return index < plotsCleaned.count && plotsCleaned[index]
        }
        // `first` is read field by field (see the loop below for why no element binding).
        let firstList = Int(refs[0].catalog), firstIndex = Int(refs[0].item)
        if refs.count == 1 {
            let ref = refs[0]
            let rating = lists[firstList][firstIndex].rating.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            var cleanedPlot: String? = nil
            if let raw = lists[firstList][firstIndex].plot {
                cleanedPlot = isClean(ref) || plotProfile(raw).passthrough ? raw : cleanPlot(raw)
            }
            let cleanedGenres = cleanGenres(lists[firstList][firstIndex].genres, cache: &cleanedGenreLists)
            var single = MediaTitle(
                id: id,
                kind: kind, title: lists[firstList][firstIndex].title, year: year ?? lists[firstList][firstIndex].year, variants: [lists[firstList][firstIndex].mediaVariant],
                plot: cleanedPlot,
                genres: cleanedGenres, rating: rating, addedAt: lists[firstList][firstIndex].addedAt,
                categoryIDs: categories[Int(ref.catalog)][Int(ref.item)].flatMap { categorySets[$0] } ?? [],
                isAdult: adult[Int(ref.catalog)][Int(ref.item)]
            )
            // Artwork addresses are shared with the variant as text, never re-parsed.
            single.$posterURL = lists[firstList][firstIndex].posterText
            single.$backdropURL = lists[firstList][firstIndex].backdropText
            return single
        }
        var variants: [MediaVariant] = []
        variants.reserveCapacity(refs.count)
        var title = lists[firstList][firstIndex].title
        var bestNaturalness = TextFolding.naturalnessScore(lists[firstList][firstIndex].title)
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
            // Fields are read through the subscripts: a `let item = lists[…][…]` binding
            // copies the whole struct (and retains every shared string in it) a second time
            // on top of the `mediaVariant` copy the title actually keeps.
            let list = Int(ref.catalog), index = Int(ref.item)
            variants.append(lists[list][index].mediaVariant)
            if offset > 0, lists[list][index].title != title {
                let candidate = lists[list][index].title
                let score = TextFolding.naturalnessScore(candidate)
                if score > bestNaturalness {
                    bestNaturalness = score
                    title = candidate
                }
            }
            if resolvedYear == nil { resolvedYear = lists[list][index].year }
            if poster == nil { poster = lists[list][index].posterText }
            if backdrop == nil { backdrop = lists[list][index].backdropText }
            // `cleaned` never lengthens a plot (it only trims and drops text), so a variant
            // whose raw plot can't beat the current best cleaned length is skipped without
            // paying for synopsis normalization — the common case is duplicate plots.
            // `plotProfile` additionally detects plots `cleaned` would return unchanged,
            // skipping the regex/NLP path for clean provider prose entirely.
            if let rawPlot = lists[list][index].plot {
                let clean = isClean(ref)
                let profile = clean ? (bytes: rawPlot.utf8.count, passthrough: true) : plotProfile(rawPlot)
                if profile.bytes > plotLength {
                    if profile.passthrough {
                        plot = rawPlot
                        plotLength = profile.bytes
                    } else if let candidate = cleanPlot(rawPlot), candidate.utf8.count > plotLength {
                        plot = candidate
                        plotLength = candidate.utf8.count
                    }
                }
            }
            for genre in cleanGenres(lists[list][index].genres, cache: &cleanedGenreLists) {
                if seenGenres.insert(TextFolding.fold(genre)).inserted { genres.append(genre) }
            }
            if let value = lists[list][index].rating, value.isFinite, value > 0 { rating = max(rating ?? 0, value) }
            if let date = lists[list][index].addedAt { addedAt = max(addedAt ?? date, date) }
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

    /// Decodes the UTF-8 scalar starting at `i` (which must be a lead byte). Input is a valid
    /// Swift string, so continuation bytes need no validation.
    private static func decodeUTF8Scalar(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int) -> UInt32? {
        let b0 = p[i]
        if b0 < 0x80 { return UInt32(b0) }
        let length = b0 < 0xE0 ? 2 : (b0 < 0xF0 ? 3 : 4)
        guard i + length <= end else { return nil }
        var value = UInt32(b0) & (length == 2 ? 0x1F : (length == 3 ? 0x0F : 0x07))
        for j in 1..<length { value = (value << 6) | (UInt32(p[i + j]) & 0x3F) }
        return value
    }

    /// Byte offset where the last UTF-8 scalar of `p[0..<end]` starts (scans back over the
    /// ≤3 continuation bytes that may precede it).
    private static func lastScalarOffset(_ p: UnsafePointer<UInt8>, _ end: Int) -> Int? {
        var i = end - 1
        var steps = 0
        while i > 0 && steps < 3 && (p[i] & 0xC0) == 0x80 {
            i -= 1
            steps += 1
        }
        return (p[i] & 0xC0) != 0x80 ? i : nil
    }

    /// Whether `ProviderSynopsis.cleaned` would return `p[0..<bytes]` unchanged. See
    /// `plotProfile` for the exact equivalence argument.
    private static func plotIsPassthrough(_ p: UnsafePointer<UInt8>, _ bytes: Int) -> Bool {
        var previousWasSpace = false
        var i = 0
        while i < bytes {
            let b = p[i]
            if b == 0x20 {
                if previousWasSpace { return false }
                previousWasSpace = true
            } else {
                previousWasSpace = false
                if b >= 0x09 && b <= 0x0D { return false }
                if b == 0xC2, i + 1 < bytes, p[i + 1] == 0x85 { return false }
                if b == 0xE2, i + 2 < bytes, p[i + 1] == 0x80, p[i + 2] == 0xA8 || p[i + 2] == 0xA9 {
                    return false
                }
            }
            i += 1
        }
        // `cleaned` also trims when the first or last scalar is whitespace; decode just those two.
        guard let firstScalar = decodeUTF8Scalar(p, 0, bytes),
              let lastOffset = lastScalarOffset(p, bytes),
              let lastScalar = decodeUTF8Scalar(p, lastOffset, bytes),
              let first = Unicode.Scalar(firstScalar), let last = Unicode.Scalar(lastScalar)
        else { return false }
        let whitespace = CharacterSet.whitespacesAndNewlines
        return !whitespace.contains(first) && !whitespace.contains(last)
    }

    /// One pass over the plot's UTF-8 answering both the byte length used by the
    /// longest-cleaned-plot selection and whether `ProviderSynopsis.cleaned` would return the
    /// text unchanged — letting callers skip the regex/NLP path for clean provider prose.
    ///
    /// `cleaned` returns its input unchanged exactly when the text is non-empty, has no
    /// whitespace at either edge (`CharacterSet.whitespacesAndNewlines`), and
    /// `needsNormalization` finds none of {double space, 0x09–0x0D, 0x85, 0x2028, 0x2029}.
    /// Those scalars are matched on raw UTF-8: the encoding is self-synchronizing, so `0x20`,
    /// `0x09`–`0x0D` can only be the ASCII scalars themselves and `C2 85`, `E2 80 A8`,
    /// `E2 80 A9` only encode U+0085, U+2028, U+2029 — never bytes inside another character.
    static func plotProfile(_ text: String) -> (bytes: Int, passthrough: Bool) {
        guard let result = text.utf8.withContiguousStorageIfAvailable({ buffer in
            let bytes = buffer.count
            let passthrough = bytes > 0
                && buffer.baseAddress.map { plotIsPassthrough($0, bytes) } == true
            return (bytes, passthrough)
        }) else {
            // Non-contiguous storage: stay conservative and let `cleaned` decide.
            return (text.utf8.count, false)
        }
        return result
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
        let phaseStart = ContinuousClock.now
        var groupIndex: [String: Int] = Dictionary(minimumCapacity: total)
        var groupKeys: [String] = []
        var members: [[Channel]] = []
        var categoryIDs: [Set<String>] = []
        var adultFlags: [Bool] = []

        for (catalogIndex, list) in lists.enumerated() {
            let resolver = context.resolver(catalog: catalogIndex, kind: .live)
            for (itemIndex, channel) in list.enumerated() {
                let category = channel.categoryID.flatMap { resolver[$0] }
                let isAdult = channel.isAdult || category?.isAdult == true
                if category?.isHidden == true || (isAdult && context.options.hideAdult) { continue }
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
                if let visible = category?.visibleID { categoryIDs[group].insert(visible) }
                if isAdult { adultFlags[group] = true }
            }
        }
        BuildProfile.mark("channels group-loop", since: phaseStart)

        let buildStart = ContinuousClock.now
        var groups: [ChannelGroup] = []
        groups.reserveCapacity(groupKeys.count)
        var numbers: [Int?] = []
        numbers.reserveCapacity(groupKeys.count)
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
            numbers.append(number)
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
        BuildProfile.mark("channels build groups", since: buildStart)

        // Sort: number asc (nil last), then name key.
        let sortStart = ContinuousClock.now
        var order = Array(groups.indices)
        order.sort { lhs, rhs in
            let a = numbers[lhs], b = numbers[rhs]
            if a != b {
                guard let a else { return false }
                guard let b else { return true }
                return a < b
            }
            return groupKeys[lhs] < groupKeys[rhs]
        }
        BuildProfile.mark("channels sort", since: sortStart)
        let indexStart = ContinuousClock.now
        var output = ChannelGroups()
        output.groups = order.map { groups[$0] }
        output.categoryIDs = order.map { categoryIDs[$0] }
        output.groupIndex = Dictionary(minimumCapacity: order.count)
        output.contentIndex = Dictionary(minimumCapacity: total)
        for (position, group) in order.enumerated() {
            output.groupIndex[groupKeys[group]] = position
            for channel in members[group] { output.contentIndex[channel.id] = position }
        }
        BuildProfile.mark("channels indexes", since: indexStart)
        return output
    }

    // MARK: - Categories

    struct CategoryResult: Sendable {
        var groups: [CategoryGroup] = []
        var categoryToGroup: [String: String] = [:]
        var members: [String: [Int32]] = [:]
    }

    static func categoryGroups(kind: MediaKind, context: Context, memberCategoryIDs: [Set<String>]) -> CategoryResult {
        let start = ContinuousClock.now
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
        BuildProfile.mark("categoryGroups.\(kind.rawValue)", since: start)
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

/// PRISM_BUILD_PROFILE=1: wall-clock timings of each catalog-build phase, printed to stderr.
enum BuildProfile {
    static let enabled = ProcessInfo.processInfo.environment["PRISM_BUILD_PROFILE"] != nil

    @inline(__always) static func mark(_ label: String, since start: ContinuousClock.Instant) {
        guard enabled else { return }
        let elapsed = ContinuousClock.now - start
        let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
        let line = String(format: "[profile] %@ %8.1f ms\n", label, ms)
        FileHandle.standardError.write(Data(line.utf8))
    }
}

extension CatalogBuilder {
    /// PRISM_CATALOG_DUMP=<path>: canonical text dump of the assembled catalog for byte-level
    /// A/B verification of build changes (temporary instrumentation, not for production use).
    static func dumpCatalogForVerification(_ catalog: Catalog, to path: String) {
        func esc(_ value: String?) -> String { value.map { String(reflecting: $0) } ?? "∅" }
        func esc(_ value: String) -> String { String(reflecting: value) }
        var out = ""
        out.reserveCapacity(1 << 26)
        for title in catalog.movies + catalog.series {
            out += "T\u{1F}\(title.id.rawValue)\u{1F}\(title.kind.rawValue)\u{1F}\(esc(title.title))\u{1F}\(title.year.map(String.init) ?? "∅")"
            out += "\u{1F}\(esc(title.plot))\u{1F}\(title.genres.sorted().joined(separator: ","))"
            out += "\u{1F}\(title.rating.map { String($0.bitPattern) } ?? "∅")\u{1F}\(title.addedAt?.timeIntervalSinceReferenceDate.description ?? "∅")"
            out += "\u{1F}\(title.categoryIDs.sorted().joined(separator: ","))\u{1F}\(title.isAdult)"
            out += "\u{1F}\(esc(title.posterURL?.absoluteString))\u{1F}\(esc(title.backdropURL?.absoluteString))\n"
            for variant in title.variants {
                let categoryID = variant.movie?.categoryID ?? variant.series?.categoryID
                let tmdbID = variant.movie?.tmdbID ?? variant.series?.tmdbID
                let plot = variant.movie?.plot ?? variant.series?.plot
                out += "V\u{1F}\(variant.id.rawValue)\u{1F}\(variant.sourceID.rawValue)\u{1F}\(variant.quality.rawValue)"
                out += "\u{1F}\(esc(variant.rawName))\u{1F}\(esc(variant.title))\u{1F}\(variant.tags.sorted().joined(separator: ","))"
                out += "\u{1F}\(esc(categoryID))\u{1F}\(tmdbID.map(String.init) ?? "∅")\u{1F}\(esc(plot))\n"
            }
        }
        for group in catalog.channels {
            out += "C\u{1F}\(group.id)\u{1F}\(esc(group.name))\u{1F}\(group.number.map(String.init) ?? "∅")\u{1F}\(esc(group.epgID))"
            out += "\u{1F}\(group.categoryIDs.sorted().joined(separator: ","))\u{1F}\(group.isAdult)\n"
            for channel in group.variants {
                out += "W\u{1F}\(channel.id.rawValue)\u{1F}\(channel.sourceID.rawValue)\u{1F}\(esc(channel.nativeID))"
                out += "\u{1F}\(esc(channel.name))\u{1F}\(esc(channel.rawName))\u{1F}\(channel.number.map(String.init) ?? "∅")"
                out += "\u{1F}\(esc(channel.categoryID))\u{1F}\(esc(channel.epgID))\n"
            }
        }
        for kind in [MediaKind.live, .movie, .series] {
            for group in catalog.categoryGroups(kind) {
                out += "G\u{1F}\(group.id)\u{1F}\(esc(group.name))\u{1F}\(group.categoryIDs.joined(separator: ","))"
                out += "\u{1F}\(group.itemCount)\u{1F}\(group.isAdult)\u{1F}\(group.sortIndex)\n"
            }
        }
        for (key, languages) in catalog.indexes.providerLanguages.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            out += "L\u{1F}\(key.rawValue)\u{1F}\(languages.sorted().joined(separator: ","))\n"
        }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
