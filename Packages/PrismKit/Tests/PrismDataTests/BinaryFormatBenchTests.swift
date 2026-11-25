import Foundation
import PrismCore
import Testing
@testable import PrismData

/// Measurements for the binary (v2) catalog cache format, on synthetic and real data.
/// Run with `PRISM_BINBENCH=1`; release mode only is meaningful.
@Suite("Binary format bench", .serialized, .enabled(if: ProcessInfo.processInfo.environment["PRISM_BINBENCH"] == "1"))
struct BinaryFormatBenchTests {
    private static func ms(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: end)
        return Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private static var rssMiB: Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576
    }

    /// A copy of the user's real v1 catalog cache, read-only, outside the app container.
    static let realArchiveURL = URL(fileURLWithPath: "/tmp/prism-bincache/real-v1.catalog")

    /// Encodes a catalog with binary payloads and explicit compression control, so the
    /// compressed/uncompressed variants can be compared through the production decode path
    /// (which self-describes compression per segment).
    static func encodeBinary(_ catalog: SourceCatalog, compress: Bool) async throws -> Data {
        @Sendable func segment(_ payload: Data, _ tag: CatalogCache.Tag) throws -> SegmentedArchive.Segment {
            if compress {
                return SegmentedArchive.Segment(tag: tag.rawValue, payload: try (payload as NSData).compressed(using: .lzfse) as Data)
            }
            return SegmentedArchive.Segment(tag: tag.rawValue, payload: payload)
        }
        let meta = CatalogCache.Meta(
            sourceID: catalog.sourceID, categories: catalog.categories, account: catalog.account, fetchedAt: catalog.fetchedAt,
            channelCount: catalog.channels.count, movieCount: catalog.movies.count, seriesCount: catalog.series.count,
            titlesRefined: true, plotsCleaned: catalog.plotsCleaned
        )
        async let channels = SegmentedArchive.encodeChunks(catalog.channels, chunkSize: CatalogCache.chunkSize) { slice in
            try segment(BinaryArchive.encodeChannels(slice), .channels)
        }
        async let movies = SegmentedArchive.encodeChunks(catalog.movies, chunkSize: CatalogCache.chunkSize) { slice in
            try segment(BinaryArchive.encodeMovies(slice), .movies)
        }
        async let series = SegmentedArchive.encodeChunks(catalog.series, chunkSize: CatalogCache.chunkSize / 4) { slice in
            try segment(BinaryArchive.encodeSeries(slice), .series)
        }
        let metaSegment = try segment(BinaryArchive.encodeMeta(meta), .meta)
        let segments = try await [metaSegment] + channels + movies + series
        return SegmentedArchive.pack(segments, version: 2)
    }

    /// Realistic-shape synthetic catalog: most movies carry plots, tags, genres, ratings,
    /// artwork; series carry plots; channels carry logos and epg ids.
    static func syntheticCatalog(movies: Int, series: Int, channels: Int) -> SourceCatalog {
        var rng = SplitMix64(seed: 7)
        let source: SourceID = "bench"
        let genresPool = ["Action", "Drame", "Comédie", "Thriller", "SF", "Horreur", "Animation"]
        let tagsPool = ["FR", "EN", "MULTI", "VOSTFR", "HEVC", "UHD"]
        var catalog = SourceCatalog(
            sourceID: source,
            categories: (0..<120).map { Fixture.category(source, .movie, "m\($0)", "Catégorie films \($0)", sort: $0) }
                + (0..<60).map { Fixture.category(source, .series, "s\($0)", "Catégorie séries \($0)", sort: $0) }
                + (0..<80).map { Fixture.category(source, .live, "l\($0)", "Catégorie chaînes \($0)", sort: $0) },
            account: XtreamAccount(username: "benchuser", status: "Active", isActive: true, serverURL: URL(string: "http://bench.example.com")),
            fetchedAt: Fixture.reference
        )
        catalog.movies.reserveCapacity(movies)
        for index in 0..<movies {
            let title = Synthetic.title(&rng)
            let year = Int.random(in: 1950...2025, using: &rng)
            let plotWords = (0..<Int.random(in: 20...60, using: &rng)).map { _ in Synthetic.vocabulary.randomElement(using: &rng)! }.joined(separator: " ")
            catalog.movies.append(Movie(
                sourceID: source, nativeID: "\(1_000_000 + index)", title: title, rawName: "FR: \(title) (\(year)) MULTi",
                year: year, posterURL: Fixture.url("posters/\(index).jpg"), backdropURL: Fixture.url("backdrops/\(index).jpg"),
                plot: index % 10 == 0 ? nil : plotWords,
                genres: Array(genresPool.shuffled(using: &rng).prefix(2)),
                rating: Double(Int.random(in: 0...100, using: &rng)) / 10,
                durationSeconds: Int.random(in: 4_800...9_600, using: &rng),
                cast: index % 3 == 0 ? ["Acteur \(index % 500)", "Actrice \(index % 700)"] : [],
                director: index % 3 == 0 ? "Réalisateur \(index % 300)" : nil,
                categoryID: "\(source.rawValue):movie:m\(Int.random(in: 0..<120, using: &rng))",
                streamURL: Fixture.url("movie/benchuser/pass/\(1_000_000 + index).mkv"),
                containerExtension: index % 2 == 0 ? "mkv" : "mp4",
                quality: VideoQuality(rawValue: Int.random(in: 0...4, using: &rng)) ?? .unknown,
                tags: Array(tagsPool.shuffled(using: &rng).prefix(2)),
                addedAt: Fixture.reference.addingTimeInterval(-Double(Int.random(in: 0...3_000_000, using: &rng))),
                tmdbID: Int.random(in: 1...500_000, using: &rng),
                trailerURL: index % 4 == 0 ? Fixture.url("trailers/\(index).mp4") : nil
            ))
        }
        catalog.series.reserveCapacity(series)
        for index in 0..<series {
            let title = Synthetic.title(&rng)
            let year = Int.random(in: 1980...2025, using: &rng)
            let plotWords = (0..<Int.random(in: 20...80, using: &rng)).map { _ in Synthetic.vocabulary.randomElement(using: &rng)! }.joined(separator: " ")
            catalog.series.append(Series(
                sourceID: source, nativeID: "\(500_000 + index)", title: title, rawName: "EN - \(title) (\(year))",
                year: year, posterURL: Fixture.url("series/\(index).jpg"), backdropURL: Fixture.url("seriesbg/\(index).jpg"),
                plot: plotWords, genres: Array(genresPool.shuffled(using: &rng).prefix(2)),
                rating: Double(Int.random(in: 0...100, using: &rng)) / 10,
                cast: ["Acteur \(index % 500)"], director: "Réalisateur \(index % 300)",
                categoryID: "\(source.rawValue):series:s\(Int.random(in: 0..<60, using: &rng))",
                quality: .hd, tags: Array(tagsPool.shuffled(using: &rng).prefix(1)),
                addedAt: Fixture.reference.addingTimeInterval(-Double(Int.random(in: 0...3_000_000, using: &rng))),
                tmdbID: Int.random(in: 1...500_000, using: &rng)
            ))
        }
        catalog.channels.reserveCapacity(channels)
        for index in 0..<channels {
            let name = index % 4 == 0 ? "Chaîne \(index / 12)" : Synthetic.title(&rng)
            catalog.channels.append(Channel(
                sourceID: source, nativeID: "\(900_000 + index)", name: name, rawName: "FR| \(name) HD",
                number: index % 7 == 0 ? nil : index,
                logoURL: Fixture.url("logos/\(index % 2_000).png"),
                categoryID: "\(source.rawValue):live:l\(Int.random(in: 0..<80, using: &rng))",
                epgID: "\(name.lowercased()).fr",
                streamURL: Fixture.url("live/benchuser/pass/\(900_000 + index).m3u8"),
                alternateStreamURL: Fixture.url("live/benchuser/pass/\(900_000 + index).ts"),
                quality: .hd, tags: Array(tagsPool.shuffled(using: &rng).prefix(1))
            ))
        }
        return catalog
    }

    @Test func syntheticComparison() async throws {
        let clock = ContinuousClock()
        let catalog = Self.syntheticCatalog(movies: 100_000, series: 20_000, channels: 30_000)
        print("[binbench] synthetic: \(catalog.channels.count) ch, \(catalog.movies.count) mv, \(catalog.series.count) sr — generated")

        // v1 encode/decode.
        var start = clock.now
        let v1 = try await CatalogCache.encode(catalog, version: 1)
        let v1EncodeMS = Self.ms(start, clock.now)
        start = clock.now
        let decodedV1 = try #require(await CatalogCache.decode(v1, version: 1))
        let v1DecodeMS = Self.ms(start, clock.now)
        print("[binbench] v1: encode \(String(format: "%.0f", v1EncodeMS)) ms, decode \(String(format: "%.0f", v1DecodeMS)) ms, \(v1.count / 1_048_576) MiB")

        // v2 compressed.
        start = clock.now
        let v2 = try await Self.encodeBinary(catalog, compress: true)
        let v2EncodeMS = Self.ms(start, clock.now)
        start = clock.now
        let decodedV2 = try #require(await CatalogCache.decode(v2, version: 2))
        let v2DecodeMS = Self.ms(start, clock.now)
        print("[binbench] v2 compressed: encode \(String(format: "%.0f", v2EncodeMS)) ms, decode \(String(format: "%.0f", v2DecodeMS)) ms, \(v2.count / 1_048_576) MiB")

        // v2 uncompressed.
        start = clock.now
        let v2raw = try await Self.encodeBinary(catalog, compress: false)
        let v2rawEncodeMS = Self.ms(start, clock.now)
        start = clock.now
        let decodedV2raw = try #require(await CatalogCache.decode(v2raw, version: 2))
        let v2rawDecodeMS = Self.ms(start, clock.now)
        print("[binbench] v2 uncompressed: encode \(String(format: "%.0f", v2rawEncodeMS)) ms, decode \(String(format: "%.0f", v2rawDecodeMS)) ms, \(v2raw.count / 1_048_576) MiB")

        // Equality oracle across all three.
        #expect(decodedV2.movies == decodedV1.movies)
        #expect(decodedV2.series == decodedV1.series)
        #expect(decodedV2.channels == decodedV1.channels)
        #expect(decodedV2raw.movies == decodedV1.movies)
        #expect(decodedV2.movies == catalog.movies)

        // Warm repetitions for a stable decode comparison.
        for (name, data, version) in [("v1", v1, UInt32(1)), ("v2 compressed", v2, 2), ("v2 uncompressed", v2raw, 2)] as [(String, Data, UInt32)] {
            var best = Double.infinity
            for _ in 0..<3 {
                start = clock.now
                _ = await CatalogCache.decode(data, version: version)
                best = min(best, Self.ms(start, clock.now))
            }
            print("[binbench] warm decode \(name): best \(String(format: "%.0f", best)) ms")
        }
        print("[binbench] peak RSS \(String(format: "%.0f", Self.rssMiB)) MiB")
    }

    /// Where does the parallel decode wall go: segment decode vs the ordered append phase?
    @Test func parallelPipelineBreakdown() async throws {
        let clock = ContinuousClock()
        guard let v1 = try? Data(contentsOf: Self.realArchiveURL, options: [.mappedIfSafe]) else {
            Issue.record("real archive copy missing")
            return
        }
        let catalog = try #require(await CatalogCache.decode(v1, version: 2))
        let v2raw = try await Self.encodeBinary(catalog, compress: false)
        guard let unpacked = SegmentedArchive.unpack(v2raw) else { return }
        let segments = Array(unpacked.segments.dropFirst())

        // 1. Parallel decode, discarding results — no append cost at all.
        for trial in 0..<3 {
            let start = clock.now
            let batchSize = min(max(4, ProcessInfo.processInfo.activeProcessorCount), 10)
            var totalItems = 0
            for lower in stride(from: 0, to: segments.count, by: batchSize) {
                let batch = segments[lower..<min(lower + batchSize, segments.count)]
                totalItems += await withTaskGroup(of: Int.self) { group in
                    for segment in batch {
                        group.addTask {
                            switch segment.tag {
                            case 1: return BinaryArchive.decodeChannels(segment.payload)?.count ?? 0
                            case 2: return BinaryArchive.decodeMovies(segment.payload)?.count ?? 0
                            case 3: return BinaryArchive.decodeSeries(segment.payload)?.count ?? 0
                            default: return 0
                            }
                        }
                    }
                    var sum = 0
                    for await count in group { sum += count }
                    return sum
                }
            }
            print("[probe] parallel decode-only wall (trial \(trial)): \(String(format: "%.0f", Self.ms(start, clock.now))) ms — \(totalItems) items")
        }

        // 2. Full pipeline through decodeChunks (decode + ordered appends).
        for trial in 0..<2 {
            let start = clock.now
            _ = await CatalogCache.decode(v2raw, version: 2)
            print("[probe] full CatalogCache.decode wall (trial \(trial)): \(String(format: "%.0f", Self.ms(start, clock.now))) ms")
        }

        // 3. Serial decode-only baseline: same work, one task, no parallelism.
        let start = clock.now
        var serialItems = 0
        for segment in segments {
            switch segment.tag {
            case 1: serialItems += BinaryArchive.decodeChannels(segment.payload)?.count ?? 0
            case 2: serialItems += BinaryArchive.decodeMovies(segment.payload)?.count ?? 0
            case 3: serialItems += BinaryArchive.decodeSeries(segment.payload)?.count ?? 0
            default: break
            }
        }
        print("[probe] serial decode-only: \(String(format: "%.0f", Self.ms(start, clock.now))) ms — \(serialItems) items")
    }

    /// Isolates the assembly cost: decode everything once, then time the ordered `+=`
    /// appends on their own, including the drop of the source chunk arrays.
    @Test func appendCostIsolation() async throws {
        let clock = ContinuousClock()
        guard let v1 = try? Data(contentsOf: Self.realArchiveURL, options: [.mappedIfSafe]) else { return }
        let catalog = try #require(await CatalogCache.decode(v1, version: 2))
        let v2raw = try await Self.encodeBinary(catalog, compress: false)
        guard let unpacked = SegmentedArchive.unpack(v2raw) else { return }
        let segments = Array(unpacked.segments.dropFirst())

        // Decode all segments into per-kind chunk arrays (parallel, kept alive).
        enum Part { case channels([Channel]), movies([Movie]), series([Series]) }
        let parts: [(Int, Part?)] = await withTaskGroup(of: (Int, Part?).self) { group in
            for (index, segment) in segments.enumerated() {
                group.addTask {
                    guard let payload = (try? (segment.payload as NSData).decompressed(using: .lzfse) as Data) ?? Optional(segment.payload) else { return (index, nil) }
                    switch segment.tag {
                    case 1: return (index, BinaryArchive.decodeChannels(segment.payload).map(Part.channels))
                    case 2: return (index, BinaryArchive.decodeMovies(segment.payload).map(Part.movies))
                    case 3: return (index, BinaryArchive.decodeSeries(segment.payload).map(Part.series))
                    default: return (index, nil)
                    }
                }
            }
            var collected: [(Int, Part?)] = []
            for await part in group { collected.append(part) }
            return collected.sorted { $0.0 < $1.0 }
        }

        // Timed: the same ordered appends decodeChunks performs.
        for trial in 0..<3 {
            var copy = SourceCatalog(sourceID: catalog.sourceID, categories: [], account: nil, fetchedAt: catalog.fetchedAt)
            copy.channels.reserveCapacity(catalog.channels.count)
            copy.movies.reserveCapacity(catalog.movies.count)
            copy.series.reserveCapacity(catalog.series.count)
            let start = clock.now
            for (_, part) in parts {
                switch part {
                case .channels(let value): copy.channels += value
                case .movies(let value): copy.movies += value
                case .series(let value): copy.series += value
                case nil: break
                }
            }
            print("[probe] append-only wall (trial \(trial)): \(String(format: "%.0f", Self.ms(start, clock.now))) ms — \(copy.channels.count + copy.movies.count + copy.series.count) items")
            let dropStart = clock.now
            copy.channels.removeAll(keepingCapacity: false)
            copy.movies.removeAll(keepingCapacity: false)
            copy.series.removeAll(keepingCapacity: false)
            print("[probe] drop assembled catalog: \(String(format: "%.0f", Self.ms(dropStart, clock.now))) ms")
        }
    }

    /// Phase breakdown inside one binary segment: decompress vs table construction vs
    /// record decoding — where do the milliseconds actually go?
    @Test func segmentPhaseBreakdown() async throws {
        let clock = ContinuousClock()
        guard let v1 = try? Data(contentsOf: Self.realArchiveURL, options: [.mappedIfSafe]) else {
            Issue.record("real archive copy missing")
            return
        }
        let catalog = try #require(await CatalogCache.decode(v1, version: 2))
        let v2raw = try await Self.encodeBinary(catalog, compress: false)
        guard let unpacked = SegmentedArchive.unpack(v2raw) else { return }

        for tag in [UInt8(1), 2, 3] {
            guard let segment = unpacked.segments.first(where: { $0.tag == tag }) else { continue }
            let payload = segment.payload // uncompressed variant: raw binary already
            let kind = [1: "channels", 2: "movies", 3: "series"][tag] ?? "?"

            // Table-only decode.
            var tableMS = Double.infinity
            var stringCount = 0
            var listCount = 0
            for _ in 0..<5 {
                let start = clock.now
                payload.withUnsafeBytes { buffer in
                    var reader = BinaryArchive.Reader(base: buffer)
                    if let tables = try? BinaryArchive.readTables(&reader) {
                        stringCount = tables.strings.count
                        listCount = tables.lists.count
                    }
                }
                tableMS = min(tableMS, Self.ms(start, clock.now))
            }

            // Full decode.
            var fullMS = Double.infinity
            var itemCount = 0
            for _ in 0..<5 {
                let start = clock.now
                switch tag {
                case 1: itemCount = BinaryArchive.decodeChannels(payload)?.count ?? 0
                case 2: itemCount = BinaryArchive.decodeMovies(payload)?.count ?? 0
                default: itemCount = BinaryArchive.decodeSeries(payload)?.count ?? 0
                }
                fullMS = min(fullMS, Self.ms(start, clock.now))
            }
            print("[probe] \(kind) segment: \(payload.count / 1024) KiB, \(itemCount) items, \(stringCount) strings, \(listCount) lists — tables \(String(format: "%.1f", tableMS)) ms, full \(String(format: "%.1f", fullMS)) ms, records-only ≈ \(String(format: "%.1f", fullMS - tableMS)) ms")
        }

        // Compression cost on the biggest segment payload.
        guard let segment = unpacked.segments.first(where: { $0.tag == 2 }) else { return }
        let compressed = try (segment.payload as NSData).compressed(using: .lzfse) as Data
        var decompressMS = Double.infinity
        for _ in 0..<5 {
            let start = clock.now
            _ = try? (compressed as NSData).decompressed(using: .lzfse) as Data
            decompressMS = min(decompressMS, Self.ms(start, clock.now))
        }
        var compressMS = Double.infinity
        for _ in 0..<3 {
            let start = clock.now
            _ = try? (segment.payload as NSData).compressed(using: .lzfse) as Data
            compressMS = min(compressMS, Self.ms(start, clock.now))
        }
        print("[probe] movie segment LZFSE: \(segment.payload.count / 1024) KiB → \(compressed.count / 1024) KiB, compress \(String(format: "%.1f", compressMS)) ms, decompress \(String(format: "%.1f", decompressMS)) ms")
    }

    @Test func realCatalogComparison() async throws {
        let clock = ContinuousClock()
        guard let v1 = try? Data(contentsOf: Self.realArchiveURL, options: [.mappedIfSafe]) else {
            Issue.record("real archive copy missing at \(Self.realArchiveURL.path)")
            return
        }
        print("[binbench] real v1 archive: \(v1.count / 1_048_576) MiB compressed")

        // Baseline: the v1 launch decode path, warm best-of-3.
        var start = clock.now
        let catalog = try #require(await CatalogCache.decode(v1, version: 2, expecting: nil))
        let v1FirstMS = Self.ms(start, clock.now)
        var v1Best = v1FirstMS
        for _ in 0..<2 {
            start = clock.now
            _ = await CatalogCache.decode(v1, version: 2)
            v1Best = min(v1Best, Self.ms(start, clock.now))
        }
        print("[binbench] v1 decode: first \(String(format: "%.0f", v1FirstMS)) ms, best \(String(format: "%.0f", v1Best)) ms — \(catalog.channels.count) ch, \(catalog.movies.count) mv, \(catalog.series.count) sr")

        // Migrate in memory to both binary variants.
        start = clock.now
        let v2 = try await Self.encodeBinary(catalog, compress: true)
        let v2EncodeMS = Self.ms(start, clock.now)
        start = clock.now
        let v2raw = try await Self.encodeBinary(catalog, compress: false)
        let v2rawEncodeMS = Self.ms(start, clock.now)
        print("[binbench] v2 encode: compressed \(String(format: "%.0f", v2EncodeMS)) ms → \(v2.count / 1_048_576) MiB, uncompressed \(String(format: "%.0f", v2rawEncodeMS)) ms → \(v2raw.count / 1_048_576) MiB")

        // Exact migration fidelity oracle on real data.
        let decodedV2 = try #require(await CatalogCache.decode(v2, version: 2))
        #expect(decodedV2.channels == catalog.channels, "channels differ after migration")
        #expect(decodedV2.movies == catalog.movies, "movies differ after migration")
        #expect(decodedV2.series == catalog.series, "series differ after migration")
        #expect(decodedV2.categories == catalog.categories)
        #expect(decodedV2.account == catalog.account)
        print("[binbench] migration oracle: v2 decode == v1 decode exactly ✔")

        // Decode walls, first + best-of-3 for each binary variant.
        for (name, data) in [("v2 compressed", v2), ("v2 uncompressed", v2raw)] as [(String, Data)] {
            start = clock.now
            _ = await CatalogCache.decode(data, version: 2)
            let first = Self.ms(start, clock.now)
            var best = first
            for _ in 0..<2 {
                start = clock.now
                _ = await CatalogCache.decode(data, version: 2)
                best = min(best, Self.ms(start, clock.now))
            }
            print("[binbench] decode \(name): first \(String(format: "%.0f", first)) ms, best \(String(format: "%.0f", best)) ms, \(data.count / 1_048_576) MiB")
        }
        print("[binbench] peak RSS \(String(format: "%.0f", Self.rssMiB)) MiB")
    }
}
