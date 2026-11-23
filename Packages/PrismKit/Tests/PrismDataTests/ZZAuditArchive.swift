import Foundation
import PrismCore
import Testing
@testable import PrismData

/// SegmentedArchive codec audit against the *installed* app's real caches (read-only).
/// Run alone: `ZZAUDIT=1 swift test --filter ZZAuditArchive --scratch-path .build/agent-archive`
///
/// Breaks the archive pipeline into measurable phases:
///  - unpack / pack container costs
///  - LZFSE decompress vs JSONDecoder (decode side split)
///  - JSONEncoder vs LZFSE compress (encode side split)
///  - JSONEncoder `.withoutEscapingSlashes` size/time impact on real data
///  - batched vs sliding-window `decodeChunks` scheduling
@Suite("ZZ archive audit", .serialized, .disabled(if: ProcessInfo.processInfo.environment["ZZAUDIT"] == nil))
struct ZZAuditArchive {
    static var container: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/app.prism.Prism/Data/Library", directoryHint: .isDirectory)
    }

    static var directories: AppDirectories {
        AppDirectories(
            root: container.appending(path: "Application Support/Prism", directoryHint: .isDirectory),
            caches: container.appending(path: "Caches/Prism", directoryHint: .isDirectory)
        )
    }

    static func ms(_ since: ContinuousClock.Instant) -> Double {
        let e = ContinuousClock.now - since
        return Double(e.components.seconds) * 1_000 + Double(e.components.attoseconds) / 1e15
    }

    private enum Part: Sendable {
        case channels([Channel])
        case movies([Movie])
        case series([Series])
        case programs([EPGProgram])
    }

    private static func decodePart(_ segment: SegmentedArchive.Segment) -> Part? {
        switch segment.tag {
        case 1: return SegmentedArchive.decodeSegment([Channel].self, from: segment).map(Part.channels)
        case 2: return SegmentedArchive.decodeSegment([Movie].self, from: segment).map(Part.movies)
        case 3: return SegmentedArchive.decodeSegment([Series].self, from: segment).map(Part.series)
        case 4: return SegmentedArchive.decodeSegment([EPGProgram].self, from: segment).map(Part.programs)
        default: return nil
        }
    }

    private static func catalogURL() -> URL {
        let sources = SourceStore(directories: directories).load()
        return directories.catalogCacheFile(for: sources[0].id)
    }

    /// Phase split: decompress-only vs JSON-decode-only vs combined decodeChunks.
    @Test func codecBreakdown() async throws {
        let url = Self.catalogURL()
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        print("ZZARCH catalog file: \(data.count / 1_048_576) MiB")

        var t = ContinuousClock.now
        let segments = try #require(SegmentedArchive.unpack(data, version: CatalogCache.formatVersion))
        print("ZZARCH   unpack: \(String(format: "%.1f", Self.ms(t))) ms → \(segments.count) segments")
        let payloadBytes = segments.reduce(0) { $0 + $1.payload.count }
        print("ZZARCH   compressed payload: \(payloadBytes / 1_048_576) MiB")

        // Decompress every payload in parallel, keep the JSON.
        t = ContinuousClock.now
        let jsons: [Data?] = await withTaskGroup(of: (Int, Data?).self) { group in
            for (i, s) in segments.enumerated() where s.tag != 0 {
                group.addTask {
                    (i, autoreleasepool { () -> Data? in
                        SegmentedArchive.decompressPayload(s.payload)
                    })
                }
            }
            var out = [Data?](repeating: nil, count: segments.count)
            for await (i, j) in group { out[i] = j }
            return out
        }
        let decompressMS = Self.ms(t)
        let jsonBytes = jsons.compactMap { $0 }.reduce(0) { $0 + $1.count }
        print("ZZARCH   decompress all (parallel): \(String(format: "%.1f", decompressMS)) ms → \(jsonBytes / 1_048_576) MiB JSON")

        // JSON decode only, from the decompressed bytes (parallel, order irrelevant for timing).
        t = ContinuousClock.now
        let decodedCounts: [Int] = await withTaskGroup(of: (Int, Int).self) { group in
            for (i, s) in segments.enumerated() where s.tag != 0 {
                guard let json = jsons[i] else { continue }
                group.addTask {
                    let count: Int
                    switch s.tag {
                    case 1: count = (try? JSONDecoder().decode([Channel].self, from: json))?.count ?? -1
                    case 2: count = (try? JSONDecoder().decode([Movie].self, from: json))?.count ?? -1
                    case 3: count = (try? JSONDecoder().decode([Series].self, from: json))?.count ?? -1
                    default: count = -1
                    }
                    return (i, count)
                }
            }
            var out = [Int](repeating: -1, count: segments.count)
            for await (i, c) in group { out[i] = c }
            return out
        }
        let jsonDecodeMS = Self.ms(t)
        let totalItems = decodedCounts.reduce(0) { $0 + max(0, $1) }
        print("ZZARCH   JSONDecoder all (parallel): \(String(format: "%.1f", jsonDecodeMS)) ms → \(totalItems) items")

        // Combined production path (decompress+decode per segment, batched).
        t = ContinuousClock.now
        var sink = 0
        let combined = await SegmentedArchive.decodeChunks(segments.dropFirst(), into: 0, decode: { segment in
            guard let part = Self.decodePart(segment) else { return nil }
            switch part {
            case .channels(let v): return v.count
            case .movies(let v): return v.count
            case .series(let v): return v.count
            case .programs(let v): return v.count
            }
        }, append: { sink += $1 })
        print("ZZARCH   decodeChunks combined: \(String(format: "%.1f", Self.ms(t))) ms → \(combined ?? -1) items (sink \(sink))")

        withExtendedLifetime(jsons) {}
    }

    /// Encoder formatting variants on real movie data: bytes, time, decode equality.
    @Test func encoderFormatting() async throws {
        let url = Self.catalogURL()
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let segments = try #require(SegmentedArchive.unpack(data, version: CatalogCache.formatVersion))
        // Decode a few movie segments (tag 2) — enough for a stable measurement.
        var movies: [Movie] = []
        var movieSegments = 0
        for s in segments where s.tag == 2 && movieSegments < 8 {
            if let m = SegmentedArchive.decodeSegment([Movie].self, from: s) {
                movies += m
                movieSegments += 1
            }
        }
        print("ZZARCH encoder bench: \(movies.count) movies from \(movieSegments) segments")
        #expect(!movies.isEmpty)

        func encodeWith(_ formatting: JSONEncoder.OutputFormatting) throws -> (json: Data, compressed: Data) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = formatting
            let json = try encoder.encode(movies)
            let compressed = try (json as NSData).compressed(using: .lzfse) as Data
            return (json, compressed)
        }

        var t = ContinuousClock.now
        let plain = try encodeWith([])
        print("ZZARCH   encode default: \(String(format: "%.1f", Self.ms(t))) ms → json \(plain.json.count) B, lzfse \(plain.compressed.count) B")

        t = ContinuousClock.now
        let noSlashes = try encodeWith([.withoutEscapingSlashes])
        print("ZZARCH   encode noSlashes: \(String(format: "%.1f", Self.ms(t))) ms → json \(noSlashes.json.count) B, lzfse \(noSlashes.compressed.count) B")

        // Slash-escape share of the JSON.
        let slashCount = plain.json.withUnsafeBytes { raw -> Int in
            raw.bindMemory(to: UInt8.self).reduce(0) { $0 + ($1 == 0x5C ? 1 : 0) }
        }
        print("ZZARCH   backslashes in default JSON: \(slashCount) (\(String(format: "%.2f", 100.0 * Double(slashCount) / Double(plain.json.count)))%)")

        // Decode equality + timing on the noSlashes payload.
        t = ContinuousClock.now
        let back = try JSONDecoder().decode([Movie].self, from: noSlashes.json)
        print("ZZARCH   decode noSlashes JSON: \(String(format: "%.1f", Self.ms(t))) ms → \(back.count) movies, equal=\(back == movies)")
        #expect(back == movies)
    }

    /// Batched (current) vs sliding-window scheduling on the real segments.
    @Test func decodeScheduling() async throws {
        let url = Self.catalogURL()
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let segments = try #require(SegmentedArchive.unpack(data, version: CatalogCache.formatVersion))
        let slice = segments.dropFirst()

        // Current production path.
        var t = ContinuousClock.now
        var a = 0
        _ = await SegmentedArchive.decodeChunks(slice, into: 0, decode: { segment in
            Self.decodePart(segment).map { part in
                switch part {
                case .channels(let v): return v.count
                case .movies(let v): return v.count
                case .series(let v): return v.count
                case .programs(let v): return v.count
                }
            }
        }, append: { a += $1 })
        let batchedMS = Self.ms(t)
        print("ZZARCH   decodeChunks batched: \(String(format: "%.1f", batchedMS)) ms (items \(a))")

        // Sliding-window variant (test-local copy of the proposed algorithm).
        t = ContinuousClock.now
        var b = 0
        _ = await Self.decodeChunksWindowed(slice, into: 0, decode: { segment in
            Self.decodePart(segment).map { part in
                switch part {
                case .channels(let v): return v.count
                case .movies(let v): return v.count
                case .series(let v): return v.count
                case .programs(let v): return v.count
                }
            }
        }, append: { b += $1 })
        let windowedMS = Self.ms(t)
        print("ZZARCH   decodeChunks windowed: \(String(format: "%.1f", windowedMS)) ms (items \(b))")
        #expect(a == b)

        // Second runs (warm) for stability.
        t = ContinuousClock.now
        _ = await SegmentedArchive.decodeChunks(slice, into: 0, decode: { segment in
            Self.decodePart(segment).map { part in
                switch part {
                case .channels(let v): return v.count
                case .movies(let v): return v.count
                case .series(let v): return v.count
                case .programs(let v): return v.count
                }
            }
        }, append: { _, _ in })
        print("ZZARCH   decodeChunks batched (warm): \(String(format: "%.1f", Self.ms(t))) ms")
        t = ContinuousClock.now
        _ = await Self.decodeChunksWindowed(slice, into: 0, decode: { segment in
            Self.decodePart(segment).map { part in
                switch part {
                case .channels(let v): return v.count
                case .movies(let v): return v.count
                case .series(let v): return v.count
                case .programs(let v): return v.count
                }
            }
        }, append: { _, _ in })
        print("ZZARCH   decodeChunks windowed (warm): \(String(format: "%.1f", Self.ms(t))) ms")
    }

    /// Encode-side breakdown on the decoded catalog: JSONEncoder vs LZFSE vs pack.
    @Test func encodeBreakdown() async throws {
        let url = Self.catalogURL()
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let decoded = try #require(await CatalogCache.decode(data, version: CatalogCache.formatVersion))
        print("ZZARCH encode bench catalog: \(decoded.channels.count)ch \(decoded.movies.count)mv \(decoded.series.count)sr")

        // JSON encode only (serial, one pass over movies) for the split.
        var t = ContinuousClock.now
        let encoder = JSONEncoder()
        let moviesJSON = try encoder.encode(decoded.movies)
        print("ZZARCH   JSONEncoder movies (\(decoded.movies.count)): \(String(format: "%.1f", Self.ms(t))) ms → \(moviesJSON.count / 1_048_576) MiB")

        t = ContinuousClock.now
        _ = try (moviesJSON as NSData).compressed(using: .lzfse) as Data
        print("ZZARCH   LZFSE compress movies JSON: \(String(format: "%.1f", Self.ms(t))) ms")

        // Full production encode (parallel encodeChunks + pack).
        t = ContinuousClock.now
        let encoded = try await CatalogCache.encode(decoded, version: CatalogCache.formatVersion)
        print("ZZARCH   CatalogCache.encode total: \(String(format: "%.1f", Self.ms(t))) ms → \(encoded.count / 1_048_576) MiB")

        // pack() alone on the produced segments is inside encode; measure pack cost directly.
        t = ContinuousClock.now
        let segments = try #require(SegmentedArchive.unpack(encoded, version: CatalogCache.formatVersion))
        let repacked = SegmentedArchive.pack(segments, version: CatalogCache.formatVersion)
        print("ZZARCH   pack \(segments.count) segments / \(repacked.count / 1_048_576) MiB: \(String(format: "%.1f", Self.ms(t))) ms, identical=\(repacked == encoded)")
        #expect(repacked == encoded)
    }

    /// Compression algorithm trade-offs on real catalog JSON: ratio, compress time,
    /// decompress time. LZFSE is the incumbent; LZ4/LZMA/ZLIB are candidates.
    @Test func compressionAlgorithms() async throws {
        let url = Self.catalogURL()
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let segments = try #require(SegmentedArchive.unpack(data, version: CatalogCache.formatVersion))
        var movies: [Movie] = []
        var n = 0
        for s in segments where s.tag == 2 && n < 8 {
            if let m = SegmentedArchive.decodeSegment([Movie].self, from: s) { movies += m; n += 1 }
        }
        let encoder = JSONEncoder()
        let json = try encoder.encode(movies)
        print("ZZARCH codec bench json: \(json.count / 1_048_576) MiB (\(movies.count) movies)")

        for algo: NSData.CompressionAlgorithm in [.lzfse, .lz4, .lzma, .zlib] {
            var t = ContinuousClock.now
            guard let compressed = try? (json as NSData).compressed(using: algo) as Data else {
                print("ZZARCH   \(algo): compress failed")
                continue
            }
            let compressMS = Self.ms(t)
            t = ContinuousClock.now
            guard let round = try? (compressed as NSData).decompressed(using: algo) as Data, round == json else {
                print("ZZARCH   \(algo): round-trip FAILED")
                continue
            }
            let decompressMS = Self.ms(t)
            print("ZZARCH   \(algo): \(compressed.count / 1_048_576) MiB — compress \(String(format: "%.1f", compressMS)) ms, decompress \(String(format: "%.1f", decompressMS)) ms")
        }
    }

    /// Decode wall-time vs segment granularity: smaller chunks give the ≤10-wide decode
    /// window more, shorter tasks (better tail utilization) at the cost of more per-segment
    /// JSON/LZFSE overhead and slightly worse compression.
    @Test func chunkSizeSweep() async throws {
        let url = Self.catalogURL()
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let decoded = try #require(await CatalogCache.decode(data, version: CatalogCache.formatVersion))
        print("ZZARCH sweep catalog: \(decoded.movies.count)mv \(decoded.series.count)sr \(decoded.channels.count)ch")

        for chunkSize in [3_000, 6_000, 12_000] {
            var t = ContinuousClock.now
            let movieSegments = try await SegmentedArchive.encodeChunks(decoded.movies, tag: 2, chunkSize: chunkSize)
            let encodeMS = Self.ms(t)
            let bytes = movieSegments.reduce(0) { $0 + $1.payload.count }

            t = ContinuousClock.now
            let count = await SegmentedArchive.decodeChunks(movieSegments[...], into: 0, decode: { segment in
                SegmentedArchive.decodeSegment([Movie].self, from: segment)
            }, append: { total, chunk in total += chunk.count })
            let decodeMS = Self.ms(t)
            print("ZZARCH   movies chunkSize=\(chunkSize): \(movieSegments.count) segs, \(bytes / 1_048_576) MiB lzfse — encode \(String(format: "%.1f", encodeMS)) ms, decode \(String(format: "%.1f", decodeMS)) ms → \(count)")
        }
    }

    // MARK: - Sliding-window decode (proposed)

    /// Keeps `width` decodes in flight at all times instead of barrier-synchronizing
    /// batches of `width`: the next segment starts as soon as any slot frees. Results
    /// are appended strictly in archive order via a small reorder buffer.
    static func decodeChunksWindowed<Chunk: Sendable, Result>(
        _ segments: ArraySlice<SegmentedArchive.Segment>, into initial: Result,
        decode: @escaping @Sendable (SegmentedArchive.Segment) -> Chunk?,
        append: (inout Result, Chunk) -> Void
    ) async -> Result? {
        var result = initial
        let count = segments.count
        guard count > 0 else { return result }
        let width = min(max(4, ProcessInfo.processInfo.activeProcessorCount), 10)
        let base = segments.startIndex
        var nextStart = 0
        var nextAppend = 0
        var pending: [Int: Chunk] = [:]
        pending.reserveCapacity(width)

        return await withTaskGroup(of: (Int, Chunk?).self) { group in
            func launch(_ index: Int) {
                let segment = segments[base + index]
                group.addTask { (index, Task.isCancelled ? nil : decode(segment)) }
            }
            for i in 0..<min(width, count) { launch(i) }
            nextStart = min(width, count)

            while let (index, chunk) = await group.next() {
                guard !Task.isCancelled, let chunk else { return nil }
                pending[index] = chunk
                while let ready = pending.removeValue(forKey: nextAppend) {
                    append(&result, ready)
                    nextAppend += 1
                }
                if nextStart < count {
                    launch(nextStart)
                    nextStart += 1
                }
            }
            return result
        }
    }
}
