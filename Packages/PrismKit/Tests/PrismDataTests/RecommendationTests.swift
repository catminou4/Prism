import PrismCore
import Testing
@testable import PrismData

@Suite("Sélections du catalogue")
struct RecommendationTests {
    @Test func availableTitlesAppearOnceAcrossEditorialShelves() async throws {
        let french = Fixture.movie(Fixture.a, "fr", "Anatomy of a Fall", year: 2023)
        let frenchVF = Fixture.movie(Fixture.b, "fr-vf", "Anatomy of a Fall", year: 2023, raw: "VF | Anatomy of a Fall (2023) 4K")
        let american = Fixture.series(Fixture.a, "us", "Severance", year: 2022)
        let discovery = Fixture.movie(Fixture.a, "discover", "Winter Break", year: 2023, backdrop: "winter.jpg")
        let wrongYear = Fixture.movie(Fixture.a, "wrong-year", "Le Comte de Monte-Cristo", year: 2002)
        let adult = Fixture.movie(Fixture.a, "adult", "Titane", year: 2021, poster: "adult.jpg", rating: 10, adult: true)
        let catalog = await Fixture.build(
            [Fixture.source(Fixture.a), Fixture.source(Fixture.b)],
            [SourceCatalog(sourceID: Fixture.a, movies: [french, discovery, wrongYear, adult], series: [american]),
             SourceCatalog(sourceID: Fixture.b, movies: [frenchVF])]
        )

        let recommendations = await RecommendationBuilder.build(for: catalog)
        let grouped = try #require(recommendations.french.first)
        #expect(recommendations.french.map(\.title) == ["Anatomy of a Fall"])
        #expect(Set(grouped.variants.map(\.id)) == [french.id, frenchVF.id])
        #expect(recommendations.american.map(\.title) == ["Severance"])
        #expect(recommendations.discoveries.map(\.title) == ["Winter Break"])
        #expect(recommendations.highlights.map(\.title) == ["Winter Break", "Anatomy of a Fall", "Severance"])
        #expect(recommendations.wellRated.isEmpty)
    }

    @Test func sparsePlaylistUsesDistinctiveUndatedTitlesWithoutInferringCountryFromAudio() async {
        let exact = Fixture.movie(Fixture.a, "exact", "Le Fabuleux Destin d’Amélie Poulain")
        let ambiguous = Fixture.movie(Fixture.a, "ambiguous", "Le Parrain")
        var dubbed = Fixture.movie(Fixture.a, "dub", "Le Secret du rivage", poster: "rivage.jpg", rating: 8.1)
        dubbed.tags = ["VF", "EN"]
        let unverified = Fixture.movie(Fixture.a, "unverified", "Le Chêne doré", rating: 10)
        let catalog = await Fixture.build(
            [Fixture.source(Fixture.a)],
            [SourceCatalog(sourceID: Fixture.a, movies: [exact, ambiguous, dubbed, unverified])]
        )

        let recommendations = await RecommendationBuilder.build(for: catalog)
        #expect(recommendations.french.map(\.title) == [exact.title])
        #expect(recommendations.american.isEmpty)
        #expect(recommendations.discoveries.isEmpty)
        #expect(recommendations.wellRated.map(\.title) == [dubbed.title])
        #expect(recommendations.highlights.map(\.title) == [dubbed.title, exact.title])
    }
}
