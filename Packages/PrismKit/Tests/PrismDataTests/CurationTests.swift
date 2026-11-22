import Foundation
import PrismCore
import Testing
@testable import PrismData

@Suite("Sélection éditoriale")
struct CurationTests {
    // MARK: Taxonomy

    @Test func providerCategoryNamesMapToGenresPlatformsAndFlags() {
        let netflix = CurationTaxonomy.traits(forCategory: "MULTI| Netflix Series 4K", currentYear: 2026)
        #expect(netflix.platforms.contains(.netflix))
        #expect(netflix.flags.contains(.uhd))
        #expect(netflix.flags.contains(.international))

        #expect(CurationTaxonomy.traits(forCategory: "Horreur/Epouvante", currentYear: 2026).genres == GenreSet(.horror))
        let fresh = CurationTaxonomy.traits(forCategory: "FR - Films Comédie 2026", currentYear: 2026)
        #expect(fresh.genres.contains(.comedy))
        #expect(fresh.flags.contains(.newRelease))
        #expect(CurationTaxonomy.traits(forCategory: "TOP IMDB", currentYear: 2026).flags.contains(.acclaimed))

        let regional = CurationTaxonomy.traits(forCategory: "HINDI MOVIES", currentYear: 2026)
        #expect(regional.flags.contains(.regional))
        #expect(!regional.flags.contains(.international))
        let kids = CurationTaxonomy.traits(forCategory: "Enfants", currentYear: 2026)
        #expect(kids.flags.contains(.kids))
        #expect(kids.genres.contains(.family))
        #expect(CurationTaxonomy.traits(forCategory: "CAM | Nouveautés", currentYear: 2026).flags.contains(.lowQualityRelease))
        // Word boundaries: "historyczne" is not "history", a TV channel is not a broadcaster platform.
        #expect(!CurationTaxonomy.traits(forCategory: "Filmy historyczne", currentYear: 2026).genres.contains(.history))
        #expect(CurationTaxonomy.traits(forCategory: "Maximum Overdrive", currentYear: 2026).platforms.isEmpty)
    }

    @Test func genreLabelsAndEpisodeLikeTitles() {
        let labels = CurationTaxonomy.genres(forLabel: "Science-Fiction & Fantastique")
        #expect(labels.contains(.scienceFiction))
        #expect(labels.contains(.fantasy))
        #expect(CurationTaxonomy.genres(forLabel: "دراما") == GenreSet(.drama))
        #expect(CurationTaxonomy.looksLikeEpisode("Kuruluş Osman 145. Bölüm"))
        #expect(CurationTaxonomy.looksLikeEpisode("Dune: Part Two - Official Trailer"))
        #expect(!CurationTaxonomy.looksLikeEpisode("Dune : Deuxième Partie"))
    }

    @Test func providerRatingsAreCalibrated() {
        #expect(CurationIndex.calibrated(10, kind: .movie, editions: 6) < 7, "a perfect 10 means a handful of votes")
        #expect(abs(CurationIndex.calibrated(9.2, kind: .movie, editions: 1) - 7.8) < 0.01)
        #expect(CurationIndex.calibrated(9.2, kind: .movie, editions: 8) == 9.2)
        #expect(abs(CurationIndex.calibrated(8, kind: .series, editions: 4) - 7.55) < 0.01, "rounded series ratings")
        #expect(CurationIndex.calibrated(7.8, kind: .movie, editions: 1) == 7.8)
    }

    // MARK: Feeds

    @Test func feedsKeepOnlyEligibleTitlesAndNeverRepeatThem() async throws {
        let library = await Library.make()
        #expect(library.index.isBuilt)
        #expect(!CurationIndex.empty.isBuilt)

        let feed = await library.feed(.movies)
        #expect(!feed.highlights.isEmpty)
        #expect(feed.highlights.first?.label == "À la une", "small lists have no chart to claim a number one")
        // A Top 10 is information and may repeat the hero; editorial shelves never repeat a title.
        let editorial = feed.highlights.map(\.title) + feed.shelves.filter { $0.style == .poster }.flatMap(\.items)
        #expect(Set(editorial.map(\.id)).count == editorial.count)
        let everything = editorial + feed.shelves.flatMap(\.items)
        #expect(everything.allSatisfy { $0.kind == .movie })
        #expect(everything.allSatisfy { !Library.ineligible.contains($0.title) })
        #expect(feed.shelves.contains { $0.title == "Le meilleur de Netflix" })
        #expect(feed.genres.contains { $0.genre == .thriller })

        let again = await library.feed(.movies)
        #expect(again.shelves.map(\.id) == feed.shelves.map(\.id))
        #expect(again.shelves.flatMap(\.items).map(\.id) == feed.shelves.flatMap(\.items).map(\.id), "stable within a day")
    }

    @Test func seeAllListsTheWholeFacetAndHonoursDismissals() async throws {
        let library = await Library.make()
        let query = CurationQuery(kind: .movie, facet: .genre(.thriller), title: "Thrillers")
        let thrillers = await library.collection(query)
        #expect(thrillers.count == Library.thrillers.count)
        #expect(Set(thrillers.map(\.title)) == Set(Library.thrillers))

        let dismissed = try #require(thrillers.first)
        let profile = CurationProfile(dismissed: [dismissed.id])
        #expect(await !library.collection(query, profile: profile).contains { $0.id == dismissed.id })
        let feed = await library.feed(.movies, profile: profile)
        let shown = feed.highlights.map(\.title) + feed.shelves.flatMap(\.items)
        #expect(!shown.contains { $0.id == dismissed.id })
    }

