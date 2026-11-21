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
    static let chunkSize = 12_000

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
    }

    public nonisolated let directories: AppDirectories
    nonisolated let version: UInt32

    public init(directories: AppDirectories) {
        self.init(directories: directories, version: Self.formatVersion)
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
            channelCount: catalog.channels.count, movieCount: catalog.movies.count, seriesCount: catalog.series.count
        )
        async let channels = SegmentedArchive.encodeChunks(catalog.channels, tag: Tag.channels.rawValue, chunkSize: chunkSize)
        async let movies = SegmentedArchive.encodeChunks(catalog.movies, tag: Tag.movies.rawValue, chunkSize: chunkSize)
        async let series = SegmentedArchive.encodeChunks(catalog.series, tag: Tag.series.rawValue, chunkSize: chunkSize / 4)
        let metaSegment = try SegmentedArchive.encodeSegment(meta, tag: Tag.meta.rawValue)
        let segments = try await [metaSegment] + channels + movies + series
        return SegmentedArchive.pack(segments, version: version)
    }

    private enum Decoded: Sendable {
        case meta(Meta)
        case channels([Channel])
        case movies([Movie])
        case series([Series])
        case invalid
    }

    @concurrent
    static func decode(_ data: Data, version: UInt32, expecting id: SourceID? = nil) async -> SourceCatalog? {
        guard let segments = SegmentedArchive.unpack(data, version: version) else { return nil }
        let decoded: [(Int, Decoded)] = await withTaskGroup(of: (Int, Decoded).self) { group in
            for (index, segment) in segments.enumerated() {
                group.addTask {
                    switch Tag(rawValue: segment.tag) {
                    case .meta: (index, SegmentedArchive.decodeSegment(Meta.self, from: segment).map(Decoded.meta) ?? .invalid)
                    case .channels: (index, SegmentedArchive.decodeSegment([Channel].self, from: segment).map(Decoded.channels) ?? .invalid)
                    case .movies: (index, SegmentedArchive.decodeSegment([Movie].self, from: segment).map(Decoded.movies) ?? .invalid)
                    case .series: (index, SegmentedArchive.decodeSegment([Series].self, from: segment).map(Decoded.series) ?? .invalid)
                    case nil: (index, .invalid)
                    }
                }
            }
            var results: [(Int, Decoded)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }
        var meta: Meta?
        var channels: [Channel] = []
        var movies: [Movie] = []
        var series: [Series] = []
        for (_, part) in decoded {
            switch part {
            case .meta(let value): meta = value
            case .channels(let value): channels += value
            case .movies(let value): movies += value
            case .series(let value): series += value
            case .invalid: return nil
            }
        }
        guard let meta, id == nil || meta.sourceID == id,
              meta.channelCount == channels.count, meta.movieCount == movies.count, meta.seriesCount == series.count else { return nil }
        return SourceCatalog(
            sourceID: meta.sourceID, categories: meta.categories, channels: channels, movies: movies, series: series,
            account: meta.account, fetchedAt: meta.fetchedAt
        )
    }
}

/// Disk cache of per-source EPG programmes (same segmented format as `CatalogCache`).
public actor EPGCache {
    public static let formatVersion: UInt32 = 1
    static let chunkSize = 40_000

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
    }

    init(directories: AppDirectories, version: UInt32) {
        self.directories = directories
        self.version = version
    }

    @concurrent
    public nonisolated func load(_ id: SourceID) async -> Entry? {
        guard let data = try? Data(contentsOf: directories.epgCacheFile(for: id), options: [.mappedIfSafe]),
              let segments = SegmentedArchive.unpack(data, version: version),
              let first = segments.first, first.tag == 0,
              let meta = SegmentedArchive.decodeSegment(Meta.self, from: first), meta.sourceID == id else { return nil }
        let chunks: [(Int, [EPGProgram]?)] = await withTaskGroup(of: (Int, [EPGProgram]?).self) { group in
            for (index, segment) in segments.dropFirst().enumerated() {
                group.addTask { (index, SegmentedArchive.decodeSegment([EPGProgram].self, from: segment)) }
            }
            var results: [(Int, [EPGProgram]?)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }
        var programs: [EPGProgram] = []
        programs.reserveCapacity(meta.programCount)
        for (_, chunk) in chunks {
            guard let chunk else { return nil }
            programs += chunk
        }
        guard programs.count == meta.programCount else { return nil }
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
