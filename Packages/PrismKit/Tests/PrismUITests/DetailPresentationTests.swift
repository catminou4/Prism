import Foundation
import PrismCore
import PrismData
import Testing
@testable import PrismUI

struct DetailPresentationTests {
    @Test func ratingsPreferActualTMDBVotesAndFallBackToValidProviderValues() {
        let community = DetailRating.preferred(tmdb: 8.4, voteCount: 40, provider: [7])
        #expect(community?.value == 8.4)
        #expect(community?.source == .tmdb)

        let fallback = DetailRating.preferred(tmdb: 8.4, voteCount: 0, provider: [nil, 11, 7.2])
        #expect(fallback?.value == 7.2)
        #expect(fallback?.source == .provider)
        #expect(DetailRating.preferred(tmdb: .nan, provider: [.infinity, 0, -1]) == nil)
    }

    @Test func frenchSynopsisTakesPriorityAndSwedishIsOmitted() async {
        let swedish = "Paul Atreides förenar sig med Chani och Fremenfolket samtidigt som han är ute efter hämnd på konspiratörerna."
        let french = "Paul Atréides s’allie à Chani et aux Fremen pour venger ceux qui ont détruit sa famille."
        let english = "Paul Atreides joins Chani and the Fremen to avenge those who destroyed his family."
        #expect(await DetailPresentation.synopsis([swedish, english, french]) == french)
        #expect(await DetailPresentation.synopsis([swedish, english]) == english)
        #expect(await DetailPresentation.synopsis([swedish]) == nil)
    }

    @Test func relatedNamesUseTheSelectedEditionAndRejectMixedScripts() throws {
        let source = Source(name: "IPTV", kind: .xtream)
        let stream = try #require(URL(string: "https://example.invalid/movie.mp4"))
        let mixed = Movie(sourceID: source.id, nativeID: "mixed", title: "The Beekeeperزنبوردار", streamURL: stream, tags: ["VF"])
        let polish = Movie(sourceID: source.id, nativeID: "pl", title: "Pszczelarz", streamURL: stream, tags: ["PL"])
        let english = Movie(sourceID: source.id, nativeID: "en", title: "The Beekeeper", streamURL: stream, tags: ["EN"])
        let french = Movie(sourceID: source.id, nativeID: "fr", title: "Le Protecteur", streamURL: stream, tags: ["VF"])
        var title = MediaTitle(
            id: TitleID(rawValue: "title"), kind: .movie, title: mixed.title, year: 2024,
            variants: [.movie(mixed), .movie(polish), .movie(english)]
        )
        #expect(Recommendations.empty.localizedName(for: title, in: .empty, languages: [.french]) == nil)
        #expect(Recommendations.empty.localizedName(for: title, in: .empty, languages: [.english]) == english.title)
        title.variants.append(.movie(french))
        #expect(Recommendations.empty.localizedName(for: title, in: .empty, languages: [.french, .english]) == french.title)
    }

    @Test func alternateSynopsisChoosesOneFrenchEditionBeforeEnglish() throws {
        let source = Source(name: "IPTV", kind: .xtream)
        let stream = try #require(URL(string: "https://example.invalid/movie.mp4"))
        let options = ["SWE", "EN", "VFQ"].map { tag in
            TitleEdition(
                variant: .movie(Movie(sourceID: source.id, nativeID: tag, title: "Film", streamURL: stream, tags: [tag])),
                source: source
            )
        }
        #expect(DetailPresentation.alternateSynopsisEdition(in: options[...])?.edition.key == "VFQ")
        #expect(DetailPresentation.alternateSynopsisEdition(in: options.dropLast())?.edition.key == "EN")
        #expect(DetailPresentation.alternateSynopsisEdition(in: options.prefix(1)) == nil)
    }
}