    @Test func historyPersonalisesTheFeed() async throws {
        let library = await Library.make()
        let comedy = try #require(library.catalog.movies.first { $0.title == Library.comedies[0] })
        let feed = await library.feed(.movies, profile: CurationProfile(watched: [comedy.id]))
        let personal = feed.shelves.filter { $0.id == "for-you" || $0.id == "because" }
        #expect(!personal.isEmpty)
        #expect(feed.shelves.first.map { personal.contains($0) } == true, "personal picks lead the page")
        for shelf in personal {
            #expect(shelf.items.allSatisfy { Library.comedies.contains($0.title) && $0.id != comedy.id })
        }
    }
}

/// A small but realistic provider list: Netflix thrillers, comedies, plus everything a curated page
/// must leave out (cam rips, regional imports, adult titles, titles without artwork).
private struct Library {
    static let thrillers = [
        "Velmora", "Karst Lane", "Nightglass", "Corvin Bay", "The Quiet Ledger", "Ashfall Point", "Morrow Street",
        "Silt Harbour", "The Tallis Code", "Greywater", "Hollow Signal", "Pale Meridian", "Under Cobalt",
        "The Brass Witness", "Northlight", "Driftmark", "Saltmarsh", "Ironvale", "The Last Ferryman", "Copperline",
    ]
    static let comedies = [
        "Les Vacances de Gaspard", "Un Mariage Presque Parfait", "Le Grand Bazar", "Tonton Rémi", "La Colocation",
        "Les Voisins du Dessus", "Pique-Nique Royal", "Le Retour de Mamie", "Bon Voyage Lucien", "Les Cousins",
        "Le Camping des Pins", "Maman a Raté",
    ]
    static let ineligible: Set<String> = ["Rogue Harbour Cam", "Dhoom Raja", "Sapna Ghar", "After Hours Club", "Blank Canvas"]

    let catalog: Catalog
    let recommendations: Recommendations
    let index: CurationIndex

    static func make() async -> Library {
        let source: SourceID = "src-a"
        let categories = [
            Fixture.category(source, .movie, "thr", "NETFLIX | Thriller"),
            Fixture.category(source, .movie, "com", "Comédies"),
            Fixture.category(source, .movie, "cam", "CAM | Nouveautés 2025"),
            Fixture.category(source, .movie, "hin", "Hindi Movies"),
            Fixture.category(source, .movie, "xxx", "Adultes", adult: true),
            Fixture.category(source, .series, "ser", "Séries Netflix"),
        ]
        var movies: [Movie] = []
        for (offset, name) in thrillers.enumerated() {
            movies.append(Fixture.movie(
                source, "t\(offset)", name, year: 2016 + offset % 10, category: "thr", poster: "t\(offset).jpg",
                backdrop: offset % 2 == 0 ? "tb\(offset).jpg" : nil, rating: 6.6 + Double(offset % 9) * 0.15
            ))
        }
        for (offset, name) in comedies.enumerated() {
            movies.append(Fixture.movie(
                source, "c\(offset)", name, year: 2012 + offset, category: "com", poster: "c\(offset).jpg",
                rating: 6.4 + Double(offset % 6) * 0.2
            ))
        }
        movies.append(Fixture.movie(source, "cam", "Rogue Harbour Cam", year: 2025, category: "cam", poster: "cam.jpg", rating: 8.6))
        movies.append(Fixture.movie(source, "hin1", "Dhoom Raja", year: 2024, category: "hin", poster: "h1.jpg", rating: 8.4))
        movies.append(Fixture.movie(source, "hin2", "Sapna Ghar", year: 2025, category: "hin", poster: "h2.jpg", rating: 8.2))
        movies.append(Fixture.movie(source, "adult", "After Hours Club", year: 2024, category: "xxx", poster: "x.jpg", rating: 8, adult: true))
        movies.append(Fixture.movie(source, "blank", "Blank Canvas", year: 2024, category: "thr", rating: 8.8))
        let series = (0..<3).map { offset in
            Fixture.series(source, "s\(offset)", ["Harrow Point", "Lumen Street", "The Cartographers"][offset],
                           year: 2023, category: "ser", poster: "s\(offset).jpg", rating: 7.6)
        }
        let catalog = await Fixture.build(
            [Fixture.source(source)],
            [SourceCatalog(sourceID: source, categories: categories, movies: movies, series: series)]
        )
        let recommendations = await RecommendationBuilder.build(for: catalog)
        let index = await CurationIndex.build(catalog: catalog, recommendations: recommendations, now: Fixture.reference)
        return Library(catalog: catalog, recommendations: recommendations, index: index)
    }

    func feed(_ scope: CurationScope, profile: CurationProfile = CurationProfile()) async -> CuratedFeed {
        await Curator.feed(
            scope: scope, catalog: catalog, index: index, recommendations: recommendations,
            languages: HomeAudioLanguage.defaults, profile: profile, now: Fixture.reference
        )
    }

    func collection(_ query: CurationQuery, profile: CurationProfile = CurationProfile()) async -> [MediaTitle] {
        await Curator.collection(
            query, catalog: catalog, index: index, recommendations: recommendations,
            languages: HomeAudioLanguage.defaults, profile: profile, now: Fixture.reference
        )
    }
}
