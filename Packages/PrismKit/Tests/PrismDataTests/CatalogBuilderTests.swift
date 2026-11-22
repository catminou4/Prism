import Foundation
import PrismCore
import Testing
@testable import PrismData

@Suite("CatalogBuilder grouping")
struct CatalogBuilderTests {
    typealias F = Fixture

    @Test func providerLanguageLabelsUseTheRawCategoryForEachEdition() async throws {
        let french = F.category(F.a, .movie, "10", "┃FR┃ Films - Nouveautés")
        let english = F.category(F.b, .movie, "10", "VOD | en-GB | New Releases")
        let frenchMovie = F.movie(F.a, "fr", "Inception", year: 2010, category: french.nativeID)
        let englishMovie = F.movie(F.b, "en", "Inception", year: 2010, category: english.id)
        let catalog = await F.build([F.source(F.a), F.source(F.b)], [
            SourceCatalog(sourceID: F.a, categories: [french], movies: [frenchMovie]),
            SourceCatalog(sourceID: F.b, categories: [english], movies: [englishMovie]),
        ])
        #expect(catalog.movies.count == 1)
        #expect(catalog.providerLanguages(for: .movie(frenchMovie)) == ["fr"])
        #expect(catalog.providerLanguages(for: .movie(englishMovie)) == ["en"])
    }

    @Test func categoriesDistinguishExplicitLanguagesFromIncidentalWords() {
        #expect(ProviderCategoryLanguage.codes(in: "Films en famille").isEmpty)
        #expect(ProviderCategoryLanguage.codes(in: "France • Documentaires").isEmpty)
        #expect(ProviderCategoryLanguage.codes(in: "FR | Films VOSTFR").isEmpty)
        #expect(ProviderCategoryLanguage.codes(in: "Audio EN | Sous-titres FR") == ["en"])
        #expect(ProviderCategoryLanguage.codes(in: "SÉRIES [EN / VF]") == ["en", "fr"])
        #expect(ProviderCategoryLanguage.codes(in: "|AR| Films récents") == ["ar"])
    }

    @Test func crossSourceMoviesAreGroupedWithPriorityOrder() async {
        let catalogs = [
            SourceCatalog(sourceID: F.b, movies: [F.movie(F.b, "1", "Inception", year: 2010, quality: .uhd)]),
            SourceCatalog(sourceID: F.a, movies: [F.movie(F.a, "9", "Inception", year: 2010, quality: .hd)]),
        ]
        let catalog = await F.build([F.source(F.a), F.source(F.b)], catalogs)
        #expect(catalog.movies.count == 1)
        let title = try! #require(catalog.movies.first)
        #expect(title.variants.map(\.sourceID) == [F.a, F.b])
        #expect(title.id == TitleID(kind: .movie, normalizedTitle: "inception", year: 2010))
        #expect(title.kind == .movie)
    }

    @Test(arguments: [true, false])
    func hiddenProviderCategoryKeepsOtherEditions(categoryListed: Bool) async throws {
        let hidden = F.category(F.a, .movie, "1", "Cinéma")
        let visible = F.category(F.b, .movie, "1", "Cinéma")
        let removed = F.movie(F.a, "1", "Inception", year: 2010, category: hidden.nativeID)
        let retained = F.movie(F.b, "1", "Inception", year: 2010, category: visible.id)
        let hiddenOnly = F.movie(F.a, "2", "Interstellar", year: 2014, category: hidden.id)
        let catalogs = [
            SourceCatalog(sourceID: F.a, categories: categoryListed ? [hidden] : [], movies: [removed, hiddenOnly]),
            SourceCatalog(sourceID: F.b, categories: [visible], movies: [retained]),
        ]
        let filtered = await CatalogBuilder.build(
            sources: [F.source(F.a), F.source(F.b)], catalogs: catalogs,
            options: .init(hiddenCategoryIDs: [hidden.id])
        )

        let title = try #require(filtered.movies.first)
        #expect(filtered.movies.count == 1)
        #expect(title.variants.map(\.id) == [retained.id])
        #expect(filtered.titleID(containing: removed.id) == nil)
        #expect(filtered.titleID(containing: hiddenOnly.id) == nil)
        #expect(filtered.category(hidden.id) == nil)
        #expect(filtered.movieCategories.first?.categoryIDs == [visible.id])
    }

