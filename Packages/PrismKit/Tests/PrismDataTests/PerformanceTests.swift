import Foundation
import PrismCore
import Testing
@testable import PrismData

/// Large synthetic catalogs. Bounds are generous (debug build, tests running in parallel);
/// measured numbers are printed.
@Suite("Performance", .serialized)
struct PerformanceTests {
    @Test func buildLargeCatalogAndSearch() async throws {
        let (sources, catalogs) = Synthetic.catalogs(movies: 150_000, series: 20_000, channels: 30_000)
        let (catalog, buildMS) = await measureMilliseconds {
            await CatalogBuilder.build(sources: sources, catalogs: catalogs)
        }
        print("[perf] CatalogBuilder.build 150k movies + 20k series + 30k channels: \(Int(buildMS)) ms → \(catalog.movies.count) movies, \(catalog.series.count) series, \(catalog.channels.count) channel groups")
        #expect(buildMS < 6_000)
        #expect(catalog.movies.count < 150_000, "duplicates were grouped")
        #expect(catalog.movies.count > 100_000)

        let (recommendations, recommendationMS) = await measureMilliseconds {
            await RecommendationBuilder.build(for: catalog)
        }
        print("[perf] Recommendations for \(catalog.movies.count + catalog.series.count) titles: \(String(format: "%.2f", recommendationMS)) ms")
        #expect(recommendationMS < 150)
        let selection = recommendations.selection(for: HomeAudioLanguage.defaults)
        #expect(selection.highlights.isEmpty)
        #expect(selection.wellRated.isEmpty)

        let (index, indexMS) = await measureMilliseconds { await SearchIndex.build(from: catalog) }
        print("[perf] SearchIndex.build \(index.entryCount) entries, \(index.wordCount) words: \(Int(indexMS)) ms")
        #expect(index.entryCount > 150_000)

        var rng = SplitMix64(seed: 99)
        var queries = (0..<40).map { _ in String(Synthetic.vocabulary.randomElement(using: &rng)!.prefix(Int.random(in: 1...5, using: &rng))) }
        queries += ["k", "a", "chaine 1", "ka lo", "zzzzq", "elo", Synthetic.title(&rng).lowercased()]
        var worst = 0.0
        var worstQuery = ""
        var total = 0.0
        var hits = 0
        for query in queries {
            let (results, ms) = await measureMilliseconds { index.search(query) }
            if ms > worst { worst = ms; worstQuery = query }
            total += ms
            if !results.isEmpty { hits += 1 }
        }
        let average = total / Double(queries.count)
        print("[perf] search over \(index.entryCount) entries: avg \(String(format: "%.2f", average)) ms, worst \(String(format: "%.2f", worst)) ms (\(queries.count) queries, \(hits) with results; worst query “\(worstQuery)”)")
        #expect(average < 60)
        #expect(hits > queries.count / 2)
    }

    @Test func cacheEncodeDecode() async throws {
        let (_, catalogs) = Synthetic.catalogs(movies: 150_000, series: 0, channels: 0)
        var big = SourceCatalog(sourceID: "perf")
        big.movies = catalogs.flatMap(\.movies)
        big.categories = catalogs.flatMap(\.categories)

        // Shipped format: segmented JSON + LZFSE, encoded / decoded in parallel.
        let (data, encodeMS) = try await measureMilliseconds { try await CatalogCache.encode(big, version: 1) }
        let (decoded, decodeMS) = await measureMilliseconds { await CatalogCache.decode(data, version: 1) }
        print("[perf] CatalogCache (segmented JSON+LZFSE, parallel) 150k movies: encode \(Int(encodeMS)) ms, decode \(Int(decodeMS)) ms, \(data.count / 1_024) KiB")
        #expect(decoded?.movies.count == 150_000)
        #expect(decoded?.movies.first == big.movies.first)
        #expect(decodeMS < 20_000)

        // Single-document baselines; set PRISM_PERF_COMPARE=1 (measured: JSON ≈ 3.5 s / 1.7 s, binary
        // plist ≈ 3× slower and 2.5× bigger once compressed).
        guard ProcessInfo.processInfo.environment["PRISM_PERF_COMPARE"] == "1" else { return }
        for encoding in [CompressedCodableFile.Encoding.json, .binaryPropertyList] {
            let (data, encodeMS) = try await measureMilliseconds { try CompressedCodableFile.encode(big, version: 1, encoding: encoding) }
            let (decoded, decodeMS) = await measureMilliseconds { CompressedCodableFile.decode(SourceCatalog.self, from: data, version: 1) }
            print("[perf] single-document \(encoding) 150k movies: encode \(Int(encodeMS)) ms, decode \(Int(decodeMS)) ms, \(data.count / 1_024) KiB")
            #expect(decoded?.movies.count == 150_000)
        }
    }
}
