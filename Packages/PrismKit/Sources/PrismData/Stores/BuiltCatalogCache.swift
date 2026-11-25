import Foundation
import PrismCore

/// Persisted, already-built catalog: a derived cache of `CatalogBuilder.build`'s exact output.
///
/// The launch path validates the small meta segment first (source list, build options, builder
/// semantics version, and one fingerprint per compressed source-cache file). Validation rehashes
/// only those compressed cache bytes — tens of MB on the reference catalog, never the expanded
/// hundreds of MB — and only then decodes the grouped object payloads. Any validation or
/// structural inconsistency discards the artifact and the ordinary decode+build path runs unchanged.
public actor BuiltCatalogCache {
    /// Container version. Older artifact versions are simply ignored and overwritten by the
    /// next successful build (there is only one derived file, so no migration is worthwhile).
    public static let formatVersion: UInt32 = 1
    /// Logical input contract of the artifact. Bump when `CatalogBuilder`'s grouping,
    /// reconciliation, category, language or ranking semantics change, even if this binary
    /// layout does not. This is deliberately separate from `formatVersion`.
    static let builderSemanticsVersion: UInt32 = 1

    enum Tag: UInt8 {
        case meta = 0, sources = 1
        case movieTitles = 2, movieVariants = 3
        case seriesTitles = 4, seriesVariants = 5
        case channelGroups = 6, channelVariants = 7
        case structure = 8, indexes = 9
    }

    public nonisolated let directories: AppDirectories
    private var lastSaveGeneration: UInt64 = 0

    public init(directories: AppDirectories) {
        self.directories = directories
    }

    // MARK: - Load

    /// Exact catalog for these enabled sources/options, or `nil` for missing, stale or corrupt data.
    /// Validation of the input key happens before the large payload decode.
    @concurrent
    public nonisolated func load(sources: [Source], options: CatalogBuildOptions) async -> Catalog? {
        let enabled = sources.filter(\.isEnabled)
        guard !enabled.isEmpty else { return nil }
        let url = directories.builtCatalogFile
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let unpacked = SegmentedArchive.unpack(data),
              unpacked.version == Self.formatVersion,
              let first = unpacked.segments.first, first.tag == Tag.meta.rawValue,
              let metaPayload = CatalogCache.expandedBinaryPayload(of: first),
              let meta = BuiltCatalogBinary.decodeMeta(metaPayload),
              Self.validateMeta(meta, enabled: enabled, options: options),
              await Self.validateInputs(meta.inputs, directories: directories),
              unpacked.segments.count > 1, unpacked.segments[1].tag == Tag.sources.rawValue,
              let sourcePayload = CatalogCache.expandedBinaryPayload(of: unpacked.segments[1]),
              let storedSources = BuiltCatalogBinary.decodeSources(sourcePayload),
              Self.sameInputs(storedSources, enabled)
        else { return nil }
        return await Self.decodeCatalog(unpacked: unpacked, meta: meta, storedSources: storedSources)
    }

    /// Source-record comparison for artifact validation. `sources.json` persists dates as
    /// whole-second ISO8601 strings while the artifact binds the exact in-memory values, so
    /// sub-second precision always differs across a process restart. Neither `createdAt` nor
    /// `lastRefreshedAt` influences `CatalogBuilder` (only ids, order and enabled state do) —
    /// they are refresh bookkeeping, and every semantic field still compares exactly.
    private static func sameInputs(_ stored: [Source], _ enabled: [Source]) -> Bool {
        guard stored.count == enabled.count else { return false }
        return zip(stored, enabled).allSatisfy { left, right in
            var left = left, right = right
            left.createdAt = .distantPast
            right.createdAt = .distantPast
            left.lastRefreshedAt = nil
            right.lastRefreshedAt = nil
            return left == right
        }
    }

    private static func validateMeta(_ meta: BuiltCatalogBinary.Meta, enabled: [Source], options: CatalogBuildOptions) -> Bool {
        let cap = 5_000_000
        return meta.builderSemanticsVersion == builderSemanticsVersion
            && meta.hideAdult == options.hideAdult
            && meta.hiddenCategoryIDs == options.hiddenCategoryIDs.sorted()
            && meta.inputs.count == enabled.count
            && zip(meta.inputs, enabled).allSatisfy { $0.sourceID == $1.id }
            && meta.sourceCount == enabled.count
            && (0...cap).contains(meta.movieTitleCount) && (0...cap).contains(meta.movieVariantCount)
            && (0...cap).contains(meta.seriesTitleCount) && (0...cap).contains(meta.seriesVariantCount)
            && (0...cap).contains(meta.channelGroupCount) && (0...cap).contains(meta.channelVariantCount)
            && (0...cap).contains(meta.categoryGroupCount)
    }

    private enum Decoded: Sendable {
        case movieStubs([BuiltCatalogBinary.MediaStub])
        case movies([Movie])
        case seriesStubs([BuiltCatalogBinary.MediaStub])
        case series([Series])
        case channelStubs([BuiltCatalogBinary.ChannelStub])
        case channels([Channel])
        case structure(BuiltCatalogBinary.Structure)
        case indexes(BuiltCatalogBinary.IndexPayload)
    }

    private struct Parts: Sendable {
        var movieStubs: [BuiltCatalogBinary.MediaStub] = []
        var movies: [Movie] = []
        var seriesStubs: [BuiltCatalogBinary.MediaStub] = []
        var series: [Series] = []
        var channelStubs: [BuiltCatalogBinary.ChannelStub] = []
        var channels: [Channel] = []
        var structure: BuiltCatalogBinary.Structure?
        var indexes: BuiltCatalogBinary.IndexPayload?
    }

    @concurrent
    static func decodeCatalog(
        unpacked: (version: UInt32, segments: [SegmentedArchive.Segment]), meta: BuiltCatalogBinary.Meta, storedSources: [Source]
    ) async -> Catalog? {
        var parts = Parts()
        parts.movieStubs.reserveCapacity(meta.movieTitleCount)
        parts.movies.reserveCapacity(meta.movieVariantCount)
        parts.seriesStubs.reserveCapacity(meta.seriesTitleCount)
        parts.series.reserveCapacity(meta.seriesVariantCount)
        parts.channelStubs.reserveCapacity(meta.channelGroupCount)
        parts.channels.reserveCapacity(meta.channelVariantCount)
        guard let decoded = await SegmentedArchive.decodeChunks(unpacked.segments.dropFirst(2), into: parts, decode: { segment -> Decoded? in
            guard let payload = CatalogCache.expandedBinaryPayload(of: segment) else { return nil }
            switch Tag(rawValue: segment.tag) {
            case .movieTitles: return BuiltCatalogBinary.decodeMediaTitles(payload, kind: .movie).map(Decoded.movieStubs)
            case .movieVariants: return BinaryArchive.decodeMovies(payload).map(Decoded.movies)
            case .seriesTitles: return BuiltCatalogBinary.decodeMediaTitles(payload, kind: .series).map(Decoded.seriesStubs)
            case .seriesVariants: return BinaryArchive.decodeSeries(payload).map(Decoded.series)
            case .channelGroups: return BuiltCatalogBinary.decodeChannelGroups(payload).map(Decoded.channelStubs)
            case .channelVariants: return BinaryArchive.decodeChannels(payload).map(Decoded.channels)
            case .structure: return BuiltCatalogBinary.decodeStructure(payload).map(Decoded.structure)
            case .indexes: return BuiltCatalogBinary.decodeIndexes(payload).map(Decoded.indexes)
            case .meta, .sources, nil: return nil
            }
        }, append: { parts, part in
            switch part {
            case .movieStubs(let value): parts.movieStubs += value
            case .movies(let value): parts.movies += value
            case .seriesStubs(let value): parts.seriesStubs += value
            case .series(let value): parts.series += value
            case .channelStubs(let value): parts.channelStubs += value
            case .channels(let value): parts.channels += value
            case .structure(let value): parts.structure = value
            case .indexes(let value): parts.indexes = value
            }
        }), let structure = decoded.structure, let indexes = decoded.indexes else { return nil }
        guard decoded.movieStubs.count == meta.movieTitleCount, decoded.movies.count == meta.movieVariantCount,
              decoded.seriesStubs.count == meta.seriesTitleCount, decoded.series.count == meta.seriesVariantCount,
              decoded.channelStubs.count == meta.channelGroupCount, decoded.channels.count == meta.channelVariantCount,
              structure.liveGroups.count + structure.movieGroups.count + structure.seriesGroups.count == meta.categoryGroupCount
        else { return nil }
        return BuiltCatalogBinary.assemble(
            sources: storedSources,
            movieStubs: decoded.movieStubs, movies: decoded.movies,
            seriesStubs: decoded.seriesStubs, series: decoded.series,
            channelStubs: decoded.channelStubs, channels: decoded.channels,
            structure: structure, indexPayload: indexes
        )
    }

    // MARK: - Save

    /// Encodes and atomically writes the derived artifact at background priority. The write is
    /// generation-guarded both in memory (overlapping saves in one process) and in the file
    /// header (a newer artifact already on disk is never overwritten).
    public func save(catalog: Catalog, sources: [Source], catalogs: [SourceCatalog], options: CatalogBuildOptions, generation: UInt64) async {
        lastSaveGeneration = max(lastSaveGeneration, generation)
        let enabled = sources.filter(\.isEnabled)
        guard !enabled.isEmpty else { return }
        // `CatalogBuilder` keeps only the first catalog for a source id. Build exactly that
        // ordered input subset; enabled sources with no readable cache are keyed explicitly below.
        var inputBySource: [SourceID: SourceCatalog] = [:]
        for catalog in catalogs where inputBySource[catalog.sourceID] == nil {
            inputBySource[catalog.sourceID] = catalog
        }
        var inputs: [SourceCatalog] = []
        var missingInputs: [SourceID] = []
        inputs.reserveCapacity(enabled.count)
        for source in enabled {
            if let input = inputBySource[source.id] {
                inputs.append(input)
            } else {
                missingInputs.append(source.id)
            }
        }
        guard var fingerprints = await Self.fingerprints(for: inputs, directories: directories) else { return }
        // An enabled source without a readable cache is itself part of the builder input:
        // the build treats it as empty. Record that state explicitly so the artifact remains
        // usable for partial libraries, and so a later successful import invalidates it.
        fingerprints += missingInputs.map {
            BuiltCatalogBinary.InputFingerprint(
                sourceID: $0, byteCount: Self.missingFingerprintByteCount, contentHash: 0
            )
        }
        // Fingerprint order is the enabled-source priority order, not the append order above.
        var byID: [SourceID: BuiltCatalogBinary.InputFingerprint] = [:]
        for fingerprint in fingerprints where byID[fingerprint.sourceID] == nil {
            byID[fingerprint.sourceID] = fingerprint
        }
        fingerprints = enabled.compactMap { byID[$0.id] }
        guard fingerprints.count == enabled.count else { return }
        let meta = BuiltCatalogBinary.Meta(
            builderSemanticsVersion: Self.builderSemanticsVersion,
            saveGeneration: generation,
            hideAdult: options.hideAdult,
            hiddenCategoryIDs: options.hiddenCategoryIDs.sorted(),
            inputs: fingerprints,
            sourceCount: enabled.count,
            movieTitleCount: catalog.movies.count,
            movieVariantCount: catalog.movies.reduce(0) { $0 + $1.variants.count },
            seriesTitleCount: catalog.series.count,
            seriesVariantCount: catalog.series.reduce(0) { $0 + $1.variants.count },
            channelGroupCount: catalog.channels.count,
            channelVariantCount: catalog.channels.reduce(0) { $0 + $1.variants.count },
            categoryGroupCount: catalog.liveCategories.count + catalog.movieCategories.count + catalog.seriesCategories.count
        )
        guard let data = await Self.encodeArtifact(catalog: catalog, meta: meta) else { return }
        // The input files may have been refreshed while this background encode ran. Revalidate
        // the exact fingerprints before writing: a stale artifact is worse than no artifact.
        guard await Self.validateInputs(fingerprints, directories: directories) else { return }
        guard generation >= lastSaveGeneration,
              Self.existingGeneration(at: directories.builtCatalogFile) <= generation
        else { return }
        try? data.write(to: directories.builtCatalogFile, options: [.atomic])
    }

    private static func existingGeneration(at url: URL) -> UInt64 {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let unpacked = SegmentedArchive.unpack(data),
              unpacked.version == formatVersion,
              let first = unpacked.segments.first,
              let payload = CatalogCache.expandedBinaryPayload(of: first),
              let meta = BuiltCatalogBinary.decodeMeta(payload)
        else { return 0 }
        return meta.saveGeneration
    }

    @concurrent
    static func encodeArtifact(catalog: Catalog, meta: BuiltCatalogBinary.Meta) async -> Data? {
        guard let extraction = extract(catalog) else { return nil }
        async let movieTitles = SegmentedArchive.encodeChunks(catalog.movies, chunkSize: CatalogCache.chunkSize) { slice in
            try CatalogCache.compressedBinarySegment(BuiltCatalogBinary.encodeMediaTitles(slice, kind: .movie), tag: Tag.movieTitles.rawValue)
        }
        async let movieVariants = SegmentedArchive.encodeChunks(extraction.movies, chunkSize: CatalogCache.chunkSize) { slice in
            try CatalogCache.compressedBinarySegment(BinaryArchive.encodeMovies(slice), tag: Tag.movieVariants.rawValue)
        }
        async let seriesTitles = SegmentedArchive.encodeChunks(catalog.series, chunkSize: CatalogCache.chunkSize) { slice in
            try CatalogCache.compressedBinarySegment(BuiltCatalogBinary.encodeMediaTitles(slice, kind: .series), tag: Tag.seriesTitles.rawValue)
        }
        async let seriesVariants = SegmentedArchive.encodeChunks(extraction.series, chunkSize: CatalogCache.chunkSize / 4) { slice in
            try CatalogCache.compressedBinarySegment(BinaryArchive.encodeSeries(slice), tag: Tag.seriesVariants.rawValue)
        }
        async let channelGroups = SegmentedArchive.encodeChunks(catalog.channels, chunkSize: CatalogCache.chunkSize) { slice in
            try CatalogCache.compressedBinarySegment(BuiltCatalogBinary.encodeChannelGroups(slice), tag: Tag.channelGroups.rawValue)
        }
        async let channelVariants = SegmentedArchive.encodeChunks(extraction.channels, chunkSize: CatalogCache.chunkSize) { slice in
            try CatalogCache.compressedBinarySegment(BinaryArchive.encodeChannels(slice), tag: Tag.channelVariants.rawValue)
        }
        do {
            let metaSegment = try CatalogCache.compressedBinarySegment(BuiltCatalogBinary.encodeMeta(meta), tag: Tag.meta.rawValue)
            let sourceSegment = try CatalogCache.compressedBinarySegment(BuiltCatalogBinary.encodeSources(catalog.sources), tag: Tag.sources.rawValue)
            let structure = BuiltCatalogBinary.Structure(
                categories: catalog.indexes.categories,
                liveGroups: catalog.liveCategories, movieGroups: catalog.movieCategories, seriesGroups: catalog.seriesCategories
            )
            let structureSegment = try CatalogCache.compressedBinarySegment(BuiltCatalogBinary.encodeStructure(structure), tag: Tag.structure.rawValue)
            let indexSegment = try CatalogCache.compressedBinarySegment(BuiltCatalogBinary.encodeIndexes(extraction.indexes), tag: Tag.indexes.rawValue)
            let segments = try await [metaSegment, sourceSegment]
                + movieTitles + movieVariants + seriesTitles + seriesVariants
                + channelGroups + channelVariants + [structureSegment, indexSegment]
            return SegmentedArchive.pack(segments, version: formatVersion)
        } catch {
            return nil
        }
    }

    private struct Extraction: Sendable {
        var movies: [Movie]
        var series: [Series]
        var channels: [Channel]
        var indexes: BuiltCatalogBinary.IndexPayload
    }

    /// Flatten variants and recover the information the grouped object graph does not retain.
    /// Content-ID keys are not serialized: variants are stored title-major and entries are
    /// reinserted in ascending title order on decode, exactly as the builder did.
    private static func extract(_ catalog: Catalog) -> Extraction? {
        var movies: [Movie] = []
        var series: [Series] = []
        var channels: [Channel] = []
        movies.reserveCapacity(catalog.movies.reduce(0) { $0 + $1.variants.count })
        series.reserveCapacity(catalog.series.reduce(0) { $0 + $1.variants.count })
        channels.reserveCapacity(catalog.channels.reduce(0) { $0 + $1.variants.count })
        var indexes = BuiltCatalogBinary.IndexPayload()
        indexes.hasTaggedEditions = catalog.indexes.hasTaggedEditions
        indexes.hasMalformedMediaContentIDs = catalog.indexes.hasMalformedMediaContentIDs
        indexes.categoryLanguages = catalog.indexes.categoryLanguages
        indexes.categoryToGroup = catalog.indexes.categoryToGroup
        indexes.movieLanguageSets = catalog.indexes.movieByContent.providerLanguageSets
        indexes.seriesLanguageSets = catalog.indexes.seriesByContent.providerLanguageSets
        indexes.featuredMovies = catalog.indexes.featuredMovies
        indexes.featuredSeries = catalog.indexes.featuredSeries
        indexes.topRatedMovies = catalog.indexes.topRatedMovies
        indexes.topRatedSeries = catalog.indexes.topRatedSeries

        for title in catalog.movies {
            for variant in title.variants {
                guard case .movie(let movie) = variant,
                      let entry = catalog.indexes.movieByContent.entries[movie.id],
                      entry.languageID >= 0, entry.languageID < indexes.movieLanguageSets.count,
                      entry.languageID <= Int32.max else { return nil }
                movies.append(movie)
                indexes.movieLanguageIDs.append(Int32(entry.languageID))
            }
        }
        for title in catalog.series {
            for variant in title.variants {
                guard case .series(let item) = variant,
                      let entry = catalog.indexes.seriesByContent.entries[item.id],
                      entry.languageID >= 0, entry.languageID < indexes.seriesLanguageSets.count,
                      entry.languageID <= Int32.max else { return nil }
                series.append(item)
                indexes.seriesLanguageIDs.append(Int32(entry.languageID))
            }
        }
        for group in catalog.channels {
            for channel in group.variants { channels.append(channel) }
        }

        func extras(_ final: [TitleID: Int], titles: [MediaTitle]) -> [TitleID: Int] {
            var canonical: [TitleID: Int] = Dictionary(minimumCapacity: titles.count)
            for (index, title) in titles.enumerated() { canonical[title.id] = index }
            var output: [TitleID: Int] = [:]
            for (key, position) in final where canonical[key] != position {
                output[key] = position
            }
            return output
        }
        indexes.movieTitleExtras = extras(catalog.indexes.movieByTitleID, titles: catalog.movies)
        indexes.seriesTitleExtras = extras(catalog.indexes.seriesByTitleID, titles: catalog.series)

        for group in catalog.liveCategories + catalog.movieCategories + catalog.seriesCategories {
            guard let members = catalog.indexes.groupMembers[group.id], !members.isEmpty else { return nil }
            indexes.groupMembers.append(members)
        }
        return Extraction(movies: movies, series: series, channels: channels, indexes: indexes)
    }

    // MARK: - Input fingerprints

    private static func fingerprint(data: Data, id: SourceID) -> BuiltCatalogBinary.InputFingerprint {
        BuiltCatalogBinary.InputFingerprint(
            sourceID: id, byteCount: UInt64(data.count), contentHash: contentHash(data)
        )
    }

    private static let missingFingerprintByteCount = UInt64.max
    private static let demoFingerprintByteCount = UInt64.max - 1

    /// The demo catalog is deterministic code-generated data rather than a cache file. Encode
    /// its tiny fixture with a fixed `fetchedAt` (the builder ignores that field) and use the
    /// resulting bytes as its semantic fingerprint; validation recomputes the same small encode.
    private static func demoFingerprint() async -> BuiltCatalogBinary.InputFingerprint? {
        let demo = DemoContent.makeCatalog(fetchedAt: DemoContent.referenceDate)
        guard let data = try? await CatalogCache.encode(demo, version: CatalogCache.formatVersion) else { return nil }
        return BuiltCatalogBinary.InputFingerprint(
            sourceID: DemoContent.sourceID, byteCount: demoFingerprintByteCount,
            contentHash: contentHash(data)
        )
    }

    /// Hash the compressed cache once, in this background save path, and bind it to the source
    /// catalog by checking the embedded meta fields. A concurrent refresh changes those fields
    /// or the file bytes and makes this save abort.
    private static func fingerprints(for catalogs: [SourceCatalog], directories: AppDirectories) async -> [BuiltCatalogBinary.InputFingerprint]? {
        var output: [BuiltCatalogBinary.InputFingerprint] = []
        output.reserveCapacity(catalogs.count)
        for catalog in catalogs {
            if catalog.sourceID == DemoContent.sourceID {
                guard let fingerprint = await demoFingerprint() else { return nil }
                output.append(fingerprint)
                continue
            }
            let url = directories.catalogCacheFile(for: catalog.sourceID)
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
            guard let meta = CatalogCache.embeddedMeta(in: data, expecting: catalog.sourceID),
                  meta.fetchedAt == catalog.fetchedAt,
                  meta.channelCount == catalog.channels.count,
                  meta.movieCount == catalog.movies.count,
                  meta.seriesCount == catalog.series.count,
                  meta.categories == catalog.categories,
                  meta.plotsCleaned == catalog.plotsCleaned
            else { return nil }
            output.append(fingerprint(data: data, id: catalog.sourceID))
        }
        return output
    }

    private static func validateInputs(_ inputs: [BuiltCatalogBinary.InputFingerprint], directories: AppDirectories) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            for input in inputs {
                group.addTask {
                    if input.byteCount == demoFingerprintByteCount {
                        guard let current = await demoFingerprint() else { return false }
                        return current.contentHash == input.contentHash
                    }
                    let url = directories.catalogCacheFile(for: input.sourceID)
                    if input.byteCount == missingFingerprintByteCount {
                        // Missing-input sentinel: valid only while this source still has no readable
                        // catalog archive. A corrupt file is equivalent to no cache in `CatalogCache.load`;
                        // a valid newly imported archive must invalidate the artifact.
                        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return true }
                        return CatalogCache.embeddedMeta(in: data, expecting: input.sourceID) == nil
                    }
                    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return false }
                    return UInt64(data.count) == input.byteCount && contentHash(data) == input.contentHash
                }
            }
            for await valid in group where !valid { return false }
            return true
        }
    }

    /// xxHash64, implemented locally to keep the artifact format independent of platform
    /// compression/crypto libraries. It is a fast non-cryptographic input fingerprint, not a
    /// security boundary; collision resistance is appropriate for cache invalidation.
    static func contentHash(_ data: Data) -> UInt64 {
        data.withUnsafeBytes { buffer in
            xxHash64(buffer, seed: 0)
        }
    }

    private static func xxHash64(_ buffer: UnsafeRawBufferPointer, seed: UInt64) -> UInt64 {
        let prime1: UInt64 = 11_400_714_785_074_694_791
        let prime2: UInt64 = 14_029_467_366_897_019_727
        let prime3: UInt64 = 1_609_587_929_392_839_161
        let prime4: UInt64 = 9_650_029_242_287_828_579
        let prime5: UInt64 = 2_870_177_450_010_260_261
        @inline(__always) func rotate(_ value: UInt64, _ amount: UInt64) -> UInt64 {
            (value << amount) | (value >> (64 - amount))
        }
        @inline(__always) func round(_ accumulator: UInt64, _ input: UInt64) -> UInt64 {
            rotate(accumulator &+ input &* prime2, 31) &* prime1
        }
        @inline(__always) func load64(_ position: Int) -> UInt64 {
            UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: position, as: UInt64.self))
        }
        @inline(__always) func load32(_ position: Int) -> UInt32 {
            UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: position, as: UInt32.self))
        }
        var position = buffer.startIndex
        let end = buffer.endIndex
        var hash: UInt64
        if buffer.count >= 32 {
            var v1 = seed &+ prime1 &+ prime2
            var v2 = seed &+ prime2
            var v3 = seed
            var v4 = seed &- prime1
            while position <= end - 32 {
                v1 = round(v1, load64(position))
                v2 = round(v2, load64(position + 8))
                v3 = round(v3, load64(position + 16))
                v4 = round(v4, load64(position + 24))
                position += 32
            }
            hash = rotate(v1, 1) &+ rotate(v2, 7) &+ rotate(v3, 12) &+ rotate(v4, 18)
            for lane in [v1, v2, v3, v4] {
                let mixed = round(0, lane)
                hash ^= mixed
                hash = hash &* prime1 &+ prime4
            }
        } else {
            hash = seed &+ prime5
        }
        hash = hash &+ UInt64(buffer.count)
        while position <= end - 8 {
            hash ^= round(0, load64(position))
            hash = rotate(hash, 27) &* prime1 &+ prime4
            position += 8
        }
        if position <= end - 4 {
            hash ^= UInt64(load32(position)) &* prime1
            hash = rotate(hash, 23) &* prime2 &+ prime3
            position += 4
        }
        while position < end {
            hash ^= UInt64(buffer[position]) &* prime5
            hash = rotate(hash, 11) &* prime1
            position += 1
        }
        hash ^= hash >> 33
        hash = hash &* prime2
        hash ^= hash >> 29
        hash = hash &* prime3
        hash ^= hash >> 32
        return hash
    }
}