    @Test func sameSourceQualityDuplicatesBecomeVariants() async {
        let movies = [
            F.movie(F.a, "1", "Avatar", year: 2009, quality: .hd, raw: "FR: Avatar (2009) HD"),
            F.movie(F.a, "2", "Avatar", year: 2009, quality: .uhd, raw: "4K | Avatar (2009) [MULTI] HDR"),
            F.movie(F.a, "3", "Avatar", year: 2009, quality: .sd, raw: "Avatar SD"),
        ]
        let catalog = await F.build([F.source(F.a)], [SourceCatalog(sourceID: F.a, movies: movies)])
        #expect(catalog.movies.count == 1)
        #expect(catalog.movies[0].variants.map(\.quality) == [.uhd, .hd, .sd])
        #expect(catalog.movies[0].bestQuality == .uhd)
    }

    @Test @MainActor func providerIDLinksTranslationsAndMigratesLibraryEntries() async throws {
        let french = F.movie(F.a, "1", "Premier Contact", year: 2016, tmdbID: 329865)
        let english = F.movie(F.b, "2", "Arrival", year: 2016, tmdbID: 329865)
        let otherOffer = F.movie(F.b, "3", "Arrival", year: 2016)
        let catalogs = [SourceCatalog(sourceID: F.a, movies: [french]), SourceCatalog(sourceID: F.b, movies: [english, otherOffer])]
        let catalog = await F.build([F.source(F.a), F.source(F.b)], catalogs)
        let canonical = try #require(catalog.movies.first)
        let frenchID = TitleID(kind: .movie, normalizedTitle: "premier contact", year: 2016)
        let englishID = TitleID(kind: .movie, normalizedTitle: "arrival", year: 2016)
        #expect(catalog.movies.count == 1)
        #expect(canonical.title == "Premier Contact")
        #expect(canonical.id == TitleID(kind: .movie, tmdbID: 329865))
        #expect(Set(canonical.variants.map(\.id)) == [french.id, english.id, otherOffer.id])
        #expect(catalog.title(frenchID)?.id == canonical.id)
        #expect(catalog.title(englishID)?.id == canonical.id)

        let search = await SearchIndex.build(from: catalog)
        #expect(search.search("arrival").movies.map(\.id) == [canonical.id])
        #expect(search.search("premier contact").movies.map(\.id) == [canonical.id])

        let library = LibraryStore.inMemory()
        library.addToWatchlist(englishID)
        library.addToWatchlist(frenchID)
        library.setPreferredVariant(english.id, for: englishID)
        library.recordPlayback(target: .title(englishID), contentID: english.id)
        library.updateProgress(PlaybackProgress(contentID: english.id, titleID: englishID, position: 300, duration: 7_000))
        library.reconcileTitles(in: catalog)
        #expect(library.watchlist == [canonical.id])
        #expect(library.preferredVariant(for: canonical.id) == english.id)
        #expect(library.history.map(\.target) == [.title(canonical.id)])
        #expect(library.continueWatching(in: catalog).map(\.title.id) == [canonical.id])

        let singleSource = await F.build([F.source(F.b)], catalogs)
        #expect(singleSource.title(canonical.id)?.id == englishID)
        library.reconcileTitles(in: singleSource)
        #expect(library.watchlist == [englishID])
    }

