import Foundation
import PrismCore
import Testing
@testable import PrismData

/// Synthetic ~115k-entry benchmark for `SearchIndex`. Builds the grouped `Catalog` directly
/// (the index only reads names, years, variants counts and dates) so the suite stays fast;
/// query latency is what is measured, not `CatalogBuilder`.
@Suite("SearchIndex performance", .serialized)
struct SearchIndexPerformanceTests {
    /// p50/p95/p99/max over `samples`, in milliseconds.
    private static func percentiles(_ samples: [Double]) -> (p50: Double, p95: Double, p99: Double, max: Double) {
        let sorted = samples.sorted()
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))] }
        return (at(0.50), at(0.95), at(0.99), sorted.last ?? 0)
    }

    private static func format(_ ms: Double) -> String { String(format: "%.2f", ms) }

    private static func wordBytes(at rank: Int, in index: SearchIndex) -> ArraySlice<UInt8> {
        let start = Int(index.wordOffsets[rank]), end = Int(index.wordOffsets[rank + 1])
        return index.wordBytes[start..<end]
    }

    /// Whether `token` prefix-matches at least one indexed word (same binary search as the index).
    private static func hasPrefixWord(_ index: SearchIndex, _ token: [UInt8]) -> Bool {
        let count = index.wordCount
        var low = 0, high = count
        // First word >= token.
        while low < high {
            let mid = (low + high) >> 1
            if wordBytes(at: mid, in: index).lexicographicallyPrecedes(token[...]) { low = mid + 1 } else { high = mid }
        }
        guard low < count else { return false }
        return wordBytes(at: low, in: index).starts(with: token)
    }

    @Test func queryLatencyAt100k() async throws {
        var rng = SplitMix64(seed: 7)
        let movies = (0..<90_000).map { index in
            MediaTitle(
                id: TitleID(rawValue: "movie:\(index)"), kind: .movie,
                title: Synthetic.title(&rng), year: Int.random(in: 1950...2025, using: &rng),
                variants: [], addedAt: Fixture.reference.addingTimeInterval(-Double(Int.random(in: 0...3_000_000, using: &rng)))
            )
        }
        let series = (0..<15_000).map { index in
            MediaTitle(
                id: TitleID(rawValue: "series:\(index)"), kind: .series,
                title: Synthetic.title(&rng), year: Int.random(in: 1990...2025, using: &rng),
                variants: [], addedAt: Fixture.reference.addingTimeInterval(-Double(Int.random(in: 0...3_000_000, using: &rng)))
            )
        }
        let channels = (0..<10_000).map { index in
            ChannelGroup(
                id: "channel:\(index)",
                name: index % 4 == 0 ? "Chaîne \(index / 4)" : Synthetic.title(&rng),
                variants: []
            )
        }
        let catalog = Catalog(
            sources: [Fixture.source(Fixture.a)], channels: channels, movies: movies, series: series,
            liveCategories: [], movieCategories: [], seriesCategories: [], indexes: Catalog.Indexes()
        )

        let (index, buildMS) = await measureMilliseconds { await SearchIndex.build(from: catalog) }
        print("[search-perf] build \(index.entryCount) entries, \(index.wordCount) words: \(Self.format(buildMS)) ms")
        #expect(index.entryCount == 115_000)

        // Query battery: single-char prefix, word prefixes, multi-token AND, year token,
        // substring-only fallback and misses. Deterministic.
        var rngQueries = SplitMix64(seed: 99)
        var queries: [(label: String, query: String)] = []
        // Prefixes of real vocabulary words (1–4 chars) — the common typing path.
        for _ in 0..<12 {
            let word = Synthetic.vocabulary.randomElement(using: &rngQueries)!
            let length = Int.random(in: 1...min(4, word.count), using: &rngQueries)
            queries.append(("prefix", String(word.prefix(length))))
        }
        // Full words and 2–3 token AND queries.
        for _ in 0..<8 {
            let count = Int.random(in: 1...3, using: &rngQueries)
            let words = (0..<count).map { _ in Synthetic.vocabulary.randomElement(using: &rngQueries)! }
            queries.append(("words", words.joined(separator: " ")))
        }
        // Year tokens and numeric-ish queries.
        queries += [("year", "2021"), ("year", "2024"), ("digits", "123"), ("channel", "chaine 12")]
        // Substring-only: interior slices of vocabulary words, kept only when no indexed
        // word starts with them (forces the substringSearch fallback).
        var substringQueries = 0
        var attempts = 0
        while substringQueries < 10, attempts < 200 {
            attempts += 1
            let word = Synthetic.vocabulary.randomElement(using: &rngQueries)!
            guard word.count >= 5 else { continue }
            let start = Int.random(in: 1...(word.count - 3), using: &rngQueries)
            let length = Int.random(in: 2...min(3, word.count - start), using: &rngQueries)
            let token = String(word.dropFirst(start).prefix(length))
            let folded = Array(TextFolding.fold(token).utf8)
            if !Self.hasPrefixWord(index, folded) {
                queries.append(("substring", token))
                substringQueries += 1
            }
        }
        queries += [("miss", "zzzzq"), ("miss", "qx jkvb")]

        var samples: [(label: String, ms: Double, hits: Int)] = []
        samples.reserveCapacity(queries.count * 3)
        for (label, query) in queries {
            // Two passes: first warms any lazy paths, second is measured.
            _ = index.search(query, limit: 50)
            for _ in 0..<2 {
                let (results, ms) = await measureMilliseconds { index.search(query, limit: 50) }
                let hits = results.channels.count + results.movies.count + results.series.count
                samples.append((label, ms, hits))
            }
        }

        var byLabel: [String: [Double]] = [:]
        for sample in samples { byLabel[sample.label, default: []].append(sample.ms) }
        for label in ["prefix", "words", "year", "digits", "channel", "substring", "miss"] {
            guard let group = byLabel[label], !group.isEmpty else { continue }
            let p = Self.percentiles(group)
            print("[search-perf] \(label): n=\(group.count) p50 \(Self.format(p.p50)) ms, "
                + "p95 \(Self.format(p.p95)) ms, p99 \(Self.format(p.p99)) ms, max \(Self.format(p.max)) ms")
        }
        let all = samples.map(\.ms)
        let p = Self.percentiles(all)
        print("[search-perf] ALL: n=\(all.count) p50 \(Self.format(p.p50)) ms, "
            + "p95 \(Self.format(p.p95)) ms, p99 \(Self.format(p.p99)) ms, max \(Self.format(p.max)) ms")

        // Generous bounds: debug-build test machine under parallel load. The prefix path is
        // the hot one; substring fallback is allowed more headroom.
        let prefixP95 = Self.percentiles(byLabel["prefix"] ?? []).p95
        #expect(prefixP95 < 25, "prefix p95 \(Self.format(prefixP95)) ms")
        #expect(p.p99 < 250, "overall p99 \(Self.format(p.p99)) ms")
    }
}
