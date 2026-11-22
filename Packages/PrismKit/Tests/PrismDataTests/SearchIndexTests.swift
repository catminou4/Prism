import Foundation
import PrismCore
import Testing
@testable import PrismData

@Suite("SearchIndex")
struct SearchIndexTests {
    typealias F = Fixture

    static func makeIndex() async -> (Catalog, SearchIndex) {
        let movies = [
            F.movie(F.a, "1", "Amélie", year: 2001, quality: .hd),
            F.movie(F.a, "2", "The Dark Knight", year: 2008, quality: .uhd),
            F.movie(F.a, "3", "Dune", year: 2021, quality: .uhd),
            F.movie(F.a, "4", "Dune : Deuxième partie", year: 2024, quality: .hd),
            F.movie(F.a, "5", "Children of Dune", year: 2003),
            F.movie(F.a, "6", "Stargate", year: 1994),
            F.movie(F.a, "7", "Star Wars", year: 1977, quality: .hd),
            F.movie(F.a, "8", "Lone Star", year: 1996),
            F.movie(F.a, "9", "Dune", year: 1984, quality: .sd),
            F.movie(F.a, "10", "Le Fabuleux Destin d'Amélie Poulain", year: 2001, quality: .sd),
            F.movie(F.a, "11", "Œdipe roi", year: 1967),
        ]
        let series = [F.series(F.a, "1", "Knight Rider", year: 1982), F.series(F.a, "2", "Dune: Prophecy", year: 2024)]
        let channels = [F.channel(F.a, "1", "TF1", number: 1), F.channel(F.a, "2", "TF1 Séries Films", number: 20), F.channel(F.a, "3", "Star TV")]
        let catalog = await F.build([F.source(F.a)], [SourceCatalog(sourceID: F.a, channels: channels, movies: movies, series: series)])
        return (catalog, await SearchIndex.build(from: catalog))
    }

    @Test func accentInsensitive() async {
        let (_, index) = await Self.makeIndex()
        let results = index.search("amelie")
        #expect(results.movies.map(\.title).contains("Amélie"))
        #expect(results.movies.first?.title == "Amélie", "exact match first")
        #expect(index.search("AMÉLIE").movies.first?.title == "Amélie")
        #expect(index.search("oedipe").movies.map(\.title) == ["Œdipe roi"])
        #expect(index.search("séries").channels.map(\.name) == ["TF1 Séries Films"])
    }

    @Test func multiTokenAND() async {
        let (_, index) = await Self.makeIndex()
        #expect(index.search("dark knight").movies.map(\.title) == ["The Dark Knight"])
        #expect(index.search("knight dark").movies.map(\.title) == ["The Dark Knight"])
        #expect(index.search("kni da").movies.map(\.title) == ["The Dark Knight"])
        #expect(index.search("dark xyz").isEmpty)
        #expect(index.search("knight").series.map(\.title) == ["Knight Rider"])
        #expect(index.search("dune 1984").movies.map(\.year) == [1984], "year is searchable")
    }

    @Test func rankingExactThenPrefixThenWords() async {
        let (_, index) = await Self.makeIndex()
        let titles = index.search("dune").movies.map(\.title)
        #expect(titles.count == 4)
        #expect(Array(titles.prefix(2)) == ["Dune", "Dune"], "exact matches first")
        #expect(titles[2] == "Dune : Deuxième partie", "full-name prefix next")
        #expect(titles[3] == "Children of Dune", "word match last")
        let dunes = index.search("dune").movies.prefix(2)
        #expect(dunes.map(\.year) == [2021, 1984], "ties broken by quality")
    }

    @Test func prefixBeatsSubstringAndSubstringIsAFallback() async {
        let (_, index) = await Self.makeIndex()
        let star = index.search("star").movies.map(\.title)
        #expect(Set(star) == ["Star Wars", "Stargate", "Lone Star"])
        #expect(star.last == "Lone Star")
        // "gate" prefix-matches nothing: substring fallback finds Stargate.
        #expect(index.search("gate").movies.map(\.title) == ["Stargate"])
        // "ars" only appears inside words.
        #expect(index.search("ars").movies.map(\.title) == ["Star Wars"])
        #expect(index.search("zzzz").isEmpty)
    }