    @Test func conflictingProviderIDsDoNotAssignTheUnknownVariant() async throws {
        let local = F.series(F.a, "1", "Mirage", year: 2024, tmdbID: 100)
        let other = F.series(F.b, "1", "Mirage", year: 2024, tmdbID: 200)
        let unknown = F.series(F.b, "2", "Mirage", year: 2024)
        let catalog = await F.build([F.source(F.a), F.source(F.b)], [
            SourceCatalog(sourceID: F.a, series: [local]), SourceCatalog(sourceID: F.b, series: [other, unknown]),
        ])
        #expect(catalog.series.count == 3)
        #expect(catalog.series.allSatisfy { $0.variants.count == 1 })
        #expect(catalog.title(TitleID(kind: .series, normalizedTitle: "mirage", year: 2024)) == nil)
        #expect(catalog.titleID(containing: local.id) == TitleID(kind: .series, tmdbID: 100))
        #expect(catalog.titleID(containing: other.id) == TitleID(kind: .series, tmdbID: 200))
        #expect(catalog.titleID(containing: unknown.id) != nil)
    }

    @Test func yearDisambiguation() async {
        let movies = [
            F.movie(F.a, "1", "Dune", year: 1984),
            F.movie(F.a, "2", "Dune", year: 2021),
            F.movie(F.b, "3", "Dune"),
            F.movie(F.a, "4", "Heat", year: 1995),
            F.movie(F.b, "5", "HEAT"),
            F.movie(F.b, "6", "Solaris"),
            F.movie(F.a, "7", "Solaris"),
        ]
        let catalog = await F.build(
            [F.source(F.a), F.source(F.b)],
            [SourceCatalog(sourceID: F.a, movies: movies.filter { $0.sourceID == F.a }),
             SourceCatalog(sourceID: F.b, movies: movies.filter { $0.sourceID == F.b })]
        )
        let dunes = catalog.movies.filter { $0.title == "Dune" }
        #expect(dunes.count == 3, "1984 and 2021 stay apart; the undated one is ambiguous")
        #expect(Set(dunes.map(\.year)) == [1984, 2021, nil])
        let heat = catalog.movies.filter { $0.id.rawValue.hasPrefix("movie:heat:") }
        #expect(heat.count == 1)
        #expect(heat.first?.year == 1995)
        #expect(heat.first?.variants.count == 2, "undated variant joins the only dated group")
        #expect(heat.first?.title == "Heat", "natural casing preferred over ALL CAPS")
        let solaris = catalog.movies.filter { $0.id.rawValue.hasPrefix("movie:solaris:") }
        #expect(solaris.count == 1)
        #expect(solaris.first?.variants.map(\.sourceID) == [F.a, F.b])
    }

    @Test func seriesAreGroupedLikeMovies() async {
        let catalog = await F.build(
            [F.source(F.a), F.source(F.b)],
            [SourceCatalog(sourceID: F.a, series: [F.series(F.a, "1", "The Bear", year: 2022)]),
             SourceCatalog(sourceID: F.b, series: [F.series(F.b, "7", "The Bear", year: 2022, quality: .fhd), F.series(F.b, "8", "Dark")])]
        )
        #expect(catalog.series.count == 2)
        let bear = try! #require(catalog.series.first { $0.title == "The Bear" })
        #expect(bear.kind == .series)
        #expect(bear.variants.count == 2)
        #expect(bear.id.rawValue == "series:the bear:2022")
    }

