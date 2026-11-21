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
        let selection = recommendations.selection(for: HomeAudioLanguage.defaults)
        let grouped = try #require(selection.french.first)
        #expect(selection.french.map(\.title) == ["Anatomie d’une chute"])
        #expect(Set(grouped.variants.map(\.id)) == [french.id, frenchVF.id])
        #expect(selection.american.map(\.title) == ["Severance"])
        #expect(selection.discoveries.map(\.title) == ["Winter Break"])
        #expect(selection.highlights.map(\.title) == ["Winter Break", "Anatomie d’une chute", "Severance"])
        #expect(selection.wellRated.isEmpty)
        let index = await SearchIndex.build(from: catalog, recommendations: recommendations)
        #expect(index.search("anatomie d'une chute").movies.first?.id == grouped.id)
        #expect(index.search("anatomy of a fall").movies.first?.id == grouped.id)
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

        let selections = await RecommendationBuilder.build(for: catalog)
        let recommendations = selections.selection(for: HomeAudioLanguage.defaults)
        #expect(recommendations.french.map(\.title) == [exact.title])
        #expect(recommendations.american.isEmpty)
        #expect(recommendations.discoveries.isEmpty)
        #expect(selections.selection(for: [.english]).wellRated.map(\.title) == [dubbed.title])
        #expect(recommendations.highlights.map(\.title) == [exact.title])
    }

    @Test func playbackLanguagesRespectProviderVersionsAndPreserveOfficialNames() async throws {
        var spanishDune = Fixture.movie(Fixture.a, "dub-es", "Dune: Part Two", year: 2024, tmdbID: 693134)
        spanishDune.tags = ["ES"]
        var frenchDune = Fixture.movie(Fixture.a, "dub-fr", "Diuna – Część druga", year: 2024, tmdbID: 693134)
        frenchDune.tags = ["VF"]
        var originalOnly = Fixture.series(Fixture.a, "us", "Severance", year: 2022)
        originalOnly.tags = ["VOSTFR"]
        var unknownMultilingual = Fixture.movie(Fixture.a, "unverified", "Année lumière", poster: "annee.jpg", rating: 9)
        unknownMultilingual.tags = ["MULTI", "VOSTFR"]
        var bilingualLabel = Fixture.movie(Fixture.a, "untidy", "Une autre vie حياة", poster: "vie.jpg", rating: 9)
        bilingualLabel.tags = ["FR"]
        let catalog = await Fixture.build(
            [Fixture.source(Fixture.a)], [SourceCatalog(
                sourceID: Fixture.a, movies: [spanishDune, frenchDune, unknownMultilingual, bilingualLabel], series: [originalOnly]
            )]
        )

        let recommendations = await RecommendationBuilder.build(for: catalog)
        let french = recommendations.selection(for: [.french])
        let english = recommendations.selection(for: [.english])
        let dune = try #require(french.american.first)
        #expect(dune.title == "Dune : Deuxième Partie")
        #expect(Set(dune.variants.map(\.id)) == [spanishDune.id, frenchDune.id])
        #expect(english.american.map(\.title) == ["Severance"])
        #expect(french.wellRated.isEmpty)
        #expect(english.wellRated.isEmpty)
        #expect(try #require(catalog.title(dune.id)).title != dune.title)
        #expect(recommendations.named(try #require(catalog.title(dune.id))).title == dune.title)
    }

    @Test func datedEditorialAliasesGroupWithoutProviderIDsAndKeepPreviousLinks() async throws {
        var french = Fixture.movie(Fixture.a, "vf", "Le Comte de Monte-Cristo", year: 2024)
        french.tags = ["VF"]
        var english = Fixture.movie(Fixture.a, "vo", "The Count of Monte Cristo", year: 2024)
        english.tags = ["EN"]
        let earlierAdaptation = Fixture.movie(Fixture.a, "older", "The Count of Monte Cristo", year: 2002)
        let catalog = await Fixture.build(
            [Fixture.source(Fixture.a)],
            [SourceCatalog(sourceID: Fixture.a, movies: [french, english, earlierAdaptation])]
        )

        let formerKey = TitleID(kind: .movie, normalizedTitle: TitleNormalizer.key(english.title), year: 2024)
        let group = try #require(catalog.title(formerKey))
        #expect(catalog.movies.count == 2)
        #expect(Set(group.variants.map(\.id)) == [french.id, english.id])
        #expect(catalog.titleID(containing: english.id) == group.id)
        let recommendations = await RecommendationBuilder.build(for: catalog)
        #expect(recommendations.selection(for: [.french]).french.map(\.id) == [group.id])
        #expect(recommendations.selection(for: [.english]).french.map(\.id) == [group.id])
    }

    @Test func spotlightUsesAReadableSynopsisFromAnotherEdition() async throws {
        let arabic = "يعود اللص إلى مدينته بعد سنوات طويلة ليكشف الحقيقة ويساعد عائلته على استعادة حقها."
        let french = "Un voleur revient dans sa ville natale et découvre que sa famille est au cœur d’une affaire qui dure depuis des années."
        var first = Fixture.series(Fixture.a, "lupin-uhd", "Lupin", year: 2021, quality: .uhd, plot: arabic)
        first.tags = ["VF"]
        var second = Fixture.series(Fixture.b, "lupin-hd", "Lupin", year: 2021, quality: .hd, plot: french)
        second.tags = ["VF"]
        let catalog = await Fixture.build(
            [Fixture.source(Fixture.a), Fixture.source(Fixture.b)],
            [SourceCatalog(sourceID: Fixture.a, series: [first]), SourceCatalog(sourceID: Fixture.b, series: [second])]
        )
        let recommendations = await RecommendationBuilder.build(for: catalog)
        #expect(recommendations.selection(for: [.french]).highlights.first?.plot == french)
        #expect(ProviderSynopsis.preferredFrenchOrEnglish(from: [arabic]) == nil)
    }

    @Test func anotherLanguageCannotDisplaceEligibleTitlesBeforeRanking() async {
        let english = (0..<110).map { number in
            var item = Fixture.movie(Fixture.a, "en\(number)", "English film \(number)", poster: "en.jpg", rating: 9.8)
            item.tags = ["EN"]
            return item
        }
        var french = Fixture.movie(Fixture.a, "fr", "Un secret de famille", poster: "fr.jpg", rating: 8)
        french.tags = ["VF"]
        let catalog = await Fixture.build(
            [Fixture.source(Fixture.a)],
            [SourceCatalog(sourceID: Fixture.a, movies: english + [french])]
        )
        let recommendations = await RecommendationBuilder.build(for: catalog)
        let selection = recommendations.selection(for: [.french])
        #expect(selection.wellRated.map(\.title) == [french.title])
        #expect(selection.highlights.map(\.title) == [french.title])
    }
}
