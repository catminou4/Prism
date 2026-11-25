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
        var context = Context(catalogs: ordered, priority: priority, options: options)

        // Language evidence depends only on categories, so resolve its small lookup tables before
        // grouping. The per-variant values are then written together with the content indexes —
        // that index already pays the ContentID hashing/insertion cost for every variant.
        var categoryLanguages: [String: Set<String>] = [:]
        for category in context.categories.values where category.kind == .movie || category.kind == .series {
            let languages = ProviderCategoryLanguage.codes(in: category.rawName)
            if !languages.isEmpty { categoryLanguages[category.id] = languages }
        }
        let providerLangsStart = ContinuousClock.now
        let languageTable = ProviderLanguageTable(categoryLanguages: categoryLanguages)
        context.applyProviderLanguageTable(languageTable)
        BuildProfile.mark("providerLanguages", since: providerLangsStart)

        // Normalization keys, then grouping — kept in one scope so the per-item key strings
        // are released when grouping finishes instead of living until `build` returns.
        let groupedStart = ContinuousClock.now
        let (movieGroups, seriesGroups, channelGrouping) = await groupedTitles(
            ordered: ordered, context: context, languageTable: languageTable
        )
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
        indexes.categoryLanguages = categoryLanguages
        indexes.hasMalformedMediaContentIDs = movieGroups.hasMalformedContentIDs || seriesGroups.hasMalformedContentIDs
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
        ordered: [SourceCatalog], context: Context,
        languageTable: ProviderLanguageTable
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
        async let movieTitles = groupMedia(
            kind: .movie, lists: ordered.map(\.movies), keys: keys.movies, context: context,
            languageTable: languageTable
        )
        async let seriesTitles = groupMedia(
            kind: .series, lists: ordered.map(\.series), keys: keys.series, context: context,
            languageTable: languageTable
        )
        async let channelGroups = groupChannels(lists: ordered.map(\.channels), keys: keys.channels, context: context)
        let result = await (movieTitles, seriesTitles, channelGroups)
        BuildProfile.mark("grouping (all 3 parallel)", since: groupStart)
        return result
    }

    /// Interned distinct language sets. Variants store only a small table id beside their
    /// title position, so the content index keeps the same one-word dictionary values it had
    /// before provider languages were fused into it. The ordering is deterministic: index 0 is
    /// empty and non-empty sets are sorted by their canonical joined ISO codes.
    struct ProviderLanguageTable: Sendable {
        var sets: [Set<String>]
        var idsByCategory: [String: Int]

        init(categoryLanguages: [String: Set<String>]) {
            var uniqueByKey: [String: Set<String>] = [:]
            for languages in categoryLanguages.values {
                uniqueByKey[languages.sorted().joined(separator: "\u{1F}")] = languages
            }
            var sets: [Set<String>] = [[]]
            var idsByKey: [String: Int] = [:]
            for key in uniqueByKey.keys.sorted() {
                guard let languages = uniqueByKey[key] else { continue }
                idsByKey[key] = sets.count
                sets.append(languages)
            }
            var idsByCategory: [String: Int] = [:]
            idsByCategory.reserveCapacity(categoryLanguages.count)
            for (categoryID, languages) in categoryLanguages {
                let key = languages.sorted().joined(separator: "\u{1F}")
                idsByCategory[categoryID] = idsByKey[key] ?? 0
            }
            self.sets = sets
            self.idsByCategory = idsByCategory
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
        var resolvers: [[MediaKind: [String: ResolvedCategory]]]

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

        /// Fills every precomputed category resolution with its interned language-set id.
        /// This is O(#categories), not O(#variants): hidden and unknown resolutions keep id 0,
        /// exactly like the former lookup of a category absent from `categoryLanguages`.
        mutating func applyProviderLanguageTable(_ table: ProviderLanguageTable) {
            guard !table.idsByCategory.isEmpty else { return }
            for catalogIndex in resolvers.indices {
                let byKind = resolvers[catalogIndex]
                for (kind, original) in byKind {
                    var mapping = original
                    for key in original.keys {
                        guard var resolved = mapping[key] else { continue }
                        resolved.languageID = Int32(table.idsByCategory[resolved.visibleID ?? ""] ?? 0)
                        mapping[key] = resolved
                    }
                    resolvers[catalogIndex][kind] = mapping
                }
            }
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
        /// Interned provider-language set for this category resolution (0 = none). The raw
        /// category reference has already been resolved when an item reaches grouping, so the
        /// content index copies this small id instead of redoing canonical/native id lookup
        /// once per variant.
        var languageID: Int32 = 0
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
        var contentIndex = Catalog.MediaContentIndex()
        /// Category ids per title, in `titles` order.
        var categoryIDs: [Set<String>] = []
        var hasTaggedEditions = false
        var hasMalformedContentIDs = false
    }

    /// Per-chunk output of the parallel title construction.
    private struct BuiltChunk: Sendable {
        var lower: Int
        var titles: [MediaTitle] = []
        var added: [Double] = []
        /// Flattened per-title refs in the exact order of `MediaTitle.variants`. The content
        /// index consumes these lightweight references instead of re-binding every enum payload.
        var variantRefs: [Ref] = []
        var variantRefStarts: [Int] = []
        var variantRefCounts: [Int] = []
        var hasMalformedContentIDs = false
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

    /// Everything the grouping phase needs about one visible item, extracted during the
    /// sequential partition scan so shard tasks never re-read the scattered source items.
    struct MediaRef: Sendable {
        var key: String
        var ref: Ref
        var year: Int?
    }

    /// Per-item results of the grouping pre-pass plus the per-shard ref buckets.
    struct MediaPartition: Sendable {
        /// Resolved visible category per item, positional with the input lists.
        var cats: [[String?]] = []
        var adult: [[Bool]] = []
        /// Interned provider-language set per item, positional with the input lists (0 = none).
        var languageIDs: [[Int32]] = []
        /// Refs of the visible items per shard, each bucket in scan order (catalog, then item).
        var shardRefs: [[MediaRef]] = []
        var hasTaggedEditions = false
        var hasTMDBIdentity = false
    }

    /// Grouping output of one shard: dated groups first (creation order), then undated ones.
    /// `datedGroups` indexes `groups` and is kept for the editorial-alias lookup: rebuilding
    /// one global dictionary would re-hash every key for the sake of a few hundred lookups.
    struct MediaShardGroups: Sendable {
        var groups: [MediaGroup] = []
        var datedCount = 0
        var datedGroups: [NameIdentity: Int] = [:]
    }

    /// Stable shard index of a normalized key: FNV-1a over the UTF-8 bytes with a murmur-style
    /// finalizer. Unlike `hashValue` this is deterministic across runs and processes, and it is
    /// a pure function of the key — every item sharing a key lands in the same shard, keeping
    /// the dated/undated reconciliation shard-local.
    static func shardIndex(for key: String, shards: Int) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        if let contiguous = key.utf8.withContiguousStorageIfAvailable({ buffer -> UInt64 in
            var fast: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in buffer {
                fast ^= UInt64(byte)
                fast &*= 0x0000_0100_0000_01b3
            }
            return fast
        }) {
            hash = contiguous
        } else {
            for byte in key.utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x0000_0100_0000_01b3
            }
        }
        hash ^= hash >> 33
        hash &*= 0xff51_afd7_ed55_8ccd
        hash ^= hash >> 33
        return Int(hash % UInt64(shards))
    }

    /// Per-chunk output of the media partition scan.
    struct MediaPartitionChunk: Sendable {
        var listIndex = 0
        var lower = 0
        var cats: [String?] = []
        var adult: [Bool] = []
        var languageIDs: [Int32] = []
        var buckets: [[MediaRef]] = []
        var tagged = false
        var tmdb = false
    }

    /// Parallel scan reproducing the serial grouping loop's per-item work: category resolution,
    /// adult flags and filtering — except that instead of grouping, each visible item is appended
    /// to the bucket of its key's shard. Concatenating the per-chunk buckets in (catalog, offset)
    /// order yields every shard's refs in the exact scan order of the former serial loop.
    static func partitionMedia<V: GroupableMedia>(
        lists: [[V]], keys: [[String]], context: Context, kind: MediaKind, shards: Int
    ) async -> MediaPartition {
        let total = lists.reduce(0) { $0 + $1.count }
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 12))
        let chunk = max(2_048, total / (workers * 2))

        let chunks: [MediaPartitionChunk] = await withTaskGroup(of: MediaPartitionChunk.self) { group in
            for (listIndex, list) in lists.enumerated() {
                let resolver = context.resolver(catalog: listIndex, kind: kind)
                let listKeys = keys[listIndex]
                var start = 0
                while start < list.count {
                    let end = min(start + chunk, list.count)
                    let lower = start
                    group.addTask {
                        var out = MediaPartitionChunk(listIndex: listIndex, lower: lower)
                        out.cats = [String?](repeating: nil, count: end - lower)
                        out.adult = [Bool](repeating: false, count: end - lower)
                        out.languageIDs = [Int32](repeating: 0, count: end - lower)
                        out.buckets = [[MediaRef]](repeating: [], count: shards)
                        guard !Task.isCancelled else { return out }
                        // Indexed field reads, exactly like the former serial loop: binding the
                        // element would copy the whole struct per item.
                        for index in lower..<end {
                            let category = list[index].categoryID.flatMap { resolver[$0] }
                            let isAdult = list[index].isAdult || category?.isAdult == true
                            if category?.isHidden == true || (isAdult && context.options.hideAdult) { continue }
                            if !out.tagged, !list[index].tags.isEmpty { out.tagged = true }
                            out.adult[index - lower] = isAdult
                            out.cats[index - lower] = category?.visibleID
                            out.languageIDs[index - lower] = category?.languageID ?? 0
                            if !out.tmdb, let tmdbID = list[index].tmdbID, tmdbID > 0 { out.tmdb = true }
                            let shard = shardIndex(for: listKeys[index], shards: shards)
                            out.buckets[shard].append(MediaRef(
                                key: listKeys[index],
                                ref: Ref(catalog: Int32(listIndex), item: Int32(index)),
                                year: list[index].year
                            ))
                        }
                        return out
                    }
                    start = end
                }
            }
            var collected: [MediaPartitionChunk] = []
            for await chunk in group { collected.append(chunk) }
            return collected.sorted { ($0.listIndex, $0.lower) < ($1.listIndex, $1.lower) }
        }

        var partition = MediaPartition()
        partition.cats = lists.map { [String?](repeating: nil, count: $0.count) }
        partition.adult = lists.map { [Bool](repeating: false, count: $0.count) }
        partition.languageIDs = lists.map { [Int32](repeating: 0, count: $0.count) }
        partition.shardRefs = [[MediaRef]](repeating: [], count: shards)
        let average = max(1, total / shards)
        for shard in partition.shardRefs.indices { partition.shardRefs[shard].reserveCapacity(average) }
        let writebackStart = ContinuousClock.now
        for chunk in chunks {
            partition.cats[chunk.listIndex].replaceSubrange(chunk.lower..<(chunk.lower + chunk.cats.count), with: chunk.cats)
            partition.adult[chunk.listIndex].replaceSubrange(chunk.lower..<(chunk.lower + chunk.adult.count), with: chunk.adult)
            partition.languageIDs[chunk.listIndex].replaceSubrange(
                chunk.lower..<(chunk.lower + chunk.languageIDs.count), with: chunk.languageIDs
            )
            for shard in chunk.buckets.indices where !chunk.buckets[shard].isEmpty {
                partition.shardRefs[shard].append(contentsOf: chunk.buckets[shard])
            }
            partition.hasTaggedEditions = partition.hasTaggedEditions || chunk.tagged
            partition.hasTMDBIdentity = partition.hasTMDBIdentity || chunk.tmdb
        }
        BuildProfile.mark("partition writeback (\(total))", since: writebackStart)
        return partition
    }

    /// The exact grouping logic of the former serial loop, restricted to one shard's entries
    /// (already in scan order). All grouping state is keyed by the normalized title, which a
    /// shard owns exclusively, so the per-shard result is identical to what the serial pass
    /// produced for these keys — including refs order within each group. Entries carry their
    /// key and year, so this scans contiguous memory instead of re-reading scattered items.
    static func groupMediaShard(entries: [MediaRef]) -> MediaShardGroups {
        var output = MediaShardGroups()
        output.groups.reserveCapacity(entries.count)
        // Most keys create their own group: reserve once instead of rehashing repeatedly.
        output.datedGroups = Dictionary(minimumCapacity: entries.count)
        /// Normalized title → its only dated group, or -1 when several years exist.
        var yearsByKey: [String: Int] = [:]
        var undatedGroups: [String: Int] = [:]
        var pendingNoYear: [Int] = []

        // Indexed field reads: binding each element would copy the key string per item.
        for offset in entries.indices {
            guard let year = entries[offset].year else {
                pendingNoYear.append(offset)
                continue
            }
            let dated = NameIdentity(key: entries[offset].key, year: year)
            if let group = output.datedGroups[dated] {
                output.groups[group].refs.append(entries[offset].ref)
            } else {
                let group = output.groups.count
                output.groups.append(MediaGroup(name: dated, refs: [entries[offset].ref]))
                output.datedGroups[dated] = group
                yearsByKey[entries[offset].key] = yearsByKey[entries[offset].key] == nil ? group : -1
            }
        }
        output.datedCount = output.groups.count
        // A variant without a year joins the only dated group with the same key; otherwise an undated group.
        for offset in pendingNoYear {
            if let group = yearsByKey[entries[offset].key], group >= 0 {
                output.groups[group].refs.append(entries[offset].ref)
            } else if let group = undatedGroups[entries[offset].key] {
                output.groups[group].refs.append(entries[offset].ref)
            } else {
                let group = output.groups.count
                output.groups.append(MediaGroup(name: NameIdentity(key: entries[offset].key, year: nil), refs: [entries[offset].ref]))
                undatedGroups[entries[offset].key] = group
            }
        }
        return output
    }

    static func groupMedia<V: GroupableMedia>(
        kind: MediaKind, lists: [[V]], keys: [[String]], context: Context,
        languageTable: ProviderLanguageTable
    ) async -> MediaGroups {
        let total = lists.reduce(0) { $0 + $1.count }
        guard total > 0 else { return MediaGroups() }
        let categoryKind: MediaKind = kind == .series ? .series : .movie
        let label = kind == .movie ? "movies" : "series"
        let phaseStart = ContinuousClock.now

        // Sharded grouping: items partition by normalized key (same key → same shard, so the
        // dated/undated reconciliation stays shard-local), shards group concurrently, and the
        // merge reproduces the exact serial order — dated groups by first appearance in scan
        // order, then undated groups by first appearance in the no-year scan.
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 12))
        let shards = max(2, workers * 2)
        let partitionStart = ContinuousClock.now
        let partition = await partitionMedia(lists: lists, keys: keys, context: context, kind: categoryKind, shards: shards)
        BuildProfile.mark("\(label) partition scan", since: partitionStart)
        guard !Task.isCancelled else { return MediaGroups() }
        let shardStart = ContinuousClock.now
        let shardGroups: [MediaShardGroups] = await withTaskGroup(of: (Int, MediaShardGroups, Double).self) { group in
            for (shard, refs) in partition.shardRefs.enumerated() {
                group.addTask {
                    let start = ContinuousClock.now
                    let groups = groupMediaShard(entries: refs)
                    let elapsed = ContinuousClock.now - start
                    return (shard, groups, Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15)
                }
            }
            var results = [MediaShardGroups?](repeating: nil, count: shards)
            var times: [Double] = []
            for await (shard, groups, elapsed) in group {
                results[shard] = groups
                times.append(elapsed)
            }
            if BuildProfile.enabled {
                let slowest = times.sorted(by: >).prefix(4).map { String(format: "%.0f", $0) }.joined(separator: ",")
                let totalMS = times.reduce(0, +)
                FileHandle.standardError.write(Data("[profile] \(label) shards: \(times.count) tasks, total \(String(format: "%.0f", totalMS)) ms; slowest ms: \(slowest)\n".utf8))
            }
            return results.map { $0 ?? MediaShardGroups() }
        }
        BuildProfile.mark("\(label) shard tasks", since: shardStart)
        let mergeGroupsStart = ContinuousClock.now
        // Merge: the serial pass ordered groups by first appearance — dated groups in scan
        // order, then undated groups in no-year scan order. The first ref of a group is the
        // item that created it, so one composite ordinal (undated sets bit 62, sorting after
        // every dated ordinal) reproduces that sequence with a single index sort. Only small
        // tuples move here; the groups themselves are copied exactly once, in the permutation.
        var flat: [(key: Int64, shard: Int32, group: Int32)] = []
        var groupedCount = 0
        for output in shardGroups { groupedCount += output.groups.count }
        flat.reserveCapacity(groupedCount)
        for (shard, output) in shardGroups.enumerated() {
            for groupIndex in output.groups.indices {
                let first = output.groups[groupIndex].refs[0]
                var composite = Int64(first.catalog) << 32 | Int64(UInt32(bitPattern: first.item))
                if groupIndex >= output.datedCount { composite |= 1 << 62 }
                flat.append((composite, Int32(shard), Int32(groupIndex)))
            }
        }
        let frozenFlat = flat
        let mergeOrder = await parallelSortedIndices(count: frozenFlat.count) { frozenFlat[$0].key < frozenFlat[$1].key }
        var mediaGroups: [MediaGroup] = []
        mediaGroups.reserveCapacity(groupedCount)
        // Per-shard map of local group index → merged position, for the editorial-alias lookup.
        var positions = shardGroups.map { [Int](repeating: 0, count: $0.groups.count) }
        for flatIndex in mergeOrder {
            let entry = flat[flatIndex]
            positions[Int(entry.shard)][Int(entry.group)] = mediaGroups.count
            mediaGroups.append(shardGroups[Int(entry.shard)].groups[Int(entry.group)])
        }
        let datedLookup = DatedGroupLookup(shards: shards, dictionaries: shardGroups.map(\.datedGroups), positions: positions)
        BuildProfile.mark("\(label) merge groups", since: mergeGroupsStart)
        let resolvedCategories = partition.cats
        let resolvedLanguageIDs = partition.languageIDs
        let adultFlags = partition.adult
        let hasTMDBIdentity = partition.hasTMDBIdentity
        let hasTaggedEditions = partition.hasTaggedEditions
        BuildProfile.mark("\(label) group-loop (sharded)", since: phaseStart)

        // Build titles in parallel chunks (variant sorting + metadata merge).
        guard !Task.isCancelled else { return MediaGroups() }
        let mergeStart = ContinuousClock.now
        let namedGroups = mergeEditorialAliases(mediaGroups, lookup: datedLookup, kind: kind, lists: lists)
        BuildProfile.mark("\(label) editorial-aliases", since: mergeStart)
        let reconcileStart = ContinuousClock.now
        let frozenGroups = hasTMDBIdentity ? await reconcileMediaIdentities(namedGroups, lists: lists) : namedGroups
        BuildProfile.mark("\(label) reconcile-ids", since: reconcileStart)
        let groupCount = frozenGroups.count
        // Smaller chunks even out the load: multi-variant groups cluster in real catalogs, and
        // with only ~2 chunks per worker one heavy chunk otherwise bounds the whole phase.
        let chunk = max(1_024, groupCount / (workers * 6))
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
                    built.variantRefStarts.reserveCapacity(upper - lower)
                    built.variantRefCounts.reserveCapacity(upper - lower)
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
                        // Keep the sorted refs in flat arrays: the final content index can then
                        // read raw fields by (catalog, item) instead of copying every MediaVariant
                        // payload a second time just to reach its id and category.
                        built.variantRefStarts.append(built.variantRefs.count)
                        built.variantRefCounts.append(refs.count)
                        for refIndex in refs.indices {
                            let ref = refs[refIndex]
                            if !built.hasMalformedContentIDs,
                               !Catalog.contentID(lists[Int(ref.catalog)][Int(ref.item)].id, hasKind: kind) {
                                built.hasMalformedContentIDs = true
                            }
                            built.variantRefs.append(ref)
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

        // Order: addedAt desc, then normalized title, then year. Fields are compared through
        // the subscripts: binding `let group = frozenGroups[…]` inside the comparator copies
        // the struct (retaining its shared strings) millions of times per sort.
        let sortStart = ContinuousClock.now
        let order = await parallelSortedIndices(count: groupCount) { lhs, rhs in
            let a = added[lhs], b = added[rhs]
            if a != b { return a > b }
            if frozenGroups[lhs].name.key != frozenGroups[rhs].name.key { return frozenGroups[lhs].name.key < frozenGroups[rhs].name.key }
            if frozenGroups[lhs].name.year != frozenGroups[rhs].name.year {
                return (frozenGroups[lhs].name.year ?? .min) < (frozenGroups[rhs].name.year ?? .min)
            }
            return (frozenGroups[lhs].tmdbID ?? 0) < (frozenGroups[rhs].tmdbID ?? 0)
        }
        BuildProfile.mark("\(label) sort order", since: sortStart)
        guard !Task.isCancelled else { return MediaGroups() }

        let finalStart = ContinuousClock.now

        // Field reads through chained subscripts, never a binding of the whole MediaTitle
        // (copying it costs ~10 retains of catalogue-shared strings/arrays, contended across
        // cores — see the makeTitle chunks). The two dictionaries build in parallel over
        // contiguous position ranges merged in order, which reproduces the serial pass exactly
        // — even when a key collides (a tmdbID shared by year-conflicting groups), since later
        // positions overwrite earlier ones in both the serial loop and the ordered merge.
        let orderFrozen = order
        let frozenChunks = chunks
        async let titleIndex: [TitleID: Int] = parallelPositionIndex(positions: groupCount, workers: workers, minimumCapacity: groupCount) { position, index in
            let groupIndex = orderFrozen[position]
            let chunkIndex = groupIndex / chunk, offset = groupIndex % chunk
            index[frozenChunks[chunkIndex].titles[offset].id] = position
            if !frozenGroups[groupIndex].ambiguousName, !frozenGroups[groupIndex].aliases.isEmpty {
                index[frozenGroups[groupIndex].name.id(kind: kind)] = position
            }
            for aliasIndex in frozenGroups[groupIndex].aliases.indices {
                index[frozenGroups[groupIndex].aliases[aliasIndex].id(kind: kind)] = position
            }
            if let tmdbID = frozenGroups[groupIndex].tmdbID { index[TitleID(kind: kind, tmdbID: tmdbID)] = position }
        }
        async let contentEntries: [ContentID: Catalog.MediaContentIndex.Entry] = parallelPositionIndex(
            positions: groupCount, workers: workers, minimumCapacity: total
        ) { position, index in
            let groupIndex = orderFrozen[position]
            let chunkIndex = groupIndex / chunk, titleOffset = groupIndex % chunk
            let firstRef = frozenChunks[chunkIndex].variantRefStarts[titleOffset]
            let refCount = frozenChunks[chunkIndex].variantRefCounts[titleOffset]
            for refOffset in 0..<refCount {
                let ref = frozenChunks[chunkIndex].variantRefs[firstRef + refOffset]
                let listIndex = Int(ref.catalog), itemIndex = Int(ref.item)
                let languageID = Int(resolvedLanguageIDs[listIndex][itemIndex])
                index[lists[listIndex][itemIndex].id] = Catalog.MediaContentIndex.Entry(
                    titleIndex: position, languageID: languageID
                )
            }
        }
        // Permutation: one copy per title (not two — the categories extraction is fused in).
        async let permutation: (titles: [MediaTitle], categories: [Set<String>]) = {
            var titles: [MediaTitle] = []
            titles.reserveCapacity(groupCount)
            var categories: [Set<String>] = []
            categories.reserveCapacity(groupCount)
            for position in 0..<groupCount {
                let groupIndex = orderFrozen[position]
                let chunkIndex = groupIndex / chunk, offset = groupIndex % chunk
                categories.append(frozenChunks[chunkIndex].titles[offset].categoryIDs)
                titles.append(frozenChunks[chunkIndex].titles[offset])
            }
            return (titles, categories)
        }()
        let permuted = await permutation
        let result = MediaGroups(
            titles: permuted.titles, titleIndex: await titleIndex,
            contentIndex: Catalog.MediaContentIndex(entries: await contentEntries, providerLanguageSets: languageTable.sets),
            categoryIDs: permuted.categories, hasTaggedEditions: hasTaggedEditions,
            hasMalformedContentIDs: chunks.contains { $0.hasMalformedContentIDs }
        )
        BuildProfile.mark("\(label) final indexes", since: finalStart)
        return result
    }

    /// Link known translations only when the exact release year agrees and provider IDs don't conflict.
    /// Saved versions keep resolving through the old grouping keys.
    /// Index of a dated group in the merged array, served by the per-shard grouping
    /// dictionaries (the shard of a key is a pure function of the key). Rebuilding one global
    /// dictionary would re-hash every normalized title for the sake of the few hundred
    /// editorial-alias lookups.
    struct DatedGroupLookup: Sendable {
        var shards: Int
        var dictionaries: [[NameIdentity: Int]]
        /// Per shard: local group index → position in the merged array.
        var positions: [[Int]]

        func group(for name: NameIdentity) -> Int? {
            let shard = shardIndex(for: name.key, shards: shards)
            guard shard < dictionaries.count, let local = dictionaries[shard][name], local < positions[shard].count else { return nil }
            return positions[shard][local]
        }
    }

    private static func mergeEditorialAliases<V: GroupableMedia>(
        _ groups: [MediaGroup], lookup: DatedGroupLookup, kind: MediaKind, lists: [[V]]
    ) -> [MediaGroup] {
        var replacements: [Int: MediaGroup] = [:]
        var removed: Set<Int> = []
        for shelf in EditorialSelection.shelves {
            for entry in shelf where entry.kind == kind {
                var offsets: [Int] = []
                for key in entry.aliasKeys {
                    guard let offset = lookup.group(for: NameIdentity(key: key, year: entry.year)),
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

    /// Lookup table built in parallel over contiguous position ranges. Each range inserts into
    /// a partial dictionary in position order; partials then merge in range order with later
    /// positions winning — the exact overwrite sequence of the serial loop, so even colliding
    /// keys resolve identically. Insertion is the expensive part on string keys (150k+ entries),
    /// and it dominates the serial merge of the small partials.
    static func parallelPositionIndex<Key: Hashable & Sendable, Value: Sendable>(
        positions: Int, workers: Int, minimumCapacity: Int,
        inserts: @escaping @Sendable (Int, inout [Key: Value]) -> Void
    ) async -> [Key: Value] {
        guard positions >= 8_192, workers > 1 else {
            var index: [Key: Value] = Dictionary(minimumCapacity: minimumCapacity)
            for position in 0..<positions { inserts(position, &index) }
            return index
        }
        let chunk = (positions + workers - 1) / workers
        let partials: [(Int, [Key: Value])] = await withTaskGroup(of: (Int, [Key: Value]).self) { group in
            for lower in stride(from: 0, to: positions, by: chunk) {
                let upper = min(lower + chunk, positions)
                group.addTask {
                    var partial: [Key: Value] = Dictionary(minimumCapacity: minimumCapacity / workers + 1)
                    for position in lower..<upper { inserts(position, &partial) }
                    return (lower, partial)
                }
            }
            var parts: [(Int, [Key: Value])] = []
            for await part in group { parts.append(part) }
            return parts
        }
        var index: [Key: Value] = Dictionary(minimumCapacity: minimumCapacity)
        for (_, partial) in partials.sorted(by: { $0.0 < $1.0 }) {
            index.merge(partial) { _, new in new }
        }
        return index
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

    /// A visible channel reference with its resolved grouping inputs, pre-computed in the
    /// parallel partition scan so shard grouping never re-reads the scattered source items.
    struct ChannelRef: Sendable {
        var key: String
        var ref: Ref
        var visibleCategory: String?
        var isAdult: Bool
    }

    /// Per-chunk output of the channel partition scan.
    struct ChannelPartitionChunk: Sendable {
        var listIndex = 0
        var lower = 0
        var buckets: [[ChannelRef]] = []
    }

    /// Grouping output of one channel shard, in local first-appearance order.
    struct ChannelShardGroups: Sendable {
        var keys: [String] = []
        /// Scan position (catalog, item packed) of each group's first channel: orders the merge.
        var ordinals: [Int64] = []
        var members: [[Channel]] = []
        var categoryIDs: [Set<String>] = []
        var adultFlags: [Bool] = []
    }

    /// The exact grouping logic of the former serial channel loop, restricted to one shard's
    /// entries (already in scan order): group creation order and per-group member order match
    /// what the serial pass produced for these keys.
    static func groupChannelShard(entries: [ChannelRef], lists: [[Channel]]) -> ChannelShardGroups {
        var groupIndex: [String: Int] = [:]
        var output = ChannelShardGroups()
        // Indexed reads: binding each entry would copy its key string per item. Copying the
        // channel itself into its group is inherent — `ChannelGroup` owns its variants.
        for offset in entries.indices {
            let key = entries[offset].key
            let group: Int
            if let existing = groupIndex[key] {
                group = existing
            } else {
                group = output.keys.count
                groupIndex[key] = group
                output.keys.append(key)
                output.ordinals.append(Int64(entries[offset].ref.catalog) << 32 | Int64(UInt32(bitPattern: entries[offset].ref.item)))
                output.members.append([])
                output.categoryIDs.append([])
                output.adultFlags.append(false)
            }
            output.members[group].append(lists[Int(entries[offset].ref.catalog)][Int(entries[offset].ref.item)])
            if let visible = entries[offset].visibleCategory { output.categoryIDs[group].insert(visible) }
            if entries[offset].isAdult { output.adultFlags[group] = true }
        }
        return output
    }

    static func groupChannels(lists: [[Channel]], keys: [[String]], context: Context) async -> ChannelGroups {
        let total = lists.reduce(0) { $0 + $1.count }
        guard total > 0 else { return ChannelGroups() }
        let phaseStart = ContinuousClock.now

        // Same sharding as the media grouping: the parallel scan filters and buckets channel
        // refs per key shard, shards group concurrently, and merging by first-appearance
        // ordinal reproduces the exact serial group and member order.
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 12))
        let shards = max(2, workers * 2)
        let chunk = max(2_048, total / (workers * 2))

        let chunks: [ChannelPartitionChunk] = await withTaskGroup(of: ChannelPartitionChunk.self) { group in
            for (listIndex, list) in lists.enumerated() {
                let resolver = context.resolver(catalog: listIndex, kind: .live)
                let listKeys = keys[listIndex]
                var start = 0
                while start < list.count {
                    let end = min(start + chunk, list.count)
                    let lower = start
                    group.addTask {
                        var out = ChannelPartitionChunk(listIndex: listIndex, lower: lower)
                        out.buckets = [[ChannelRef]](repeating: [], count: shards)
                        guard !Task.isCancelled else { return out }
                        // Indexed reads: `enumerated()` would copy every whole `Channel`
                        // (a large struct) just for the scan.
                        for index in lower..<end {
                            let category = list[index].categoryID.flatMap { resolver[$0] }
                            let isAdult = list[index].isAdult || category?.isAdult == true
                            if category?.isHidden == true || (isAdult && context.options.hideAdult) { continue }
                            let shard = shardIndex(for: listKeys[index], shards: shards)
                            out.buckets[shard].append(ChannelRef(
                                key: listKeys[index],
                                ref: Ref(catalog: Int32(listIndex), item: Int32(index)),
                                visibleCategory: category?.visibleID, isAdult: isAdult
                            ))
                        }
                        return out
                    }
                    start = end
                }
            }
            var collected: [ChannelPartitionChunk] = []
            for await chunk in group { collected.append(chunk) }
            return collected.sorted { ($0.listIndex, $0.lower) < ($1.listIndex, $1.lower) }
        }

        var shardRefs = [[ChannelRef]](repeating: [], count: shards)
        let average = max(1, total / shards)
        for shard in shardRefs.indices { shardRefs[shard].reserveCapacity(average) }
        for chunk in chunks {
            for shard in chunk.buckets.indices where !chunk.buckets[shard].isEmpty {
                shardRefs[shard].append(contentsOf: chunk.buckets[shard])
            }
        }
        guard !Task.isCancelled else { return ChannelGroups() }

        let shardGroups: [ChannelShardGroups] = await withTaskGroup(of: (Int, ChannelShardGroups).self) { group in
            for (shard, entries) in shardRefs.enumerated() {
                group.addTask { (shard, groupChannelShard(entries: entries, lists: lists)) }
            }
            var results = [ChannelShardGroups?](repeating: nil, count: shards)
            for await (shard, groups) in group { results[shard] = groups }
            return results.map { $0 ?? ChannelShardGroups() }
        }

        // Merge in first-appearance order: within a shard groups are already ordered, the
        // ordinal sort restores the exact serial sequence across shards.
        var positions: [(ordinal: Int64, shard: Int32, group: Int32)] = []
        var groupTotal = 0
        for (shard, output) in shardGroups.enumerated() {
            groupTotal += output.keys.count
            for groupIndex in output.keys.indices {
                positions.append((output.ordinals[groupIndex], Int32(shard), Int32(groupIndex)))
            }
        }
        let frozenPositions = positions
        let mergeOrder = await parallelSortedIndices(count: frozenPositions.count) { frozenPositions[$0].ordinal < frozenPositions[$1].ordinal }
        var groupKeys: [String] = []
        groupKeys.reserveCapacity(groupTotal)
        var members: [[Channel]] = []
        members.reserveCapacity(groupTotal)
        var categoryIDs: [Set<String>] = []
        categoryIDs.reserveCapacity(groupTotal)
        var adultFlags: [Bool] = []
        adultFlags.reserveCapacity(groupTotal)
        for index in mergeOrder {
            let position = positions[index]
            let output = shardGroups[Int(position.shard)]
            let groupIndex = Int(position.group)
            groupKeys.append(output.keys[groupIndex])
            members.append(output.members[groupIndex])
            categoryIDs.append(output.categoryIDs[groupIndex])
            adultFlags.append(output.adultFlags[groupIndex])
        }
        BuildProfile.mark("channels group-loop (sharded)", since: phaseStart)

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

    static func categoryGroups(kind: MediaKind, context: Context, memberCategoryIDs: [Set<String>]) async -> CategoryResult {
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

        // Titles are bucketed into member lists in index order. The loop parallelizes over
        // contiguous index ranges, each producing per-group partial lists concatenated in range
        // order afterwards — the same ascending member lists as the serial pass.
        let categoryToGroup = output.categoryToGroup
        let frozenGroupByKey = groupByKey
        func collect(into members: inout [[Int32]], range: Range<Int>) {
            for index in range where !memberCategoryIDs[index].isEmpty {
                let categoryIDs = memberCategoryIDs[index]
                if categoryIDs.count == 1, let only = categoryIDs.first {
                    if let groupID = categoryToGroup[only], let group = frozenGroupByKey[groupID] {
                        members[group].append(Int32(index))
                    }
                    continue
                }
                var seen: Set<Int> = []
                for categoryID in categoryIDs {
                    guard let groupID = categoryToGroup[categoryID], let group = frozenGroupByKey[groupID] else { continue }
                    if seen.insert(group).inserted { members[group].append(Int32(index)) }
                }
            }
        }
        let groupTotal = groups.count
        var members = [[Int32]](repeating: [], count: groupTotal)
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        if memberCategoryIDs.count >= 8_192, workers > 1 {
            let chunk = (memberCategoryIDs.count + workers * 2 - 1) / (workers * 2)
            var partials: [(Int, [[Int32]])] = await withTaskGroup(of: (Int, [[Int32]]).self) { taskGroup in
                for lower in stride(from: 0, to: memberCategoryIDs.count, by: chunk) {
                    let upper = min(lower + chunk, memberCategoryIDs.count)
                    taskGroup.addTask {
                        var partial = [[Int32]](repeating: [], count: groupTotal)
                        collect(into: &partial, range: lower..<upper)
                        return (lower, partial)
                    }
                }
                var collected: [(Int, [[Int32]])] = []
                for await part in taskGroup { collected.append(part) }
                return collected
            }
            partials.sort { $0.0 < $1.0 }
            for (_, partial) in partials {
                for group in partial.indices where !partial[group].isEmpty {
                    members[group].append(contentsOf: partial[group])
                }
            }
        } else {
            collect(into: &members, range: 0..<memberCategoryIDs.count)
        }

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

    /// Per-title scoring in parallel chunks with indexed field reads — binding each MediaTitle
    /// would copy a struct with ~15 catalogue-shared references per title, contended across
    /// cores. The entries feed `topIndices`, whose tie-break on the title index makes the
    /// outcome a pure function of the entry set: chunking cannot change the result.
    static func parallelScored(
        _ count: Int,
        score: @escaping @Sendable (Int) -> (score: Double, index: Int32)?
    ) async -> [(score: Double, index: Int32)] {
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        guard count >= 8_192, workers > 1 else {
            var scored: [(score: Double, index: Int32)] = []
            scored.reserveCapacity(count)
            for index in 0..<count { if let entry = score(index) { scored.append(entry) } }
            return scored
        }
        let chunk = (count + workers * 4 - 1) / (workers * 4)
        let parts: [(Int, [(score: Double, index: Int32)])] = await withTaskGroup(of: (Int, [(score: Double, index: Int32)]).self) { group in
            for lower in stride(from: 0, to: count, by: chunk) {
                let upper = min(lower + chunk, count)
                group.addTask {
                    var scored: [(score: Double, index: Int32)] = []
                    scored.reserveCapacity(upper - lower)
                    for index in lower..<upper { if let entry = score(index) { scored.append(entry) } }
                    return (lower, scored)
                }
            }
            var collected: [(Int, [(score: Double, index: Int32)])] = []
            for await part in group { collected.append(part) }
            return collected
        }
        return parts.sorted { $0.0 < $1.0 }.flatMap(\.1)
    }

    static func featuredRanking(_ titles: [MediaTitle], poolSize: Int = 60) async -> [Int32] {
        guard !titles.isEmpty else { return [] }
        let newest = titles.lazy.compactMap(\.addedAt).max()
        let frozenTitles = titles
        let scored = await parallelScored(titles.count) { index in
            var score = 0.0
            if frozenTitles[index].$backdropURL != nil { score += 100 }
            if frozenTitles[index].$posterURL != nil {
                score += (frozenTitles[index].plot?.utf8.count ?? 0) >= 40 ? 40 : 10
            } else if (frozenTitles[index].plot?.utf8.count ?? 0) >= 40 {
                score += 5
            }
            if let rating = frozenTitles[index].rating { score += min(max(rating, 0), 10) * 2 }
            if let newest, let added = frozenTitles[index].addedAt {
                let days = max(0, newest.timeIntervalSince(added) / 86_400)
                score += max(0, 30 - days / 6)
            }
            score += Double(min(frozenTitles[index].variants.count, 4))
            if frozenTitles[index].isAdult { score -= 1_000 }
            return (score, Int32(index))
        }
        return topIndices(scored, count: poolSize)
    }

    static func ratingRanking(_ titles: [MediaTitle], poolSize: Int = 300) async -> [Int32] {
        let frozenTitles = titles
        let scored = await parallelScored(titles.count) { index in
            guard let rating = frozenTitles[index].rating, rating > 0, !frozenTitles[index].isAdult else { return nil }
            var score = min(rating, 10) * 1_000
            if frozenTitles[index].$posterURL != nil { score += 10 }
            score += Double(min(frozenTitles[index].variants.count, 9))
            return (score, Int32(index))
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
        if !catalog.indexes.categoryLanguages.isEmpty {
            // Recreate the former unified table only in this verification path: movies first,
            // series second, so cross-kind collisions keep the build's overwrite semantics.
            var languagesByContent: [ContentID: Set<String>] = Dictionary(
                minimumCapacity: catalog.indexes.movieByContent.entries.count + catalog.indexes.seriesByContent.entries.count
            )
            for (id, entry) in catalog.indexes.movieByContent.entries {
                languagesByContent[id] = catalog.indexes.movieByContent.providerLanguageSets[entry.languageID]
            }
            for (id, entry) in catalog.indexes.seriesByContent.entries {
                languagesByContent[id] = catalog.indexes.seriesByContent.providerLanguageSets[entry.languageID]
            }
            for (key, languages) in languagesByContent.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                out += "L\u{1F}\(key.rawValue)\u{1F}\(languages.sorted().joined(separator: ","))\n"
            }
        }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