    @Test func distinctChannelsAreNotMerged() async {
        let a = [
            F.channel(F.a, "1", "TF1", number: 1, quality: .hd, raw: "FR: TF1 HD"),
            F.channel(F.a, "2", "TF1 Séries Films", number: 20),
            F.channel(F.a, "3", "Canal+", number: 4),
            F.channel(F.a, "4", "Canal+ Sport", number: 40),
            F.channel(F.a, "5", "TF1", quality: .uhd, raw: "FR: TF1 4K"),
        ]
        let b = [F.channel(F.b, "1", "TF1", number: 101, epg: "TF1.fr", logo: "tf1.png")]
        let catalog = await F.build([F.source(F.a), F.source(F.b)], [SourceCatalog(sourceID: F.a, channels: a), SourceCatalog(sourceID: F.b, channels: b)])
        #expect(catalog.channels.count == 4)
        let tf1 = try! #require(catalog.channelGroup(TitleNormalizer.key("TF1")))
        #expect(tf1.variants.map(\.id.rawValue) == ["src-a:live:5", "src-a:live:1", "src-b:live:1"])
        #expect(tf1.number == 1)
        #expect(tf1.epgID == "TF1.fr")
        #expect(tf1.logoURL == F.url("tf1.png"))
        #expect(catalog.channels.map(\.name) == ["TF1", "Canal+", "TF1 Séries Films", "Canal+ Sport"])
    }

    @Test func variantOrderIsPriorityThenQualityThenShorterName() async {
        let a = [
            F.movie(F.a, "1", "The Matrix", year: 1999, quality: .hd, raw: "FR: The Matrix (1999) HD MULTI"),
            F.movie(F.a, "2", "The Matrix", year: 1999, quality: .hd, raw: "The Matrix HD"),
            F.movie(F.a, "3", "The Matrix", year: 1999, quality: .sd),
        ]
        let b = [F.movie(F.b, "1", "The Matrix", year: 1999, quality: .uhd)]
        let catalog = await F.build([F.source(F.a), F.source(F.b)], [SourceCatalog(sourceID: F.a, movies: a), SourceCatalog(sourceID: F.b, movies: b)])
        #expect(catalog.movies.count == 1)
        #expect(catalog.movies[0].variants.map(\.id.rawValue) == ["src-a:movie:2", "src-a:movie:1", "src-a:movie:3", "src-b:movie:1"])
    }

    @Test func disabledSourcesAreExcluded() async {
        let catalog = await F.build(
            [F.source(F.a), F.source(F.b, enabled: false)],
            [SourceCatalog(sourceID: F.a, movies: [F.movie(F.a, "1", "Alien", year: 1979)]),
             SourceCatalog(sourceID: F.b, movies: [F.movie(F.b, "1", "Alien", year: 1979), F.movie(F.b, "2", "Aliens", year: 1986)])]
        )
        #expect(catalog.movies.count == 1)
        #expect(catalog.movies[0].variants.count == 1)
        #expect(catalog.sources.map(\.id) == [F.a])
        #expect(catalog.source(F.b) == nil)
    }

    @Test func metadataIsMerged() async {
        let early = F.reference.addingTimeInterval(-86_400)
        let a = [F.movie(F.a, "1", "AMELIE", year: 2001, quality: .uhd, category: "c1", plot: "Court.", genres: ["Drame", "comédie"], rating: 7.1, added: early)]
        let b = [F.movie(F.b, "1", "Amélie", year: 2001, category: "c9", poster: "amelie.jpg", backdrop: "amelie-bg.jpg",
                         plot: "Amélie, une jeune serveuse de Montmartre, décide de changer la vie des autres.",
                         genres: ["drame", "Romance"], rating: 8.3, added: F.reference, adult: false)]
        let catalogs = [
            SourceCatalog(sourceID: F.a, categories: [F.category(F.a, .movie, "c1", "Comédies")], movies: a),
            SourceCatalog(sourceID: F.b, categories: [F.category(F.b, .movie, "c9", "Romance")], movies: b),
        ]
        let catalog = await F.build([F.source(F.a), F.source(F.b)], catalogs)
        let title = try! #require(catalog.movies.first)
        #expect(catalog.movies.count == 1)
        #expect(title.title == "Amélie")
        #expect(title.posterURL == F.url("amelie.jpg"))
        #expect(title.backdropURL == F.url("amelie-bg.jpg"))
        #expect(title.plot?.hasPrefix("Amélie, une jeune") == true)
        #expect(title.genres == ["Drame", "comédie", "Romance"])
        #expect(title.rating == 8.3)
        #expect(title.addedAt == F.reference)
        #expect(title.categoryIDs == [F.categoryID(F.a, .movie, "c1"), F.categoryID(F.b, .movie, "c9")])
        #expect(title.variants.first?.sourceID == F.a)
        #expect(!title.isAdult)
    }

