import Foundation
import PrismCore

/// Disk cache of per-source catalogs.
///
/// Format: a `SegmentedArchive` of compressed chunks (metadata, then channels / movies /
/// series in chunks of `chunkSize`), encoded and decoded concurrently. Version 1 payloads are
/// JSON (measured faster than binary property lists: ≈3× on encode and decode, 2.5× smaller
/// compressed); version 2 payloads are the `BinaryArchive` encoding, because JSON parsing was
/// measured at 85 % of the launch-critical decode on a 300k-item catalogue.
///
/// Migration: version 1 archives still decode — the cache reads the version from the file
/// header, picks the matching codec, and re-saves as version 2 in the background so the next
/// launch skips the JSON parse. Nothing is ever re-downloaded or emptied. Only archives from
/// a *newer* format than this build are ignored (they may use codecs it does not have).
public actor CatalogCache {
    /// Bump when `SourceCatalog` (or any nested model) changes shape: older caches are ignored.
    public static let formatVersion: UInt32 = 2
    /// Versions this build can decode, including migratable legacy ones. Drives both the
    /// decode dispatch and the purge policy: v1 catalog archives are never purged, they are
    /// upgraded on read instead.
    public static let readableVersions: Set<UInt32> = [1, 2]
    // Smaller chunks keep concurrently expanded payloads and encoder state below their previous peak.
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
        /// Mirrors `SourceCatalog.plotsCleaned` (`nil` in older archives: the builder then
        /// cleans their plots itself, as before).
        var plotsCleaned: Bool?
    }

    public nonisolated let directories: AppDirectories
    nonisolated let version: UInt32
    /// Whether loading a legacy (v1) archive re-saves it in the current format in the
    /// background. Disabled by the versioned test init so read-only harnesses never write.
    nonisolated let migratesLegacyArchives: Bool

    public init(directories: AppDirectories) {
        self.init(directories: directories, version: Self.formatVersion, migratesLegacyArchives: true)
        // Archives written in a format this build cannot decode are useless: drop them once,
        // off the main actor. Migratable v1 archives survive (the versioned test init skips
        // this task on purpose).
        let directory = directories.caches.appending(path: "Catalogs", directoryHint: .isDirectory)
        Task.detached(priority: .utility) {
            SegmentedArchive.purgeObsoleteFiles(in: directory, versions: Self.readableVersions, suffix: "catalog")
        }
    }

    init(directories: AppDirectories, version: UInt32, migratesLegacyArchives: Bool = false) {
        self.directories = directories
        self.version = version
        self.migratesLegacyArchives = migratesLegacyArchives
    }

    /// Cached catalog, or `nil` when missing, unreadable or written by a newer format.
    /// Runs off the actor; segments are decoded in parallel. A successful legacy-format
    /// read schedules its re-encode in the current format, off the caller's path.
    @concurrent
    public nonisolated func load(_ id: SourceID) async -> SourceCatalog? {
        let url = directories.catalogCacheFile(for: id)
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        guard let catalog = await Self.decode(data, version: version, expecting: id) else { return nil }
        if migratesLegacyArchives, Self.embeddedVersion(of: data) == 1 {
            let modification = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            // Priority .background: the upgrade re-encode is pure profit for the *next*
            // launch and must never steal CPU from this one.
            Task.detached(priority: .background) {
                await self.reencodeAsCurrentVersion(catalog, id: id, unchangedSince: modification)
            }
        }
        return catalog
    }

    /// Re-writes a legacy archive in the current format. The heavy encode runs off-actor;
    /// the write itself happens here — serialized against `save`/`remove` — and only when the
    /// file is still the exact v1 archive the load read, so a concurrent refresh always wins.
    private func reencodeAsCurrentVersion(_ catalog: SourceCatalog, id: SourceID, unchangedSince modification: Date?) async {
        guard let data = try? await Self.encode(catalog, version: version) else { return }
        let url = directories.catalogCacheFile(for: id)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        let header = (try? handle.read(upToCount: 8)) ?? Data()
        try? handle.close()
        guard header.count == 8, Array(header.prefix(4)) == SegmentedArchive.magic,
              SegmentedArchive.readUInt32([UInt8](header.dropFirst(4)), at: 0) == 1,
              (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate == modification
        else { return }
        try? data.write(to: url, options: [.atomic])
    }

    /// The archive version stamped in the header, or `nil` when the file is not a segmented archive.
    static func embeddedVersion(of data: Data) -> UInt32? {
        let bytes = [UInt8](data.prefix(8))
        guard bytes.count == 8, Array(bytes[0..<4]) == SegmentedArchive.magic else { return nil }
        return SegmentedArchive.readUInt32([UInt8](bytes.dropFirst(4)), at: 0)
    }

    /// Small first-segment metadata without decoding any item payload. Used by the derived
    /// built-catalog artifact to bind its input fingerprints to the exact cached catalog.
    static func embeddedMeta(in data: Data, expecting id: SourceID) -> Meta? {
        guard let unpacked = SegmentedArchive.unpack(data), unpacked.version <= formatVersion,
              let first = unpacked.segments.first, first.tag == Tag.meta.rawValue
        else { return nil }
        switch unpacked.version {
        case 1:
            guard let meta = SegmentedArchive.decodeSegment(Meta.self, from: first) else { return nil }
            return validate(meta, expecting: id)
        case 2:
            guard let payload = expandedBinaryPayload(of: first),
                  let meta = BinaryArchive.decodeMeta(payload) else { return nil }
            return validate(meta, expecting: id)
        default:
            return nil
        }
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

    /// Version selects the payload codec: 1 is the legacy JSON encoding (kept so tests and
    /// fixtures can still produce migratable archives), anything else is written binary.
    /// Stamping a newer-than-2 version is a test hook producing unreadable foreign archives.
    @concurrent
    static func encode(_ catalog: SourceCatalog, version: UInt32) async throws -> Data {
        if version == 1 {
            return try await encodeJSON(catalog, version: version)
        }
        return try await encodeBinary(catalog, version: version)
    }

    @concurrent
    private static func encodeJSON(_ catalog: SourceCatalog, version: UInt32) async throws -> Data {
        let meta = makeMeta(for: catalog)
        async let channels = SegmentedArchive.encodeChunks(catalog.channels, tag: Tag.channels.rawValue, chunkSize: chunkSize)
        async let movies = SegmentedArchive.encodeChunks(catalog.movies, tag: Tag.movies.rawValue, chunkSize: chunkSize)
        async let series = SegmentedArchive.encodeChunks(catalog.series, tag: Tag.series.rawValue, chunkSize: chunkSize / 4)
        let metaSegment = try SegmentedArchive.encodeSegment(meta, tag: Tag.meta.rawValue)
        let segments = try await [metaSegment] + channels + movies + series
        return SegmentedArchive.pack(segments, version: version)
    }

    @concurrent
    private static func encodeBinary(_ catalog: SourceCatalog, version: UInt32) async throws -> Data {
        let meta = makeMeta(for: catalog)
        async let channels = SegmentedArchive.encodeChunks(catalog.channels, chunkSize: chunkSize) { slice in
            try compressedBinarySegment(BinaryArchive.encodeChannels(slice), tag: Tag.channels.rawValue)
        }
        async let movies = SegmentedArchive.encodeChunks(catalog.movies, chunkSize: chunkSize) { slice in
            try compressedBinarySegment(BinaryArchive.encodeMovies(slice), tag: Tag.movies.rawValue)
        }
        async let series = SegmentedArchive.encodeChunks(catalog.series, chunkSize: chunkSize / 4) { slice in
            try compressedBinarySegment(BinaryArchive.encodeSeries(slice), tag: Tag.series.rawValue)
        }
        let metaSegment = try compressedBinarySegment(BinaryArchive.encodeMeta(meta), tag: Tag.meta.rawValue)
        let segments = try await [metaSegment] + channels + movies + series
        return SegmentedArchive.pack(segments, version: version)
    }

    private static func makeMeta(for catalog: SourceCatalog) -> Meta {
        Meta(
            sourceID: catalog.sourceID, categories: catalog.categories, account: catalog.account, fetchedAt: catalog.fetchedAt,
            channelCount: catalog.channels.count, movieCount: catalog.movies.count, seriesCount: catalog.series.count,
            // Catalogs reach `save` already refined: provider decoders run
            // `TitleRefinement.refine` and cache decodes refine legacy archives.
            titlesRefined: true,
            plotsCleaned: catalog.plotsCleaned
        )
    }

    /// Binary payloads are LZFSE-compressed like the JSON ones were: measured cheaper to
    /// decompress the smaller binary stream than to page in the larger uncompressed file.
    static func compressedBinarySegment(_ payload: Data, tag: UInt8) throws -> SegmentedArchive.Segment {
        try SegmentedArchive.Segment(tag: tag, payload: (payload as NSData).compressed(using: .lzfse) as Data)
    }

    /// The binary payload of a segment: raw when it already opens with the codec byte,
    /// LZFSE-compressed otherwise (compressed streams never do — they start with `bvx`).
    /// Being self-describing keeps the compression choice a pure encode-side decision.
    static func expandedBinaryPayload(of segment: SegmentedArchive.Segment) -> Data? {
        if segment.payload.first == BinaryArchive.codecByte { return segment.payload }
        return try? (segment.payload as NSData).decompressed(using: .lzfse) as Data
    }

    private enum Decoded: Sendable {
        case channels([Channel])
        case movies([Movie])
        case series([Series])
    }

    /// Decodes any readable archive version: the version comes from the file header, not the
    /// caller. Archives newer than `version` (this cache's write format) may use codecs this
    /// build does not have — they are ignored, and a refresh will rewrite them.
    @concurrent
    static func decode(_ data: Data, version: UInt32, expecting id: SourceID? = nil) async -> SourceCatalog? {
        guard let unpacked = SegmentedArchive.unpack(data), unpacked.version <= version else { return nil }
        switch unpacked.version {
        case 1:
            return await decodeJSONSegments(unpacked.segments, expecting: id)
        case 2:
            return await decodeBinarySegments(unpacked.segments, expecting: id)
        default:
            return nil
        }
    }

    @concurrent
    private static func decodeJSONSegments(_ segments: [SegmentedArchive.Segment], expecting id: SourceID?) async -> SourceCatalog? {
        guard let first = segments.first, first.tag == Tag.meta.rawValue,
              let meta = SegmentedArchive.decodeSegment(Meta.self, from: first),
              validate(meta, expecting: id) != nil else { return nil }
        return await decodeItems(segments: segments, meta: meta, binary: false)
    }

    @concurrent
    private static func decodeBinarySegments(_ segments: [SegmentedArchive.Segment], expecting id: SourceID?) async -> SourceCatalog? {
        guard let first = segments.first, first.tag == Tag.meta.rawValue,
              let payload = expandedBinaryPayload(of: first),
              let meta = BinaryArchive.decodeMeta(payload),
              validate(meta, expecting: id) != nil else { return nil }
        return await decodeItems(segments: segments, meta: meta, binary: true)
    }

    /// Meta counts feed `reserveCapacity` in decode: reject absurd values from a corrupt
    /// archive before they turn into a giant allocation (or a negative-count trap).
    private static func validate(_ meta: Meta, expecting id: SourceID?) -> Meta? {
        guard id == nil || meta.sourceID == id,
              meta.channelCount >= 0, meta.movieCount >= 0, meta.seriesCount >= 0,
              meta.channelCount <= 2_000_000, meta.movieCount <= 2_000_000,
              meta.seriesCount <= 2_000_000 else { return nil }
        return meta
    }

    @concurrent
    private static func decodeItems(segments: [SegmentedArchive.Segment], meta: Meta, binary: Bool) async -> SourceCatalog? {
        // Archives flagged `titlesRefined` hold provider/decoder-refined titles: the
        // per-title pass (≈1 s on 250k titles) is skipped. Legacy archives pay it once.
        let refineTitles = meta.titlesRefined != true
        var empty = SourceCatalog(sourceID: meta.sourceID, categories: meta.categories, account: meta.account, fetchedAt: meta.fetchedAt)
        empty.plotsCleaned = meta.plotsCleaned == true
        // The meta counts are exact (verified below): reserve once instead of paying
        // repeated buffer growth while ~300k items append chunk by chunk.
        empty.channels.reserveCapacity(meta.channelCount)
        empty.movies.reserveCapacity(meta.movieCount)
        empty.series.reserveCapacity(meta.seriesCount)
        guard let catalog = await SegmentedArchive.decodeChunks(segments.dropFirst(), into: empty, decode: { segment in
            binary
                ? decodeBinaryPart(segment, sourceID: meta.sourceID, refineTitles: refineTitles)
                : decodePart(segment, sourceID: meta.sourceID, refineTitles: refineTitles)
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

    /// Decodes one binary segment. Nothing else: the string/list/header tables already
    /// deduplicate repeated values per segment, which is exactly what the v1 path paid a
    /// `shareRepeatedValues()` pass for — equal lists even decode to the same array value.
    private static func decodeBinaryPart(_ segment: SegmentedArchive.Segment, sourceID: SourceID, refineTitles: Bool) -> Decoded? {
        guard let payload = expandedBinaryPayload(of: segment) else { return nil }
        switch Tag(rawValue: segment.tag) {
        case .channels:
            guard let channels = BinaryArchive.decodeChannels(payload) else { return nil }
            return .channels(channels)
        case .movies:
            guard var movies = BinaryArchive.decodeMovies(payload) else { return nil }
            if refineTitles {
                // Catalogues cached before a naming fix get it without a network refresh.
                for offset in movies.indices {
                    let refined = TitleRefinement.refine(movies[offset].title)
                    if refined != movies[offset].title { movies[offset].title = refined }
                }
            }
            return .movies(movies)
        case .series:
            guard var series = BinaryArchive.decodeSeries(payload) else { return nil }
            if refineTitles {
                for offset in series.indices {
                    let refined = TitleRefinement.refine(series[offset].title)
                    if refined != series[offset].title { series[offset].title = refined }
                }
            }
            return .series(series)
        case .meta, nil:
            return nil
        }
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
///
/// Version 1 payloads are JSON; version 2 payloads are the `BinaryArchive` encoding — JSON
/// parsing dominated the decode cost exactly like it did for the catalogue cache, and the
/// programme channel ids repeat ~73 times per channel, which the per-segment string table
/// collapses to a single instance. Migration mirrors `CatalogCache`: v1 archives decode
/// through the version in the file header and are re-saved as v2 in the background.
public actor EPGCache {
    /// Bump when `EPGProgram`/`XMLTVChannel` (or the meta shape) change: older caches are ignored.
    public static let formatVersion: UInt32 = 2
    /// Versions this build can decode, including migratable legacy ones. Drives both the
    /// decode dispatch and the purge policy: v1 archives are never purged, they are
    /// upgraded on read instead.
    public static let readableVersions: Set<UInt32> = [1, 2]
    /// ~8k programmes/segment: `decodeChunks` decodes ≤10 segments concurrently, so
    /// 40k chunks let a 278k-programme feed expand ~entirely in flight (~400-500 MB
    /// transient measured); 8k bounds it to ~80k programmes per batch. Segments are
    /// self-describing — old caches still decode, they just keep the old profile
    /// until the next save.
    static let chunkSize = 8_000

    enum Tag: UInt8 {
        case meta = 0, programs = 1
    }

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
    /// Whether loading a legacy (v1) archive re-saves it in the current format in the
    /// background. Disabled by the versioned test init so read-only harnesses never write.
    nonisolated let migratesLegacyArchives: Bool

    public init(directories: AppDirectories) {
        self.init(directories: directories, version: Self.formatVersion, migratesLegacyArchives: true)
        let directory = directories.caches.appending(path: "EPG", directoryHint: .isDirectory)
        Task.detached(priority: .utility) {
            SegmentedArchive.purgeObsoleteFiles(in: directory, versions: Self.readableVersions, suffix: "epg")
        }
    }

    init(directories: AppDirectories, version: UInt32, migratesLegacyArchives: Bool = false) {
        self.directories = directories
        self.version = version
        self.migratesLegacyArchives = migratesLegacyArchives
    }

    /// Decodes the meta segment with the codec of the archive version that carries it.
    private static func decodeMetaSegment(_ segment: SegmentedArchive.Segment, version: UInt32) -> Meta? {
        switch version {
        case 1:
            return SegmentedArchive.decodeSegment(Meta.self, from: segment)
        case 2:
            guard let payload = CatalogCache.expandedBinaryPayload(of: segment) else { return nil }
            return BinaryArchive.decodeEPGMeta(payload)
        default:
            return nil
        }
    }

    /// Archive header meta, or `nil` when missing/unreadable/foreign/newer. The version comes
    /// from the file header, not the caller, so legacy archives are readable everywhere.
    private static func header(in data: Data, version: UInt32, expecting id: SourceID) -> Meta? {
        guard let unpacked = SegmentedArchive.unpack(data), unpacked.version <= version,
              let first = unpacked.segments.first, first.tag == Tag.meta.rawValue,
              let meta = decodeMetaSegment(first, version: unpacked.version), meta.sourceID == id
        else { return nil }
        return meta
    }

    /// Fetch date stored in the archive header, without decoding the programme segments.
    @concurrent
    public nonisolated func fetchedAt(_ id: SourceID) async -> Date? {
        guard let data = try? Data(contentsOf: directories.epgCacheFile(for: id), options: [.mappedIfSafe]),
              let meta = Self.header(in: data, version: version, expecting: id) else { return nil }
        return meta.fetchedAt
    }

    /// Cached entry, or `nil` when missing, unreadable or written by a newer format.
    /// Runs off the actor; segments are decoded in parallel. A successful legacy-format
    /// read schedules its re-encode in the current format, off the caller's path.
    @concurrent
    public nonisolated func load(_ id: SourceID) async -> Entry? {
        let url = directories.epgCacheFile(for: id)
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        guard let entry = await Self.decode(data, version: version, expecting: id) else { return nil }
        if migratesLegacyArchives, CatalogCache.embeddedVersion(of: data) == 1 {
            let modification = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            // Priority .background: the upgrade re-encode is pure profit for the *next*
            // launch and must never steal CPU from this one.
            Task.detached(priority: .background) {
                await self.reencodeAsCurrentVersion(entry, id: id, unchangedSince: modification)
            }
        }
        return entry
    }

    /// Re-writes a legacy archive in the current format. The heavy encode runs off-actor;
    /// the write itself happens here — serialized against `save`/`remove` — and only when the
    /// file is still the exact v1 archive the load read, so a concurrent refresh always wins.
    private func reencodeAsCurrentVersion(_ entry: Entry, id: SourceID, unchangedSince modification: Date?) async {
        guard let data = try? await Self.encode(entry, for: id, version: version) else { return }
        let url = directories.epgCacheFile(for: id)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        let header = (try? handle.read(upToCount: 8)) ?? Data()
        try? handle.close()
        guard header.count == 8, Array(header.prefix(4)) == SegmentedArchive.magic,
              SegmentedArchive.readUInt32([UInt8](header.dropFirst(4)), at: 0) == 1,
              (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate == modification
        else { return }
        try? data.write(to: url, options: [.atomic])
    }

    public func save(_ entry: Entry, for id: SourceID) async throws {
        let data = try await Self.encode(entry, for: id, version: version)
        try data.write(to: directories.epgCacheFile(for: id), options: [.atomic])
    }

    public func remove(_ id: SourceID) {
        try? FileManager.default.removeItem(at: directories.epgCacheFile(for: id))
    }

    // MARK: - Coding

    /// Version selects the payload codec: 1 is the legacy JSON encoding (kept so tests and
    /// fixtures can still produce migratable archives), anything else is written binary.
    /// Stamping a newer-than-2 version is a test hook producing unreadable foreign archives.
    @concurrent
    static func encode(_ entry: Entry, for id: SourceID, version: UInt32) async throws -> Data {
        if version == 1 {
            return try await encodeJSON(entry, for: id, version: version)
        }
        return try await encodeBinary(entry, for: id, version: version)
    }

    private static func makeMeta(_ entry: Entry, for id: SourceID) -> Meta {
        Meta(
            sourceID: id,
            channels: entry.channels.map { .init(id: $0.id, displayNames: $0.displayNames, iconURL: $0.iconURL) },
            fetchedAt: entry.fetchedAt, programCount: entry.programs.count
        )
    }

    @concurrent
    private static func encodeJSON(_ entry: Entry, for id: SourceID, version: UInt32) async throws -> Data {
        let metaSegment = try SegmentedArchive.encodeSegment(makeMeta(entry, for: id), tag: Tag.meta.rawValue)
        let chunks = try await SegmentedArchive.encodeChunks(entry.programs, tag: Tag.programs.rawValue, chunkSize: Self.chunkSize)
        return SegmentedArchive.pack([metaSegment] + chunks, version: version)
    }

    @concurrent
    private static func encodeBinary(_ entry: Entry, for id: SourceID, version: UInt32) async throws -> Data {
        async let chunks = SegmentedArchive.encodeChunks(entry.programs, chunkSize: Self.chunkSize) { slice in
            try CatalogCache.compressedBinarySegment(BinaryArchive.encodePrograms(slice), tag: Tag.programs.rawValue)
        }
        let metaSegment = try CatalogCache.compressedBinarySegment(BinaryArchive.encodeEPGMeta(makeMeta(entry, for: id)), tag: Tag.meta.rawValue)
        let segments = try await [metaSegment] + chunks
        return SegmentedArchive.pack(segments, version: version)
    }

    /// Decodes any readable archive version: the version comes from the file header, not the
    /// caller. Archives newer than `version` (this cache's write format) may use codecs this
    /// build does not have — they are ignored, and a refresh will rewrite them.
    @concurrent
    static func decode(_ data: Data, version: UInt32, expecting id: SourceID) async -> Entry? {
        guard let unpacked = SegmentedArchive.unpack(data), unpacked.version <= version else { return nil }
        switch unpacked.version {
        case 1:
            return await decodeSegments(unpacked.segments, binary: false, expecting: id)
        case 2:
            return await decodeSegments(unpacked.segments, binary: true, expecting: id)
        default:
            return nil
        }
    }

    @concurrent
    private static func decodeSegments(_ segments: [SegmentedArchive.Segment], binary: Bool, expecting id: SourceID) async -> Entry? {
        guard let first = segments.first, first.tag == Tag.meta.rawValue,
              let meta = decodeMetaSegment(first, version: binary ? 2 : 1), meta.sourceID == id
        else { return nil }
        // programCount feeds reserveCapacity: reject absurd values from a corrupt
        // archive before they become a giant allocation (or a negative-count trap).
        guard meta.programCount >= 0, meta.programCount <= 5_000_000 else { return nil }
        var emptyPrograms: [EPGProgram] = []
        emptyPrograms.reserveCapacity(meta.programCount)
        guard let programs = await SegmentedArchive.decodeChunks(segments.dropFirst(), into: emptyPrograms, decode: { segment in
            guard segment.tag == Tag.programs.rawValue else { return nil }
            if binary {
                guard let payload = CatalogCache.expandedBinaryPayload(of: segment) else { return nil }
                return BinaryArchive.decodePrograms(payload)
            }
            return SegmentedArchive.decodeSegment([EPGProgram].self, from: segment)
        }, append: { $0 += $1 }), programs.count == meta.programCount else { return nil }
        return Entry(
            programs: programs,
            channels: meta.channels.map { XMLTVChannel(id: $0.id, displayNames: $0.displayNames, iconURL: $0.iconURL) },
            fetchedAt: meta.fetchedAt
        )
    }
}
