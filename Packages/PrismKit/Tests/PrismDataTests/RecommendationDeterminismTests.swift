import PrismCore
import Testing
@testable import PrismData

@Suite("Déterminisme des recommandations éditoriales")
struct RecommendationDeterminismTests {
    private static let polish = "Zainspirowany przygodami legendarnego złodzieja, Assane poszukuje prawdy o losie swojego ojca, a każda wskazówka odsłania kolejny rodzinny sekret ukrywany od lat."
    private static let turkish = "Efsanevi bir hırsızın maceralarından ilham alan Assane, babasının tutuklanmasının ardındaki gerçeği ararken ailesinin geçmişindeki sırları da ortaya çıkarmak zorunda kalır."
    private static let english = "Inspired by the adventures of a legendary thief, Assane searches for the truth behind his father's arrest while every clue reveals another long hidden family secret."
    private static let french = "Inspiré par les aventures d’Arsène Lupin, Assane recherche la vérité sur l’arrestation de son père tandis que chaque indice révèle un secret de famille longtemps caché."
    private static let spanish = "Inspirado por las aventuras de un ladrón legendario, Assane busca la verdad sobre la detención de su padre mientras cada pista revela otro secreto familiar escondido durante años."

    @Test func parallelEditorialMatchesSerialOracleExactly() async throws {
        let catalog = try await Self.richEditorialCatalog()
        let oracle = Self.serialEditorialOracle(for: catalog)

        // The fixture must really exercise cross-entry ownership: Monte-Cristo is the first
        // editorial occurrence of the grouped title also reachable as Dune in the American shelf.
        let countID = TitleID(kind: .movie, normalizedTitle: TitleNormalizer.key("Le Comte de Monte-Cristo"), year: 2024)
        let shared = try #require(catalog.title(countID))
        let sharedCopy = try #require(oracle.editorialCopy[shared.id])
        #expect(sharedCopy.title == "Le Comte de Monte-Cristo")
        #expect(sharedCopy.originalLanguage == .french)

        // Repeated runs vary child-task scheduling; output must remain byte-for-byte stable.
        for _ in 0..<24 {
            let actual = await RecommendationBuilder.buildEditorial(for: catalog)
            try Self.expectSameRecommendations(actual, oracle)
        }
    }