    @Test func hideAdultDropsAdultItemsAndCategories() async {
        let categories = [
            F.category(F.a, .movie, "1", "Action"),
            F.category(F.a, .movie, "2", "Adultes", adult: true),
            F.category(F.a, .live, "3", "XXX"),
            F.category(F.a, .live, "4", "Info"),
        ]
        let catalogs = [SourceCatalog(
            sourceID: F.a, categories: categories,
            channels: [F.channel(F.a, "1", "Hot Channel", category: "3"), F.channel(F.a, "2", "France Info", category: "4")],
            movies: [
                F.movie(F.a, "1", "Die Hard", year: 1988, category: "1"),
                F.movie(F.a, "2", "Secret", year: 2020, category: "2"),
                F.movie(F.a, "3", "Flagged", year: 2020, category: "1", adult: true),
            ]
        )]
        let visible = await F.build([F.source(F.a)], catalogs, hideAdult: false)
        #expect(visible.movies.count == 3)
        #expect(visible.movies.filter(\.isAdult).count == 2)
        #expect(visible.movieCategories.contains { $0.isAdult })
        #expect(visible.channels.count == 2)

        let hidden = await F.build([F.source(F.a)], catalogs, hideAdult: true)
        #expect(hidden.movies.map(\.title) == ["Die Hard"])
        #expect(hidden.movieCategories.map(\.name) == ["Action"])
        #expect(hidden.liveCategories.map(\.name) == ["Info"])
        #expect(hidden.channels.map(\.name) == ["France Info"])
        #expect(hidden.category(F.categoryID(F.a, .movie, "2")) == nil)
    }

    @Test func categoriesAreMergedAcrossSources() async {
        let catalogs = [
            SourceCatalog(
                sourceID: F.a,
                categories: [F.category(F.a, .movie, "2", "Drame", sort: 1), F.category(F.a, .movie, "1", "Action", sort: 0), F.category(F.a, .movie, "3", "Vide", sort: 2)],
                movies: [F.movie(F.a, "1", "Heat", year: 1995, category: "1"), F.movie(F.a, "2", "Amour", year: 2012, category: "2")]
            ),
            SourceCatalog(
                sourceID: F.b,
                categories: [F.category(F.b, .movie, "10", "ACTION"), F.category(F.b, .movie, "11", "Horreur", sort: 1)],
                movies: [F.movie(F.b, "1", "Heat", year: 1995, category: F.categoryID(F.b, .movie, "10")), F.movie(F.b, "2", "Alien", year: 1979, category: "11")]
            ),
        ]
        let catalog = await F.build([F.source(F.a), F.source(F.b)], catalogs)
        #expect(catalog.movieCategories.map(\.name) == ["Action", "Drame", "Horreur"], "empty categories dropped, source order then appearance")
        #expect(catalog.movieCategories.map(\.sortIndex) == [0, 1, 2])
        let action = try! #require(catalog.movieCategories.first)
        #expect(action.id == "movie:action")
        #expect(action.categoryIDs == [F.categoryID(F.a, .movie, "1"), F.categoryID(F.b, .movie, "10")])
        #expect(action.itemCount == 1, "Heat from both sources counts once")
        #expect(catalog.titles(in: action).map(\.title) == ["Heat"])
        #expect(catalog.categoryGroup("movie:horreur")?.itemCount == 1)
        #expect(catalog.categoryGroup(containingCategory: F.categoryID(F.b, .movie, "10"))?.id == "movie:action")
    }

