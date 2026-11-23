import Foundation
import PrismCore

/// Disk cache of per-source catalogs.
///
/// Format: a `SegmentedArchive` of LZFSE-compressed JSON chunks (metadata, then channels / movies /
/// series in chunks of `chunkSize`), encoded and decoded concurrently. JSON was measured faster
/// than binary property lists (≈3× on encode and decode, 2.5× smaller compressed). Versioned:
/// bumping `formatVersion` makes older caches ignored.
public actor CatalogCache {
    /// Bump when `SourceCatalog` (or any nested model) changes shape: older caches are ignored.
    public static let formatVersion: UInt32 = 1
    // Smaller chunks keep concurrently expanded JSON and encoder state below their previous peak.
    static let chunkSize = 6_000

    enum Tag: UInt8 {
        case meta = 0, channels = 1, movies = 2, series = 3
    }

    struct Meta: Codable {
        var sourceID: SourceID
        var categories: [PrismCore.Category]
        var account: XtreamAccount?
        var fetchedAt: Date
        var channelCount: Int
        var movieCount: Int
        var seriesCount: Int
        /// `true` when every stored title already went through `TitleRefinement` (at
        /// provider decode or a previous cache decode): the per-title pass is skipped on
        /// load (~1 s on a 250k-title catalogue). `nil` in archives written before the
        /// flag existed — they still get the migration pass, then re-save flagged.
        var titlesRefined: Bool?
    }

    public nonisolated let directories: AppDirectories
    nonisolated let version: UInt32

    public init(directories: AppDirectories) {
        self.init(directories: directories, version: Self.formatVersion)
        // Archives written by another format version can never be decoded: drop them once,
        // off the main actor (the versioned test init skips this on purpose).
        let directory = directories.caches.appending(path: "Catalogs", directoryHint: .isDirectory)
        Task.detached(priority: .utility) {
            SegmentedArchive.purgeObsoleteFiles(in: directory, version: Self.formatVersion, suffix: "catalog")
        }
    }

    init(directories: AppDirectories, version: UInt32) {
        self.directories = directories
        self.version = version
    }

    /// Cached catalog, or `nil` when missing, unreadable or from another format version.
    /// Runs off the actor; segments are decoded in parallel.
    @concurrent
    public nonisolated func load(_ id: SourceID) async -> SourceCatalog? {
        guard let data = try? Data(contentsOf: directories.catalogCacheFile(for: id), options: [.mappedIfSafe]) else { return nil }
        return await Self.decode(data, version: version, expecting: id)
    }

    public func save(_ catalog: SourceCatalog) async throws {
        let data = try await Self.encode(catalog, version: version)
        try data.write(to: directories.catalogCacheFile(for: catalog.sourceID), options: [.atomic])
    }

    public func remove(_ id: SourceID) {
        try? FileManager.default.removeItem(at: directories.catalogCacheFile(for: id))
    }

    /// Modification date of the cache file, if any.
    public nonisolated func cachedAt(_ id: SourceID) -> Date? {
        let url = directories.catalogCacheFile(for: id)
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: - Coding

    @concurrent
    static func encode(_ catalog: SourceCatalog, version: UInt32) async throws -> Data {
        let meta = Meta(
            sourceID: catalog.sourceID, categories: catalog.categories, account: catalog.account, fetchedAt: catalog.fetchedAt,
            channelCount: catalog.channels.count, movieCount: catalog.movies.count, seriesCount: catalog.series.count,
            // Catalogs reach `save` already refined: provider decoders run
            // `TitleRefinement.refine` and cache decodes refine legacy archives.
            titlesRefined: true
        )
        async let channels = SegmentedArchive.encodeChunks(catalog.channels, tag: Tag.channels.rawValue, chunkSize: chunkSize)
        async let movies = SegmentedArchive.encodeChunks(catalog.movies, tag: Tag.movies.rawValue, chunkSize: chunkSize)
        async let series = SegmentedArchive.encodeChunks(catalog.series, tag: Tag.series.rawValue, chunkSize: chunkSize / 4)
        let metaSegment = try SegmentedArchive.encodeSegment(meta, tag: Tag.meta.rawValue)
        let segments = try await [metaSegment] + channels + movies + series
        return SegmentedArchive.pack(segments, version: version)
    }

    private enum Decoded: Sendable {
        case channels([Channel])
        case movies([Movie])
        case series([Series])
    }

    @concurrent
    static func decode(_ data: Data, version: UInt32, expecting id: SourceID? = nil) async -> SourceCatalog? {
        guard let segments = SegmentedArchive.unpack(data, version: version),
              let first = segments.first, first.tag == Tag.meta.rawValue,
              let meta = SegmentedArchive.decodeSegment(Meta.self, from: first),
              id == nil || meta.sourceID == id else { return nil }
        // Archives flagged `titlesRefined` hold provider/decoder-refined titles: the
        // per-title pass (≈1 s on 250k titles) is skipped. Legacy archives pay it once.
        let refineTitles = meta.titlesRefined != true
        // Meta counts feed reserveCapacity below: reject absurd values from a corrupt
        // archive before they turn into a giant allocation (or a negative-count trap).
        guard meta.channelCount >= 0, meta.movieCount >= 0, meta.seriesCount >= 0,
              meta.channelCount <= 2_000_000, meta.movieCount <= 2_000_000,
              meta.seriesCount <= 2_000_000 else { return nil }
        var empty = SourceCatalog(sourceID: meta.sourceID, categories: meta.categories, account: meta.account, fetchedAt: meta.fetchedAt)
        // The meta counts are exact (verified below): reserve once instead of paying
        // repeated buffer growth while ~300k items append chunk by chunk.
        empty.channels.reserveCapacity(meta.channelCount)
        empty.movies.reserveCapacity(meta.movieCount)
        empty.series.reserveCapacity(meta.seriesCount)
        guard let catalog = await SegmentedArchive.decodeChunks(segments.dropFirst(), into: empty, decode: { segment in
            decodePart(segment, sourceID: meta.sourceID, refineTitles: refineTitles)
        }, append: { catalog, part in
            switch part {
            case .channels(let value): catalog.channels += value
            case .movies(let value): catalog.movies += value
            case .series(let value): catalog.series += value
            }
        }), catalog.channels.count == meta.channelCount, catalog.movies.count == meta.movieCount,
            catalog.series.count == meta.seriesCount else { return nil }
        return catalog
    }

    /// Decodes one segment, then shares its repeated values (category ids, tag/genre
    /// lists, headers) through a throwaway `SourceCatalog`: the pool pass runs inside the
    /// parallel decode batch instead of a ~0.4 s sequential sweep after it. Pools are
    /// per-segment, so a handful of duplicated shared strings survive across segments
    /// (<1 MB on a 300k-item catalogue) — the alternative was paying the pass serially.
    private static func decodePart(_ segment: SegmentedArchive.Segment, sourceID: SourceID, refineTitles: Bool) -> Decoded? {
        switch Tag(rawValue: segment.tag) {
        case .channels:
            guard let channels = SegmentedArchive.decodeSegment([Channel].self, from: segment) else { return nil }
            var shared = SourceCatalog(sourceID: sourceID, channels: channels)
            shared.shareRepeatedValues()
            return .channels(shared.channels)
        case .movies:
            guard var movies = SegmentedArchive.decodeSegment([Movie].self, from: segment) else { return nil }
            if refineTitles {
                // Catalogues cached before a naming fix get it without a network refresh.
                for offset in movies.indices {
                    let refined = TitleRefinement.refine(movies[offset].title)
                    if refined != movies[offset].title { movies[offset].title = refined }
                }
            }
            var shared = SourceCatalog(sourceID: sourceID, movies: movies)
            shared.shareRepeatedValues()
            return .movies(shared.movies)
        case .series:
            guard var series = SegmentedArchive.decodeSegment([Series].self, from: segment) else { return nil }
            if refineTitles {
                for offset in series.indices {
                    let refined = TitleRefinement.refine(series[offset].title)
                    if refined != series[offset].title { series[offset].title = refined }
                }
            }
            var shared = SourceCatalog(sourceID: sourceID, series: series)
            shared.shareRepeatedValues()
            return .series(shared.series)
        case .meta, nil:
            return nil
        }
    }
}

/// Disk cache of per-source EPG programmes (same segmented format as `CatalogCache`).
public actor EPGCache {
    public static let formatVersion: UInt32 = 1
    /// ~8k programmes/segment: `decodeChunks` decodes ≤10 segments concurrently, so
    /// 40k chunks let a 278k-programme feed expand ~entirely in flight (~400-500 MB
    /// transient measured); 8k bounds it to ~80k programmes per batch. Segments are
    /// self-describing — old caches still decode, they just keep the old profile
    /// until the next save.
    static let chunkSize = 8_000

    public struct Entry: Sendable {
        public var programs: [EPGProgram]
        public var channels: [XMLTVChannel]
        public var fetchedAt: Date

        public init(programs: [EPGProgram], channels: [XMLTVChannel] = [], fetchedAt: Date = .now) {
            self.programs = programs
            self.channels = channels
            self.fetchedAt = fetchedAt
        }
    }

    struct Meta: Codable {
        struct StoredChannel: Codable {
            var id: String
            var displayNames: [String]
            var iconURL: URL?
        }
        var sourceID: SourceID
        var channels: [StoredChannel]
        var fetchedAt: Date
        var programCount: Int
    }

    public nonisolated let directories: AppDirectories
    nonisolated let version: UInt32

    public init(directories: AppDirectories) {
        self.init(directories: directories, version: Self.formatVersion)
        let directory = directories.caches.appending(path: "EPG", directoryHint: .isDirectory)
        Task.detached(priority: .utility) {
            SegmentedArchive.purgeObsoleteFiles(in: directory, version: Self.formatVersion, suffix: "epg")
        }
    }

    init(directories: AppDirectories, version: UInt32) {
        self.directories = directories
        self.version = version
    }

    /// Archive header (meta segment + raw segments), or `nil` when missing/unreadable/foreign.
    private static func header(in data: Data, version: UInt32, expecting id: SourceID) -> (meta: Meta, segments: [SegmentedArchive.Segment])? {
        guard let segments = SegmentedArchive.unpack(data, version: version),
              let first = segments.first, first.tag == 0,
              let meta = SegmentedArchive.decodeSegment(Meta.self, from: first), meta.sourceID == id
        else { return nil }
        return (meta, segments)
    }

    /// Fetch date stored in the archive header, without decoding the programme segments.
    @concurrent
    public nonisolated func fetchedAt(_ id: SourceID) async -> Date? {
        guard let data = try? Data(contentsOf: directories.epgCacheFile(for: id), options: [.mappedIfSafe]),
              let header = Self.header(in: data, version: version, expecting: id) else { return nil }
        return header.meta.fetchedAt
    }

    @concurrent
    public nonisolated func load(_ id: SourceID) async -> Entry? {
        guard let data = try? Data(contentsOf: directories.epgCacheFile(for: id), options: [.mappedIfSafe]),
              let header = Self.header(in: data, version: version, expecting: id) else { return nil }
        let meta = header.meta
        // programCount feeds reserveCapacity: reject absurd values from a corrupt
        // archive before they become a giant allocation (or a negative-count trap).
        guard meta.programCount >= 0, meta.programCount <= 5_000_000 else { return nil }
        var emptyPrograms: [EPGProgram] = []
        emptyPrograms.reserveCapacity(meta.programCount)
        guard let programs = await SegmentedArchive.decodeChunks(header.segments.dropFirst(), into: emptyPrograms, decode: { segment in
            guard segment.tag == 1 else { return nil }
            return SegmentedArchive.decodeSegment([EPGProgram].self, from: segment)
        }, append: { $0 += $1 }), programs.count == meta.programCount else { return nil }
        return Entry(
            programs: programs,
            channels: meta.channels.map { XMLTVChannel(id: $0.id, displayNames: $0.displayNames, iconURL: $0.iconURL) },
            fetchedAt: meta.fetchedAt
        )
    }

    public func save(_ entry: Entry, for id: SourceID) async throws {
        let meta = Meta(
            sourceID: id,
            channels: entry.channels.map { .init(id: $0.id, displayNames: $0.displayNames, iconURL: $0.iconURL) },
            fetchedAt: entry.fetchedAt, programCount: entry.programs.count
        )
        let metaSegment = try SegmentedArchive.encodeSegment(meta, tag: 0)
        let chunks = try await SegmentedArchive.encodeChunks(entry.programs, tag: 1, chunkSize: Self.chunkSize)
        let data = SegmentedArchive.pack([metaSegment] + chunks, version: version)
        try data.write(to: directories.epgCacheFile(for: id), options: [.atomic])
    }

    public func remove(_ id: SourceID) {
        try? FileManager.default.removeItem(at: directories.epgCacheFile(for: id))
    }
}