    /// Cross-source TMDB reconciliation makes one grouped title visible to both the Monte-Cristo
    /// and Dune editorial entries. That duplicate is required to exercise first-wins copy ownership.
    private static func richEditorialCatalog() async throws -> Catalog {
        let sharedTMDB = 991_001
        var countPolish = Fixture.movie(
            Fixture.a, "count-pl", "Le Comte de Monte-Cristo", year: 2024, quality: .uhd,
            poster: "count-p.jpg", backdrop: "count-b.jpg", plot: polish + " " + polish, rating: 8.8, tmdbID: sharedTMDB
        )
        countPolish.tags = ["PL"]
        var duneEnglish = Fixture.movie(
            Fixture.b, "dune-en", "Dune: Part Two", year: 2024, quality: .fhd,
            poster: "dune-p.jpg", backdrop: "dune-b.jpg", plot: english, rating: 8.7, tmdbID: sharedTMDB
        )
        duneEnglish.tags = ["EN"]
        var countFrench = Fixture.movie(
            Fixture.c, "count-fr", "The Count of Monte Cristo", year: 2024, quality: .hd,
            poster: "count-fr-p.jpg", plot: french, rating: 8.9, tmdbID: sharedTMDB
        )
        countFrench.tags = ["VF"]

        var anatomyCanonical = Fixture.movie(
            Fixture.a, "anatomy-fr", "Anatomie d’une chute", year: 2023, quality: .uhd,
            poster: "anatomy-p.jpg", backdrop: "anatomy-b.jpg", plot: polish, rating: 8.4, tmdbID: 9201
        )
        anatomyCanonical.tags = ["VF"]
        var anatomyAlias = Fixture.movie(
            Fixture.b, "anatomy-en", "Anatomy of a Fall", year: 2023, quality: .fhd,
            poster: "fall-p.jpg", plot: english, rating: 8.3, tmdbID: 9202
        )
        anatomyAlias.tags = ["EN"]

        var portraitTurkish = Fixture.movie(
            Fixture.a, "portrait-tr", "Portrait de la jeune fille en feu", year: 2019, quality: .uhd,
            poster: "portrait-p.jpg", backdrop: "portrait-b.jpg", plot: turkish + " " + turkish, rating: 8.2
        )
        portraitTurkish.tags = ["TR"]
        var portraitFrench = Fixture.movie(
            Fixture.b, "portrait-fr", "Portrait of a Lady on Fire", year: 2019, quality: .fhd,
            poster: "portrait-fr-p.jpg", plot: french, rating: 8.1
        )
        portraitFrench.tags = ["VF"]

        var lupinTurkish = Fixture.series(
            Fixture.a, "lupin-tr", "Lupin", year: 2021, quality: .uhd,
            poster: "lupin-p.jpg", plot: turkish + " " + turkish, rating: 8.0
        )
        lupinTurkish.tags = ["TR"]
        var lupinSpanish = Fixture.series(
            Fixture.b, "lupin-es", "Lupin", year: 2021, quality: .fhd,
            poster: "lupin-es-p.jpg", plot: spanish, rating: 8.0
        )
        lupinSpanish.tags = ["ES"]
        var lupinFrench = Fixture.series(
            Fixture.c, "lupin-fr", "Lupin", year: 2021, quality: .hd,
            poster: "lupin-fr-p.jpg", plot: french, rating: 8.0
        )
        lupinFrench.tags = ["VF"]

        var severance = Fixture.series(
            Fixture.a, "severance", "Severance", year: 2022, quality: .uhd,
            poster: "severance-p.jpg", plot: english + " " + english, rating: 8.7
        )
        severance.tags = ["EN"]
        var revenants = Fixture.series(
            Fixture.b, "revenants", "Les Revenants", year: 2012, quality: .fhd,
            poster: "revenants-p.jpg", plot: french, rating: 8.1
        )
        revenants.tags = ["VF"]

        let catalog = await Fixture.build(
            [Fixture.source(Fixture.a), Fixture.source(Fixture.b), Fixture.source(Fixture.c)],
            [
                SourceCatalog(
                    sourceID: Fixture.a,
                    movies: [countPolish, anatomyCanonical, portraitTurkish],
                    series: [lupinTurkish, severance]
                ),
                SourceCatalog(
                    sourceID: Fixture.b,
                    movies: [duneEnglish, anatomyAlias, portraitFrench],
                    series: [lupinSpanish, revenants]
                ),
                SourceCatalog(sourceID: Fixture.c, movies: [countFrench], series: [lupinFrench]),
            ]
        )

        // Sanity-check the fixture shape rather than relying on incidental coverage.
        let countID = TitleID(kind: .movie, normalizedTitle: TitleNormalizer.key("Le Comte de Monte-Cristo"), year: 2024)
        let duneID = TitleID(kind: .movie, normalizedTitle: TitleNormalizer.key("Dune: Part Two"), year: 2024)
        let shared = try #require(catalog.title(countID))
        #expect(catalog.title(duneID)?.id == shared.id)

        let anatomyID = TitleID(kind: .movie, normalizedTitle: TitleNormalizer.key("Anatomie d’une chute"), year: 2023)
        let fallID = TitleID(kind: .movie, normalizedTitle: TitleNormalizer.key("Anatomy of a Fall"), year: 2023)
        #expect(catalog.title(anatomyID) != nil)
        #expect(catalog.title(fallID) != nil)
        #expect(catalog.title(anatomyID)?.id != catalog.title(fallID)?.id)
        return catalog
    }