    @Test func sortingRules() async {
        let movies = [
            F.movie(F.a, "1", "Old", year: 1990, added: F.reference.addingTimeInterval(-1_000)),
            F.movie(F.a, "2", "New", year: 2024, added: F.reference),
            F.movie(F.a, "3", "Bravo", year: 2000),
            F.movie(F.a, "4", "Alpha", year: 2000),
        ]
        let channels = [
            F.channel(F.a, "1", "Zeta"), F.channel(F.a, "2", "Beta", number: 5), F.channel(F.a, "3", "Alpha"),
            F.channel(F.a, "4", "Gamma", number: 2),
        ]
        let catalog = await F.build([F.source(F.a)], [SourceCatalog(sourceID: F.a, channels: channels, movies: movies)])
        #expect(catalog.movies.map(\.title) == ["New", "Old", "Alpha", "Bravo"])
        #expect(catalog.channels.map(\.name) == ["Gamma", "Beta", "Alpha", "Zeta"])
        #expect(catalog.recentlyAdded(.movie, limit: 2).map(\.title) == ["New", "Old"])
    }

    @Test func providerLanguagesAreResolvedOncePerVariant() async throws {
        // The build-time cache must mirror `providerLanguages(for:)` exactly, including the
        // native→canonical category id fallback for older imports.
        let french = F.category(F.a, .movie, "10", "┃FR┃ Films - Nouveautés")
        let movie = F.movie(F.a, "fr", "Inception", year: 2010, category: french.nativeID)
        let uncategorised = F.movie(F.a, "x", "Titre", year: 2020)
        let catalog = await F.build(
            [F.source(F.a)],
            [SourceCatalog(sourceID: F.a, categories: [french], movies: [movie, uncategorised])]
        )
        let titles = Dictionary(uniqueKeysWithValues: catalog.movies.flatMap { title in
            title.variants.map { ($0.id, title) }
        })
        for title in catalog.movies {
            for variant in title.variants {
                #expect(catalog.indexes.providerLanguages[variant.id] == catalog.providerLanguages(for: variant))
            }
        }
        #expect(catalog.providerLanguages(for: .movie(movie)) == ["fr"])
        #expect(titles.count == 2)
    }

    @Test func emptyInputGivesEmptyCatalog() async {
        let catalog = await F.build([], [])
        #expect(catalog.isEmpty)
        #expect(Catalog.empty.isEmpty)
        #expect(Catalog.empty.featured(limit: 5).isEmpty)
    }
}

@Suite("Catalog lookups")
struct CatalogLookupTests {
    typealias F = Fixture

    static func makeCatalog() async -> Catalog {
        let catalogs = [
            SourceCatalog(
                sourceID: F.a,
                categories: [F.category(F.a, .movie, "sf", "Science-fiction"), F.category(F.a, .movie, "dr", "Drame"),
                             F.category(F.a, .series, "s", "Séries"), F.category(F.a, .live, "info", "Info")],
                channels: [F.channel(F.a, "c1", "France Info", number: 27, category: "info"), F.channel(F.a, "c2", "BFM TV", number: 15, category: "info")],
                movies: [
                    F.movie(F.a, "1", "Interstellar", year: 2014, quality: .uhd, category: "sf", backdrop: "i-bg.jpg", genres: ["Science-fiction"], rating: 8.7, added: F.reference),
                    F.movie(F.a, "2", "Arrival", year: 2016, category: "sf", poster: "a.jpg", plot: String(repeating: "Une linguiste est recrutée. ", count: 3), genres: ["Science-fiction", "Drame"], rating: 7.9, added: F.reference.addingTimeInterval(-10)),
                    F.movie(F.a, "3", "Gravity", year: 2013, category: "sf", genres: ["Science-fiction"], rating: 7.7, added: F.reference.addingTimeInterval(-20)),
                    F.movie(F.a, "4", "Amour", year: 2012, category: "dr", genres: ["Drame"], rating: 7.9, added: F.reference.addingTimeInterval(-30)),
                ],
                series: [
                    F.series(F.a, "s1", "Dark", year: 2017, category: "s", poster: "dark.jpg", plot: String(repeating: "Une disparition à Winden. ", count: 3), rating: 8.8, added: F.reference),
                    F.series(F.a, "s2", "Severance", year: 2022, category: "s", rating: 8.7, added: F.reference.addingTimeInterval(-5)),
                ]
            ),
            SourceCatalog(sourceID: F.b, movies: [F.movie(F.b, "1", "Interstellar", year: 2014, quality: .hd)]),
        ]
        return await F.build([F.source(F.a), F.source(F.b)], catalogs)
    }