    @Test func topHitAcrossKinds() async {
        let (_, index) = await Self.makeIndex()
        let tf1 = index.search("tf1")
        if case .channel(let channel) = tf1.topHit {
            #expect(channel.name == "TF1")
        } else {
            Issue.record("expected a channel top hit, got \(String(describing: tf1.topHit))")
        }
        #expect(tf1.channels.map(\.name) == ["TF1", "TF1 Séries Films"])
        if case .title(let title) = index.search("knight rider").topHit {
            #expect(title.title == "Knight Rider")
        } else {
            Issue.record("expected the series as top hit")
        }
    }

    @Test func emptyQueriesAndLimits() async {
        let (_, index) = await Self.makeIndex()
        #expect(index.search("").isEmpty)
        #expect(index.search("   ").isEmpty)
        #expect(index.search("!!").isEmpty)
        #expect(index.search("d", limit: 2).movies.count == 2)
        #expect(SearchIndex.empty.search("dune").isEmpty)
    }

    // MARK: - wordMasks / substring prefilter (120 Hz pass)

    /// The byte-class mask of every word must cover each byte class the word contains:
    /// the substring fallback skips words whose mask lacks the token's first byte, so a
    /// mask missing a class would silently drop true matches.
    @Test func wordMasksCoverEveryByteClass() async throws {
        let (_, index) = await Self.makePropertyIndex()
        for rank in 0..<index.wordCount {
            let start = Int(index.wordOffsets[rank]), end = Int(index.wordOffsets[rank + 1])
            var expected: UInt64 = 0
            for position in start..<end {
                expected |= UInt64(1) << (index.wordBytes[position] & 63)
            }
            #expect(index.wordMasks[rank] == expected, "word \(rank) mask must cover every byte class it contains")
        }
    }

    /// Property check over a catalogue mixing ASCII, diacritics, Cyrillic, Arabic, CJK and
    /// emoji-separated names: the index must return exactly the entries a brute-force replay
    /// of the prefix→substring semantics finds. `wordMasks` may only skip words that cannot
    /// contain the token — a false negative here is a lost search hit.
    @Test func substringFallbackNeverSkipsTrueMatches() async throws {
        let (_, index) = await Self.makePropertyIndex()
        let rankBytes = Self.rankBytes(of: index)
        let entryRanks = Self.entryRanks(of: index)
        for query in Self.propertyQueries {
            let expected = Self.bruteForceEntries(query: query, entryRanks: entryRanks, rankBytes: rankBytes)
            let actual = Self.entryIndexes(index, index.search(query, limit: 10_000))
            #expect(actual == expected, "query \"\(query)\"")
        }
    }

    // MARK: - Property-test plumbing

    /// Words of every entry as word ranks (entryWords slice per entry).
    private static func entryRanks(of index: SearchIndex) -> [[Int]] {
        (0..<index.entryCount).map { entry in
            let start = Int(index.entryWordOffsets[entry]), end = Int(index.entryWordOffsets[entry + 1])
            return (start..<end).map { Int(index.entryWords[$0]) }
        }
    }

    /// UTF-8 bytes of every unique word, indexed by rank.
    private static func rankBytes(of index: SearchIndex) -> [[UInt8]] {
        (0..<index.wordCount).map { rank in
            let start = Int(index.wordOffsets[rank]), end = Int(index.wordOffsets[rank + 1])
            return Array(index.wordBytes[start..<end])
        }
    }

    /// Maps search results back to entry indices (channels, then movies, then series).
    private static func entryIndexes(_ index: SearchIndex, _ results: SearchResults) -> Set<Int> {
        var entries = Set<Int>()
        for group in results.channels {
            if let position = index.channels.firstIndex(of: group) { entries.insert(position) }
        }
        for title in results.movies {
            if let position = index.movies.firstIndex(of: title) { entries.insert(index.movieStart + position) }
        }
        for title in results.series {
            if let position = index.series.firstIndex(of: title) { entries.insert(index.seriesStart + position) }
        }
        return entries
    }

    /// Brute-force replay of `SearchIndex.search` semantics at entry level: token-wise AND,
    /// prefix ranges first, substring fallback only when no entry prefix-matches, and no
    /// substring fallback when a token is shorter than `minimumSubstringLength` bytes.
    private static func bruteForceEntries(query: String, entryRanks: [[Int]], rankBytes: [[UInt8]]) -> Set<Int> {
        let tokens = TextFolding.words(ofFolded: TextFolding.fold(query))
        guard !tokens.isEmpty else { return [] }

        var prefixMatches = Set<Int>()
        for (entry, ranks) in entryRanks.enumerated() {
            let matches = tokens.allSatisfy { token in
                ranks.contains { rankBytes[$0].starts(with: token) }
            }
            if matches { prefixMatches.insert(entry) }
        }
        if !prefixMatches.isEmpty { return prefixMatches }

        guard tokens.allSatisfy({ $0.count >= SearchIndex.minimumSubstringLength }) else { return [] }
        return Set(entryRanks.indices.filter { entry in
            tokens.allSatisfy { token in
                entryRanks[entry].contains { containsBytes(rankBytes[$0], token) }
            }
        })
    }

