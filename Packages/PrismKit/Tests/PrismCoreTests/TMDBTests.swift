import Foundation
import Testing
@testable import PrismCore

@Suite("TMDB")
struct TMDBTests {
    @Test func credentialKinds() {
        #expect(TMDBClient.auth(for: "0123456789abcdef0123456789ABCDEF") == .apiKey("0123456789abcdef0123456789ABCDEF"))
        #expect(TMDBClient.auth(for: "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJ4In0.sig") == .bearer("eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJ4In0.sig"))
        #expect(TMDBClient.auth(for: "Bearer eyJ.abc.def") == .bearer("eyJ.abc.def"))
        #expect(TMDBClient.auth(for: "  ") == nil)
    }

    @Test func imageURLs() {
        #expect(TMDBClient.imageURL(path: "/abc.jpg", size: "w500")?.absoluteString == "https://image.tmdb.org/t/p/w500/abc.jpg")
        #expect(TMDBClient.imageURL(path: "abc.jpg", size: "original")?.absoluteString == "https://image.tmdb.org/t/p/original/abc.jpg")
        #expect(TMDBClient.imageURL(path: nil, size: "w500") == nil)
        #expect(TMDBClient.imageURL(path: "", size: "w500") == nil)
    }

    @Test func searchAndBestMatch() throws {
        let hits = try TMDBClient.decodeSearch(try Fixture.data("tmdb_search_movie", "json"))
        #expect(hits.map(\.id) == [76600, 19995])
        #expect(hits[1].year == 2009)
        #expect(TMDBClient.bestMatch(hits, title: "Avatar", year: 2009)?.id == 19995)
        #expect(TMDBClient.bestMatch(hits, title: "Avatar", year: nil)?.id == 19995)
        #expect(TMDBClient.bestMatch(hits, title: "Avatar la voie de l'eau", year: 2022)?.id == 76600)
        #expect(TMDBClient.bestMatch([], title: "x", year: nil) == nil)
    }

    @Test func searchRejectsUnrelatedResultsAndWrongRemakes() {
        let hits = [
            TMDBSearchHit(id: 1, title: "Un autre film", originalTitle: nil, year: 2020, popularity: 100),
            TMDBSearchHit(id: 2, title: "Dune", originalTitle: nil, year: 1984, popularity: 20),
        ]
        #expect(TMDBClient.bestMatch(hits, title: "Film introuvable", year: 2020) == nil)
        #expect(TMDBClient.bestMatch(hits, title: "Dune", year: 2021) == nil)
        #expect(TMDBClient.bestMatch(hits, title: "Dune", year: 1984)?.id == 2)
    }

