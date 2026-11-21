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
}