    private static func containsBytes(_ word: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= word.count else { return false }
        guard !needle.isEmpty else { return true }
        for start in 0...(word.count - needle.count) {
            if word[start..<(start + needle.count)].elementsEqual(needle) { return true }
        }
        return false
    }

    /// Catalogue exercising every byte class of the word masks: ASCII, Latin diacritics,
    /// Cyrillic, Arabic, CJK, emoji-separated names — plus a second source producing
    /// multi-variant titles (alternate names) and shared words across kinds.
    private static func makePropertyIndex() async -> (Catalog, SearchIndex) {
        let moviesA = [
            F.movie(F.a, "m1", "Le Fabuleux Destin d'Amélie Poulain", year: 2001),
            F.movie(F.a, "m2", "Amélie", year: 2001),
            F.movie(F.a, "m3", "Television", year: 2006),
            F.movie(F.a, "m4", "The Dark Knight", year: 2008),
            F.movie(F.a, "m5", "Dune", year: 2021, quality: .uhd),
            F.movie(F.a, "m6", "Children of Dune", year: 2003),
            F.movie(F.a, "m7", "Star Wars", year: 1977),
            F.movie(F.a, "m8", "Lone Star", year: 1996),
            F.movie(F.a, "m9", "Dune", year: 1984),
            F.movie(F.a, "m10", "«Guillemets»", year: 1999),
            F.movie(F.a, "m11", "Москва", year: 2019),
            F.movie(F.a, "m12", "مسلسل رمضان", year: 2023),
            F.movie(F.a, "m13", "\u{6771}\u{4EAC}\u{7269}\u{8A9E}", year: 1953),
            F.movie(F.a, "m14", "Film 🏆 Partie Deux", year: 2020),
            F.movie(F.a, "m15", "Café Society", year: 2013),
            F.movie(F.a, "m16", "Dune: Part One", year: 2021),
        ]
        let moviesB = [
            F.movie(F.b, "b1", "Dune", year: 2021, quality: .uhd), // variant of "Dune" 2021
            F.movie(F.b, "b2", "Dune (2021)", year: 2021), // variant + alternate name
            F.movie(F.b, "b3", "Amélie", year: 2001), // variant of "Amélie" 2001
        ]
        let series = [
            F.series(F.a, "s1", "Knight Rider", year: 1982),
            F.series(F.a, "s2", "Dune: Prophecy", year: 2024),
            F.series(F.a, "s3", "L'Été Indien", year: 1987),
        ]
        let channels = [
            F.channel(F.a, "c1", "TF1", number: 1),
            F.channel(F.a, "c2", "TF1 Séries Films", number: 20),
            F.channel(F.a, "c3", "Star TV"),
            F.channel(F.a, "c4", "Chaîne info"),
            F.channel(F.a, "c5", "الجزيرة"),
        ]
        let catalog = await F.build(
            [F.source(F.a), F.source(F.b)],
            [
                SourceCatalog(sourceID: F.a, channels: channels, movies: moviesA, series: series),
                SourceCatalog(sourceID: F.b, movies: moviesB),
            ]
        )
        return (catalog, await SearchIndex.build(from: catalog))
    }

    /// Prefix hits, interior substrings, mixed prefix+substring tokens, single characters,
    /// year-only tokens, punctuation/emoji wrappers and non-Latin scripts.
    private static let propertyQueries: [String] = [
        "dune", "dun", "dune 2021", "dune 021", "une", "part", "fabuleux", "buleux",
        "amelie", "melie", "poulain amelie", "tele", "levis", "vision", "café", "societe",
        "ildren", "of dun", "ildren of", "the dark", "dark knight rises", "star", "ars",
        "star tv", "star w", "tf1 série", "info chaîne", "knight rid", "dune pro",
        "1984", "984", "d", "moskv", "оскв", "москва", "سلسل", "رمضان", "الجزيرة",
        "", "film 🏆", "guille", "mets", "«dune»", "dune。", "\u{4EAC}\u{7269}", "\u{6771}\u{4EAC}", "🏆", "🔥", "  spaced   out  ",
    ]
}