    @Test func posterFallsBackToLocalizedImage() throws {
        let data = Data(#"{"id":1,"title":"Film","images":{"posters":[{"iso_639_1":"en","file_path":"/en.jpg"},{"iso_639_1":"fr","file_path":"/fr.jpg"}]}}"#.utf8)
        let french = try TMDBClient.decodeMetadata(data, kind: .movie)
        let english = try TMDBClient.decodeMetadata(data, kind: .movie, languageCode: "en")
        #expect(french.images.posterURL?.lastPathComponent == "fr.jpg")
        #expect(english.images.posterURL?.lastPathComponent == "en.jpg")
    }

    @Test func movieDetails() throws {
        let metadata = try TMDBClient.decodeMetadata(try Fixture.data("tmdb_movie_details", "json"), kind: .movie, region: "FR")
        #expect(metadata.tmdbID == 19995)
        #expect(metadata.kind == .movie)
        #expect(metadata.title == "Avatar")
        #expect(metadata.overview?.hasPrefix("Malgré sa paralysie") == true)
        #expect(metadata.images.logoURL?.absoluteString == "https://image.tmdb.org/t/p/w500/frLogo.png")
        #expect(metadata.images.backdropURL?.absoluteString == "https://image.tmdb.org/t/p/original/textlessBackdrop.jpg")
        #expect(metadata.images.posterURL?.absoluteString == "https://image.tmdb.org/t/p/w780/3npygfmEhqnmNTmDWhHLz1LPcbA.jpg")
        #expect(metadata.cast.map(\.name) == ["Sam Worthington", "Zoe Saldaña", "Sigourney Weaver"])
        #expect(metadata.cast[0].role == "Jake Sully")
        #expect(metadata.cast[0].profileURL?.absoluteString == "https://image.tmdb.org/t/p/w185/mflBcox36s9ZPbsZPVOuhf6axaJ.jpg")
        #expect(metadata.cast[2].profileURL == nil)
        #expect(metadata.directors == ["James Cameron"])
        #expect(metadata.genres == ["Action", "Aventure", "Fantastique", "Science-Fiction"])
        #expect(metadata.runtimeMinutes == 162)
        #expect(metadata.releaseYear == 2009)
        #expect(metadata.voteAverage == 7.588)
        #expect(metadata.trailerURL?.absoluteString == "https://www.youtube.com/watch?v=frTrailerKey")
        #expect(metadata.certification == "TP")
        let us = try TMDBClient.decodeMetadata(try Fixture.data("tmdb_movie_details", "json"), kind: .movie, region: "US")
        #expect(us.certification == "PG-13")
    }

    @Test func tvDetails() throws {
        let metadata = try TMDBClient.decodeMetadata(try Fixture.data("tmdb_tv_details", "json"), kind: .series, region: "FR")
        #expect(metadata.kind == .series)
        #expect(metadata.title == "The Bear")
        #expect(metadata.directors == ["Christopher Storer"])
        #expect(metadata.runtimeMinutes == 34)
        #expect(metadata.releaseYear == 2022)
        #expect(metadata.certification == "16")
        #expect(metadata.images.logoURL?.absoluteString == "https://image.tmdb.org/t/p/w500/tvNullLogo.png")
        #expect(metadata.images.backdropURL?.absoluteString == "https://image.tmdb.org/t/p/original/tvEnBackdrop.jpg")
        #expect(metadata.trailerURL?.absoluteString == "https://www.youtube.com/watch?v=y-cqqAJIXhs")
    }

    @Test func seasonEpisodes() throws {
        let episodes = try TMDBClient.decodeSeason(try Fixture.data("tmdb_season", "json"))
        #expect(episodes.map(\.number) == [1, 2])
        #expect(episodes[0].title == "System")
        #expect(episodes[0].runtimeMinutes == 28)
        #expect(episodes[0].voteAverage == 8)
        #expect(episodes[0].voteCount == 126)
        #expect(episodes[0].stillURL?.absoluteString == "https://image.tmdb.org/t/p/w500/e1.jpg")
        #expect(episodes[1].overview == nil)
        #expect(episodes[1].voteAverage == nil)
        #expect(episodes[1].voteCount == nil)
        #expect(episodes[1].stillURL == nil)
        #expect(episodes[1].season == 1)
    }

    @Test func invalidPayload() {
        #expect(throws: TMDBError.self) { try TMDBClient.decodeMetadata(Data("[]".utf8), kind: .movie) }
        #expect(throws: TMDBError.self) { try TMDBClient.decodeSearch(Data("oops".utf8)) }
    }

    @Test func weeklyTrendsPreserveProviderRankingAndMediaType() async throws {
        let host = "api.themoviedb.org"
        let tvPath = "/3/trending/tv/week"
        let moviePath = "/3/trending/movie/week"
        let tv = """
            {"results":[
                {"id":7,"name":"La série","original_name":"The Show","first_air_date":"2024-06-01",
                 "original_language":"en","backdrop_path":"/wide.jpg"},
                {"id":2,"name":"Autre","original_language":"fr","poster_path":"/cover.jpg"},
                {"id":7,"name":"Doublon"},
                {"id":4,"name":"Adulte","adult":true}
            ]}
            """
        let movies = """
            {"results":[{"id":9,"title":"Le film","original_title":"Der Film","release_date":"2021-03-25",
                         "original_language":"de"}]}
            """
        StubURLProtocol.register(host: host, path: tvPath, body: Data(tv.utf8))
        StubURLProtocol.register(host: host, path: moviePath, body: Data(movies.utf8))
        let client = TMDBClient(credential: "example-token", session: StubURLProtocol.session())
        let tvChart = try await client.weeklyTrending(for: .series)
        let filmChart = try await client.weeklyTrending(for: .movie)
        #expect(tvChart.map(\.id) == [7, 2])
        #expect(tvChart.first?.originalLanguage == .english)
        #expect(tvChart.first?.year == 2024)
        #expect(tvChart.first?.images.backdropURL?.absoluteString == "https://image.tmdb.org/t/p/w1280/wide.jpg")
        #expect(filmChart.first?.id == 9)
        #expect(filmChart.first?.originalLanguage == nil)
        #expect(filmChart.first?.year == 2021)
        let requests = StubURLProtocol.recordedRequests(host: host).filter { request in
            request.url?.path().hasPrefix("/3/trending/") == true
        }
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.url?.query() == "language=fr-FR" })
    }

    @Test func endToEndWithStubbedSession() async throws {
        let host = "api.themoviedb.org"
        StubURLProtocol.register(host: host, path: "/3/search/movie", body: try Fixture.data("tmdb_search_movie", "json"))
        StubURLProtocol.register(host: host, path: "/3/movie/19995", body: try Fixture.data("tmdb_movie_details", "json"))
        StubURLProtocol.register(host: host, path: "/3/tv/136315/season/1", body: try Fixture.data("tmdb_season", "json"))
        StubURLProtocol.register(host: host, path: "/3/movie/404404", status: 404, body: Data())
        let client = TMDBClient(credential: "0123456789abcdef0123456789abcdef", session: StubURLProtocol.session())
        let metadata = try #require(try await client.metadata(kind: .movie, title: "Avatar", year: 2009, tmdbID: nil))
        #expect(metadata.tmdbID == 19995)
        #expect(try await client.metadata(kind: .movie, title: "Ignored", year: nil, tmdbID: 404404) == nil)
        #expect(try await client.metadata(kind: .live, title: "TF1", year: nil, tmdbID: nil) == nil)
        #expect(try await client.seasonEpisodes(tmdbID: 136315, season: 1).count == 2)

        let urls = StubURLProtocol.recordedRequests(host: host).compactMap(\.url?.absoluteString)
        let search = try #require(urls.first { $0.contains("/3/search/movie") })
        #expect(search.contains("query=Avatar"))
        #expect(search.contains("year=2009"))
        #expect(search.contains("api_key=0123456789abcdef0123456789abcdef"))
        let details = try #require(urls.first { $0.contains("/3/movie/19995") })
        #expect(details.contains("append_to_response=images%2Ccredits%2Cvideos%2Crelease_dates"))
        #expect(details.contains("include_image_language=fr%2Cen%2Cnull"))
    }

    @Test func bearerTokenIsSentAsHeader() async throws {
        let host = "api.themoviedb.org"
        StubURLProtocol.register(host: host, path: "/3/tv/136315", body: try Fixture.data("tmdb_tv_details", "json"))
        let client = TMDBClient(credential: "eyJhbGciOiJIUzI1NiJ9.payload.signature", session: StubURLProtocol.session())
        let metadata = try await client.metadata(kind: .series, title: "The Bear", year: nil, tmdbID: 136315)
        #expect(metadata?.title == "The Bear")
        let request = try #require(StubURLProtocol.recordedRequests(host: host).first { $0.url?.path() == "/3/tv/136315" })
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer eyJhbGciOiJIUzI1NiJ9.payload.signature")
        #expect(request.url?.query()?.contains("api_key") == false)
    }

    @Test func missingCredential() async {
        let client = TMDBClient(credential: "", session: StubURLProtocol.session())
        await #expect(throws: TMDBError.invalidCredential) { try await client.metadata(kind: .movie, title: "Avatar", year: nil, tmdbID: nil) }
    }
}
