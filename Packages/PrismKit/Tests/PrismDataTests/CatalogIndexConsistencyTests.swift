import Foundation
import PrismCore
import Testing
@testable import PrismData

/// Large-enough inputs (past the 8_192 parallel thresholds) verify that the parallel grouping,
/// indexing, ranking and category passes produce the same structures as the serial semantics:
/// positions in the lookup tables must match the sorted title order, member lists must stay
/// ascending, and the whole build must be deterministic across repetitions.
struct CatalogIndexConsistencyTests {
    typealias F = Fixture

    /// Deterministic pseudo-random stream (LCG), so failures reproduce exactly.
    struct Random {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    static func generated(random: inout Random) -> (sources: [Source], catalogs: [SourceCatalog]) {
        let sources = [F.source(F.a), F.source(F.b), F.source(F.c)]
        var catalogs: [SourceCatalog] = []
        let titles = 5_200
        for (offset, source) in sources.enumerated() {
            var movies: [Movie] = []
            for index in 0..<titles {
                // ~40 % of items duplicate a title another source may carry too.
                let shared = random.next(100) < 40
                let serial = shared ? index / 2 : index * 7 + offset * 50_000
                let year: Int? = switch random.next(10) {
                case 0: nil
                case 1: 1_984
                default: 1_990 + random.next(35)
                }
                movies.append(F.movie(
                    source.id, "m\(serial)-\(index)", "Film \(serial)", year: year,
                    quality: [.unknown, .sd, .hd, .uhd][random.next(4)],
                    category: "cat-\(random.next(12))",
                    rating: random.next(100) < 70 ? Double(random.next(90) + 10) / 10 : nil,
                    added: F.reference.addingTimeInterval(TimeInterval(-random.next(400) * 86_400)),
                    tmdbID: random.next(100) < 8 ? serial : nil,
                    adult: random.next(100) < 3
                ))
            }
            var series: [Series] = []
            for index in 0..<700 {
                series.append(F.series(
                    source.id, "s\(index)", "Série \(index)", year: 1_990 + random.next(35),
                    category: "cat-\(random.next(4))",
                    rating: Double(random.next(90) + 10) / 10,
                    added: F.reference.addingTimeInterval(TimeInterval(-random.next(400) * 86_400)),
                    seasons: F.seasons(series: "s\(index)", source: source.id, counts: [2])
                ))
            }
            var channels: [Channel] = []
            for index in 0..<400 {
                channels.append(F.channel(
                    source.id, "c\(index)", "Chaîne \(index / 2)",
                    category: "cat-\(random.next(3))", epg: "epg-\(index)"
                ))
            }
            catalogs.append(SourceCatalog(
                sourceID: source.id,
                categories: (0..<12).map { F.category(source.id, .movie, "cat-\($0)", "Catégorie \($0)", sort: $0) }
                    + (0..<4).map { F.category(source.id, .series, "cat-\($0)", "Catégorie \($0)", sort: $0) }
                    + (0..<3).map { F.category(source.id, .live, "cat-\($0)", "Catégorie \($0)", sort: $0) },
                channels: channels, movies: movies, series: series
            ))
        }
        return (sources, catalogs)
    }

    @Test func lookupTablesMatchTheSortedPositions() async {
        var random = Random(state: 42)
        let (sources, catalogs) = Self.generated(random: &random)
        let catalog = await F.build(sources, catalogs)
        // Past every parallel threshold.
        #expect(catalog.movies.count > 8_192)

        for (position, title) in catalog.movies.enumerated() {
            #expect(catalog.indexes.movieByTitleID[title.id] == position)
            for variant in title.variants {
                #expect(catalog.indexes.movieByContent[variant.id] == position)
            }
        }
        for (position, title) in catalog.series.enumerated() {
            #expect(catalog.indexes.seriesByTitleID[title.id] == position)
            for variant in title.variants {
                #expect(catalog.indexes.seriesByContent[variant.id] == position)
            }
        }
        // Member lists must stay ascending (titles are bucketed in index order).
        for (_, members) in catalog.indexes.groupMembers {
            #expect(members == members.sorted())
        }
        // Rankings reference valid positions, without duplicates.
        for ranking in [catalog.indexes.featuredMovies, catalog.indexes.topRatedMovies] {
            #expect(Set(ranking).count == ranking.count)
            #expect(ranking.allSatisfy { $0 >= 0 && Int($0) < catalog.movies.count })
        }
    }

    @Test func buildIsDeterministicAcrossRepetitions() async {
        var random = Random(state: 7)
        let (sources, catalogs) = Self.generated(random: &random)
        let first = await F.build(sources, catalogs)
        let second = await F.build(sources, catalogs)
        #expect(first.movies == second.movies)
        #expect(first.series == second.series)
        #expect(first.channels == second.channels)
        #expect(first.indexes.movieByTitleID == second.indexes.movieByTitleID)
        #expect(first.indexes.movieByContent == second.indexes.movieByContent)
        #expect(first.indexes.seriesByTitleID == second.indexes.seriesByTitleID)
        #expect(first.indexes.seriesByContent == second.indexes.seriesByContent)
        #expect(first.indexes.featuredMovies == second.indexes.featuredMovies)
        #expect(first.indexes.topRatedMovies == second.indexes.topRatedMovies)
        #expect(first.indexes.groupMembers == second.indexes.groupMembers)
        #expect(first.movieCategories == second.movieCategories)
        #expect(first.liveCategories == second.liveCategories)
        #expect(first.seriesCategories == second.seriesCategories)
        #expect(first.indexes.topRatedSeries == second.indexes.topRatedSeries)
        #expect(first.indexes.featuredSeries == second.indexes.featuredSeries)
    }
}
