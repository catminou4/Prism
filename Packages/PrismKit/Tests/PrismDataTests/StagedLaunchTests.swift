import Foundation
import PrismCore
import Testing
@testable import PrismData

@Suite("Publication progressive du lancement")
struct StagedLaunchTests {
    @Test func editorialStageLandsFirstAndFallbackCompletionPreservesIt() async throws {
        let exact = Fixture.movie(Fixture.a, "exact", "Le Fabuleux Destin d’Amélie Poulain")
        var dubbed = Fixture.movie(Fixture.a, "dub", "Le Secret du rivage", poster: "rivage.jpg", rating: 8.1)
        dubbed.tags = ["VF", "EN"]
        let catalog = await Fixture.build(
            [Fixture.source(Fixture.a)],
            [SourceCatalog(sourceID: Fixture.a, movies: [exact, dubbed])]
        )

        let editorial = await RecommendationBuilder.buildEditorial(for: catalog)
        let editorialEnglish = editorial.selection(for: [.english])
        #expect(editorial.selection(for: [.french]).french.map(\.title) == [exact.title])
        #expect(editorialEnglish.wellRated.isEmpty)
        #expect(editorialEnglish.highlights.isEmpty)

        let completed = await RecommendationBuilder.completeWithFallback(editorial, for: catalog)
        #expect(Set(completed.editorialCopy.keys) == Set(editorial.editorialCopy.keys))
        #expect(completed.selection(for: [.french]).french.map(\.title) == [exact.title])
        #expect(completed.selection(for: [.english]).wellRated.map(\.title) == [dubbed.title])
        #expect(completed.selection(for: [.english]).highlights.map(\.title) == [dubbed.title])
    }

    @Test func homeSeedUsesFeaturedAndRecentlyAddedWithoutAnIndex() async throws {
        let movies = (0..<7).map { index in
            Fixture.movie(
                Fixture.a, "m\(index)", "Film récent \(index)", year: 2024,
                poster: "p\(index).jpg", backdrop: "b\(index).jpg",
                plot: "Une intrigue suffisamment longue pour être retenue dans la sélection.",
                rating: 8.5, added: Fixture.reference.addingTimeInterval(TimeInterval(-index * 3_600))
            )
        }
        let series = (0..<7).map { index in
            Fixture.series(
                Fixture.a, "s\(index)", "Série récente \(index)", year: 2024,
                poster: "s\(index).jpg", plot: "Une intrigue suffisamment longue pour être retenue dans la sélection.",
                rating: 8.4, added: Fixture.reference.addingTimeInterval(TimeInterval(-index * 3_600 - 900))
            )
        }
        let adult = Fixture.movie(Fixture.a, "adult", "Film adulte", poster: "adult.jpg", rating: 9, adult: true)
        let withoutArtwork = Fixture.movie(Fixture.a, "no-art", "Film sans image", rating: 9)
        let withoutMetadata = Fixture.movie(Fixture.a, "no-metadata", "Film sans métadonnées", poster: "no-metadata.jpg")
        let episodeLike = Fixture.movie(Fixture.a, "episode-like", "Some Show S01E01", poster: "episode.jpg", rating: 9)
        var englishOnly = Fixture.movie(
            Fixture.a, "english-only", "English Only", year: 2025, poster: "english.jpg", backdrop: "english-wide.jpg",
            rating: 9.5, added: Fixture.reference.addingTimeInterval(3_600)
        )
        englishOnly.tags = ["EN"]
        let catalog = await Fixture.build(
            [Fixture.source(Fixture.a)],
            [SourceCatalog(sourceID: Fixture.a, movies: movies + [adult, withoutArtwork, withoutMetadata, episodeLike, englishOnly], series: series)]
        )

        let dismissedID = try #require(catalog.movies.first { $0.title == "Film récent 0" }?.id)
        let feed = await Curator.seedHome(
            catalog: catalog, recommendations: .empty, languages: [.french],
            profile: CurationProfile(dismissed: [dismissedID])
        )
        #expect(!feed.highlights.isEmpty)
        #expect(feed.shelves.map { $0.id } == ["new"])
        let shelf = try #require(feed.shelves.first)
        #expect(shelf.seeAll == nil)
        #expect(shelf.items.count >= 4)
        #expect(shelf.items.contains { $0.kind == MediaKind.movie })
        #expect(shelf.items.contains { $0.kind == MediaKind.series })
        #expect(shelf.items.allSatisfy { $0.posterURL != nil || $0.backdropURL != nil })
        #expect(!shelf.items.contains { $0.isAdult })
        #expect(!shelf.items.contains { $0.title == episodeLike.title })
        #expect(!shelf.items.contains { $0.title == withoutMetadata.title })
        #expect(!shelf.items.contains { $0.title == englishOnly.title })
        #expect(!feed.highlights.contains { $0.title.title == englishOnly.title })
        #expect(!shelf.items.contains { $0.id == dismissedID })
        #expect(!feed.highlights.contains { $0.id == dismissedID })
        let heroIDs = Set(feed.highlights.map { $0.id })
        #expect(shelf.items.allSatisfy { !heroIDs.contains($0.id) })
    }
}
