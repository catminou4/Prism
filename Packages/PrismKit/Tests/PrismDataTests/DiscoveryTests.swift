import Foundation
import PrismCore
import Testing
@testable import PrismData

@Suite("Découverte du catalogue")
struct DiscoveryTests {
    @Test func localSeparatesKindsLanguagesAndViewingSignals() async {
        var watched = Fixture.movie(Fixture.a, "watched", "La première veille", poster: "watched.jpg", genres: ["Science Fiction"])
        watched.tags = ["VF"]
        var multi = Fixture.movie(Fixture.a, "multi-fr", "La suivante", poster: "multi.jpg", genres: ["Science-fiction"], rating: 7)
        multi.tags = ["VF"]
        var otherEdition = Fixture.movie(Fixture.b, "multi-en", "La suivante", poster: "multi.jpg", genres: ["Science-fiction"], rating: 7)
        otherEdition.tags = ["EN"]
        var standalone = Fixture.movie(Fixture.a, "single", "La rencontre", poster: "single.jpg", genres: ["Drame"], rating: 9)
        standalone.tags = ["VF"]
        var english = Fixture.movie(Fixture.a, "international", "Moon Signal", poster: "foreign.jpg", genres: ["Science Fiction"], rating: 10)
        english.tags = ["EN"]
        var privateTitle = Fixture.movie(Fixture.a, "hidden", "Une œuvre masquée", poster: "hidden.jpg", genres: ["Science Fiction"], rating: 10, adult: true)
        privateTitle.tags = ["VF"]
        var show = Fixture.series(Fixture.a, "show", "Le phare", poster: "show.jpg", genres: ["Science Fiction"], rating: 8.5)
        show.tags = ["VF"]
        let catalog = await Fixture.build(
            [Fixture.source(Fixture.a), Fixture.source(Fixture.b)],
            [
                SourceCatalog(sourceID: Fixture.a, movies: [watched, multi, standalone, english, privateTitle], series: [show]),
                SourceCatalog(sourceID: Fixture.b, movies: [otherEdition]),
            ]
        )
        let watchedID = catalog.titleID(containing: watched.id)
        let profile = DiscoveryProfile(watched: watchedID.map { [$0] } ?? [])
        let movies = await DiscoveryBuilder.local(
            for: .movie, in: catalog, recommendations: .empty, languages: [.french], profile: profile, now: Fixture.reference
        )
        let series = await DiscoveryBuilder.local(
            for: .series, in: catalog, recommendations: .empty, languages: [.french], profile: profile, now: Fixture.reference
        )
        let withoutHistory = await DiscoveryBuilder.local(
            for: .movie, in: catalog, recommendations: .empty, languages: [.english], profile: .init(), now: Fixture.reference
        )
        #expect(movies.recommended.map(\.title) == ["La suivante"])
        #expect(movies.localHighlights.map(\.title) == ["La rencontre", "La première veille"])
        #expect(movies.trending.isEmpty)
        #expect(series.recommended.map(\.title) == ["Le phare"])
        #expect(withoutHistory.recommended.isEmpty)
        #expect(withoutHistory.localHighlights.map(\.title) == ["Moon Signal", "La suivante"])
    }

    @Test func localNamesFollowTheSelectedEditionsOfTheSameWork() async {
        let tmdbID = 44_798_001
        var english = Fixture.movie(Fixture.a, "signal-en", "Signals at Midnight", year: 2024, poster: "english.jpg", tmdbID: tmdbID)
        english.tags = ["EN"]
        var french = Fixture.movie(Fixture.b, "signal-fr", "Les signaux de minuit", year: 2024, poster: "french.jpg", tmdbID: tmdbID)
        french.tags = ["VF"]
        let catalog = await Fixture.build(
            [Fixture.source(Fixture.a), Fixture.source(Fixture.b)],
            [SourceCatalog(sourceID: Fixture.a, movies: [english]), SourceCatalog(sourceID: Fixture.b, movies: [french])]
        )
        let frenchShelf = await DiscoveryBuilder.local(
            for: .movie, in: catalog, recommendations: .empty, languages: [.french], profile: .init()
        )
        let englishShelf = await DiscoveryBuilder.local(
            for: .movie, in: catalog, recommendations: .empty, languages: [.english], profile: .init()
        )
        #expect(frenchShelf.localHighlights.map(\.title) == ["Les signaux de minuit"])
        #expect(englishShelf.localHighlights.map(\.title) == ["Signals at Midnight"])
        #expect(frenchShelf.localHighlights.map(\.id) == englishShelf.localHighlights.map(\.id))
    }

    @Test func trendingKeepsChartOrderWithoutSelectingOtherEditionsOrUnavailableTitles() async {
        var direct = Fixture.movie(Fixture.a, "direct", "Titre fournisseur", year: 2024, tmdbID: 101)
        direct.tags = ["VF"]
        var byName = Fixture.movie(Fixture.a, "localized", "A Remarkable Film", year: 2021)
        byName.tags = ["VF"]
        var differentID = Fixture.movie(Fixture.a, "conflicting", "La reprise", year: 2020, tmdbID: 999)
        differentID.tags = ["VF"]
        var onlyEnglish = Fixture.movie(Fixture.a, "english", "Only English", year: 2023, tmdbID: 103)
        onlyEnglish.tags = ["EN"]
        var wrongYear = Fixture.movie(Fixture.a, "year", "L’ancien titre", year: 1999)
        wrongYear.tags = ["VF"]
        var inactive = Fixture.movie(Fixture.b, "removed", "Un titre retiré", year: 2024, tmdbID: 888)
        inactive.tags = ["VF"]
        let catalog = await Fixture.build(
            [Fixture.source(Fixture.a), Fixture.source(Fixture.b, enabled: false)],
            [
                SourceCatalog(sourceID: Fixture.a, movies: [direct, byName, differentID, onlyEnglish, wrongYear]),
                SourceCatalog(sourceID: Fixture.b, movies: [inactive]),
            ]
        )
        let art = TMDBImageSet(backdropURL: Fixture.url("backdrop.jpg"))
        let chart: [TMDBTrend] = [
            .init(id: 888, title: "Un titre retiré", year: 2024, originalLanguage: .french),
            .init(id: 303, title: "Un film remarquable", originalTitle: "A Remarkable Film", year: 2021, originalLanguage: .english, images: art),
            .init(id: 103, title: "Only English", year: 2023, originalLanguage: .english),
            .init(id: 901, title: "La reprise", year: 2020),
            .init(id: 2, title: "L’ancien titre", year: 2020),
            .init(id: 101, title: "Titre officiel", year: 2024),
            .init(id: 101, title: "Deuxième graphie", year: 2024),
        ]
        let result = await DiscoveryBuilder.trending(
            chart, for: .movie, in: catalog, recommendations: .empty, languages: [.french]
        )
        #expect(result.map(\.title) == ["Un film remarquable", "Titre officiel"])
        #expect(result.first?.backdropURL == art.backdropURL)
        #expect(result.first?.primary?.id == byName.id)
        #expect(result.last?.primary?.id == direct.id)
    }
}
