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

        // Normalization keys, computed once and in parallel (the expensive part on 150k+ items).
        async let movieKeys = parallelKeys(ordered.map(\.movies)) { mediaKey(title: $0.title, rawName: $0.rawName, id: $0.id) }
        async let seriesKeys = parallelKeys(ordered.map(\.series)) { mediaKey(title: $0.title, rawName: $0.rawName, id: $0.id) }
        async let channelKeys = parallelKeys(ordered.map(\.channels)) { channelKey($0) }
        let keys = await (movies: movieKeys, series: seriesKeys, channels: channelKeys)
        guard !Task.isCancelled else { return .empty }

        // Grouping (each kind concurrently; title construction is itself chunked in parallel).
        async let movieTitles = groupMedia(kind: .movie, lists: ordered.map(\.movies), keys: keys.movies, context: context)
        async let seriesTitles = groupMedia(kind: .series, lists: ordered.map(\.series), keys: keys.series, context: context)
        async let channelGroups = groupChannels(lists: ordered.map(\.channels), keys: keys.channels, context: context)
        let (movieGroups, seriesGroups, channelGrouping) = await (movieTitles, seriesTitles, channelGroups)
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

    // MARK: - Context

    struct Context: Sendable {
        let catalogs: [SourceCatalog]
        let priority: [SourceID: Int]
        let options: CatalogBuildOptions
        /// Visible categories, by canonical ID.
        let categories: [String: PrismCore.Category]
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

        // Build titles in parallel chunks (variant sorting + metadata merge).
        guard !Task.isCancelled else { return MediaGroups() }
        let namedGroups = mergeEditorialAliases(mediaGroups, datedGroups: datedGroups, kind: kind, lists: lists)
        let frozenGroups = hasTMDBIdentity ? reconcileMediaIdentities(namedGroups, lists: lists) : namedGroups
        let groupCount = frozenGroups.count
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 12))
        let chunk = max(2_048, groupCount / (workers * 2))
        let frozenCategories = resolvedCategories, frozenAdult = adultFlags
        let chunks: [BuiltChunk] = await withTaskGroup(of: BuiltChunk.self) { group in
            var start = 0
            while start < groupCount {
                let lower = start, upper = min(start + chunk, groupCount)
                group.addTask {
                    var built = BuiltChunk(lower: lower)
                    guard !Task.isCancelled else { return built }
                    built.titles.reserveCapacity(upper - lower)
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
                            categories: frozenCategories, adult: frozenAdult
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

        let unorderedTitles = chunks.flatMap(\.titles)
        async let titles = order.map { unorderedTitles[$0] }
        async let categories = order.map { unorderedTitles[$0].categoryIDs }
        async let titleIndex: [TitleID: Int] = {
            var index: [TitleID: Int] = Dictionary(minimumCapacity: groupCount)
            for (position, group) in order.enumerated() {
                let media = frozenGroups[group]
                let id = unorderedTitles[group].id
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
                for variant in unorderedTitles[group].variants { index[variant.id] = position }
            }
            return index
        }()
        return await MediaGroups(
            titles: titles, titleIndex: titleIndex, contentIndex: contentIndex,
            categoryIDs: categories, hasTaggedEditions: hasTaggedEditions
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
    static func reconcileMediaIdentities<V: GroupableMedia>(_ groups: [MediaGroup], lists: [[V]]) -> [MediaGroup] {
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
        categories: [[String?]], adult: [[Bool]]
    ) -> MediaTitle {
        let first = lists[Int(refs[0].catalog)][Int(refs[0].item)]
        if refs.count == 1 {
            let ref = refs[0]
            let rating = first.rating.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            var single = MediaTitle(
                id: id,
                kind: kind, title: first.title, year: year ?? first.year, variants: [first.mediaVariant],
                plot: cleanPlot(first.plot),
                genres: cleanGenres(first.genres), rating: rating, addedAt: first.addedAt,
                categoryIDs: categories[Int(ref.catalog)][Int(ref.item)].map { [$0] } ?? [],
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
            for genre in item.genres {
                let trimmed = trimmed(genre)
                guard !trimmed.isEmpty else { continue }
                if seenGenres.insert(TextFolding.fold(trimmed)).inserted { genres.append(trimmed) }
            }
            if let value = item.rating, value.isFinite, value > 0 { rating = max(rating ?? 0, value) }
            if let date = item.addedAt { addedAt = max(addedAt ?? date, date) }
            if let category = categories[Int(ref.catalog)][Int(ref.item)] { categoryIDs.insert(category) }
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

    static func cleanGenres(_ genres: [String]) -> [String] {
        if genres.count == 1, let only = genres.first {
            let value = trimmed(only)
            return value.isEmpty ? [] : [value]
        }
        guard !genres.isEmpty else { return [] }
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

    static func groupChannels(lists: [[Channel]], keys: [[String]], context: Context) -> ChannelGroups {
        let total = lists.reduce(0) { $0 + $1.count }
        guard total > 0 else { return ChannelGroups() }
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

        // Sort: number asc (nil last), then name key.
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
        var output = ChannelGroups()
        output.groups = order.map { groups[$0] }
        output.categoryIDs = order.map { categoryIDs[$0] }
        output.groupIndex = Dictionary(minimumCapacity: order.count)
        output.contentIndex = Dictionary(minimumCapacity: total)
        for (position, group) in order.enumerated() {
            output.groupIndex[groupKeys[group]] = position
            for channel in members[group] { output.contentIndex[channel.id] = position }
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