    /// Serial oracle: the pre-parallelization implementation, copied unchanged except for the
    /// private helper/type names needed by the test target.
    private static func serialEditorialOracle(for catalog: Catalog) -> Recommendations {
        if !catalog.sources.isEmpty, catalog.sources.allSatisfy(DemoContent.isDemo) {
            let titles = catalog.featured(limit: 7)
            let selection = RecommendationSelection(highlights: titles, french: [], american: [], discoveries: [], wellRated: titles)
            return Recommendations(selections: [
                HomeAudioLanguage.defaults: selection, [.french]: selection, [.english]: selection,
            ], editorialCopy: [:])
        }
        var editorialCopy: [TitleID: Recommendations.EditorialCopy] = [:]
        let matchStart = ContinuousClock.now
        var candidates = 0
        let editorial = EditorialSelection.shelves.map { shelf in
            shelf.map { entry in
                entry.matches(in: catalog).map { title in
                    candidates += 1
                    let copy = editorialCopy[title.id] ?? .init(
                        title: entry.name, plot: oracleHomePlot(for: title), originalLanguage: entry.originalLanguage
                    )
                    editorialCopy[title.id] = copy
                    var item = title
                    item.title = copy.title
                    item.plot = copy.plot
                    return OracleCandidate(
                        item: item,
                        audio: RecommendationBuilder.availableAudio(for: title, original: entry.originalLanguage, catalog: catalog)
                    )
                }
            }
        }
        BuildProfile.mark("editorial matches+candidates (\(candidates))", since: matchStart)

        let choices: [Set<HomeAudioLanguage>] = [HomeAudioLanguage.defaults, [.french], [.english]]
        let curatedChoices = choices.map { languages in
            var seen: Set<TitleID> = []
            return editorial.map { shelf in
                var items: [MediaTitle] = []
                for versions in shelf {
                    guard let match = versions.first(where: { !$0.audio.isDisjoint(with: languages) && !seen.contains($0.item.id) })
                    else { continue }
                    seen.insert(match.item.id)
                    items.append(match.item)
                    if items.count == 20 { break }
                }
                return items
            }
        }

        let assemblyStart = ContinuousClock.now
        var selections: [Set<HomeAudioLanguage>: RecommendationSelection] = [:]
        for (languages, curated) in zip(choices, curatedChoices) {
            let spotlight = oracleInterleaved(curated.map(oracleArtworkFirst), limit: 7)
            selections[languages] = RecommendationSelection(
                highlights: oracleArtworkFirst(spotlight),
                french: curated[0], american: curated[1], discoveries: curated[2], wellRated: []
            )
        }
        BuildProfile.mark("editorial selection assembly", since: assemblyStart)
        return Recommendations(selections: selections, editorialCopy: editorialCopy)
    }

    private struct OracleCandidate {
        let item: MediaTitle
        let audio: Set<HomeAudioLanguage>
    }

    private static func oracleHomePlot(for title: MediaTitle) -> String? {
        ProviderSynopsis.preferredFrenchOrEnglish(
            from: [title.plot] + title.variants.prefix(12).map { $0.movie?.plot ?? $0.series?.plot }
        )
    }

    private static func oracleArtworkFirst(_ titles: [MediaTitle]) -> [MediaTitle] {
        titles.filter { $0.$backdropURL != nil }
            + titles.filter { $0.$backdropURL == nil && $0.$posterURL != nil }
            + titles.filter { $0.$backdropURL == nil && $0.$posterURL == nil }
    }

    private static func oracleInterleaved(_ shelves: [[MediaTitle]], limit: Int) -> [MediaTitle] {
        var result: [MediaTitle] = []
        for index in 0..<(shelves.map(\.count).max() ?? 0) {
            for shelf in shelves where index < shelf.count {
                result.append(shelf[index])
                if result.count == limit { return result }
            }
        }
        return result
    }

    private static func expectSameRecommendations(_ actual: Recommendations, _ expected: Recommendations) throws {
        #expect(Set(actual.selections.keys) == Set(expected.selections.keys))
        for languages in expected.selections.keys {
            let expectedSelection = try #require(expected.selections[languages])
            let actualSelection = try #require(actual.selections[languages])
            #expect(actualSelection.highlights == expectedSelection.highlights)
            #expect(actualSelection.french == expectedSelection.french)
            #expect(actualSelection.american == expectedSelection.american)
            #expect(actualSelection.discoveries == expectedSelection.discoveries)
            #expect(actualSelection.wellRated == expectedSelection.wellRated)
        }

        #expect(Set(actual.editorialCopy.keys) == Set(expected.editorialCopy.keys))
        for id in expected.editorialCopy.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let expectedCopy = try #require(expected.editorialCopy[id])
            let actualCopy = try #require(actual.editorialCopy[id])
            #expect(actualCopy.title == expectedCopy.title)
            #expect(actualCopy.plot == expectedCopy.plot)
            #expect(actualCopy.originalLanguage == expectedCopy.originalLanguage)
        }
    }
}