    @Test func idLookups() async throws {
        let catalog = await Self.makeCatalog()
        let interstellar = try #require(catalog.movies.first { $0.title == "Interstellar" })
        #expect(catalog.title(interstellar.id)?.title == "Interstellar")
        let bVariant = ContentID(source: F.b, kind: .movie, nativeID: "1")
        #expect(catalog.titleID(containing: bVariant) == interstellar.id)
        #expect(catalog.movie(bVariant)?.quality == .hd)
        #expect(catalog.movie(ContentID(source: F.b, kind: .movie, nativeID: "404")) == nil)
        let dark = ContentID(source: F.a, kind: .series, nativeID: "s1")
        #expect(catalog.series(dark)?.title == "Dark")
        #expect(catalog.titleID(containing: dark) == TitleID(kind: .series, normalizedTitle: "dark", year: 2017))
        let info = ContentID(source: F.a, kind: .live, nativeID: "c1")
        #expect(catalog.channel(info)?.name == "France Info")
        #expect(catalog.channelGroupID(containing: info) == "france info")
        #expect(catalog.channelGroup("france info")?.number == 27)
        #expect(catalog.category(F.categoryID(F.a, .movie, "sf"))?.name == "Science-fiction")
        #expect(catalog.source(F.a)?.id == F.a)
        let infoGroup = try #require(catalog.liveCategories.first)
        #expect(catalog.channels(in: infoGroup).map(\.name) == ["BFM TV", "France Info"])
        #expect(catalog.titles(in: infoGroup).isEmpty)
        let sf = try #require(catalog.categoryGroup("movie:science fiction"))
        #expect(catalog.titles(in: sf).map(\.title) == ["Interstellar", "Arrival", "Gravity"])
    }

    @Test func featuredIsDeterministicAndPrefersArtwork() async {
        let first = await Self.makeCatalog()
        let second = await Self.makeCatalog()
        let featured = first.featured(limit: 4)
        #expect(featured.map(\.id) == second.featured(limit: 4).map(\.id))
        #expect(featured.first?.title == "Interstellar", "backdrop wins")
        #expect(featured.dropFirst().first?.kind == .series, "movies and series alternate")
        #expect(Set(featured.map(\.kind)) == [.movie, .series])
    }

    @Test func relatedExcludesItselfAndPrefersSharedCategories() async throws {
        let catalog = await Self.makeCatalog()
        let arrival = try #require(catalog.movies.first { $0.title == "Arrival" })
        let related = catalog.related(to: arrival, limit: 10)
        #expect(!related.contains { $0.id == arrival.id })
        #expect(related.first.map { ["Interstellar", "Gravity"].contains($0.title) } == true)
        #expect(related.map(\.id) == catalog.related(to: arrival, limit: 10).map(\.id))
    }

    @Test func topRatedOrdersByRating() async {
        let catalog = await Self.makeCatalog()
        #expect(catalog.topRated(.movie, limit: 2).map(\.title) == ["Interstellar", "Arrival"])
        #expect(catalog.topRated(.series, limit: 5).map(\.title) == ["Dark", "Severance"])
        #expect(catalog.topRated(.live, limit: 5).isEmpty)
    }
}
