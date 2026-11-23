import Foundation
import Testing
@testable import PrismData

struct SeriesCastRepositoryTests {
    @Test func exactTitleAndYearReturnsAttributedCastAndCachesIt() async throws {
        let host = StubURLProtocol.uniqueHost("tvmaze-cast")
        StubURLProtocol.register(host: host) { request in
            switch request.url?.path {
            case "/search/shows":
                guard request.queryValue("q") == "Lupin",
                      request.value(forHTTPHeaderField: "Authorization") == nil,
                      request.value(forHTTPHeaderField: "Cookie") == nil
                else { return .text("Bad query", status: 400) }
                return .json("""
                    [
                      {"show":{"id":50,"name":"Lupin","premiered":"1971-10-24","url":"https://www.tvmaze.com/shows/50/lupin"}},
                      {"show":{"id":51,"name":"Lupin","premiered":"2021-01-08","url":"https://www.tvmaze.com/shows/51/lupin"}},
                      {"show":{"id":52,"name":"Lupin Returns","premiered":"2021-08-01","url":"https://www.tvmaze.com/shows/52/lupin-returns"}}
                    ]
                    """)
            case "/shows/51/cast":
                return .json("""
                    [
                      {"person":{"id":4,"name":"Omar Sy","image":{"medium":"https://static.tvmaze.com/omar.jpg"}},
                       "character":{"name":"Assane Diop","image":null}},
                      {"person":{"id":4,"name":"Omar Sy","image":null},"character":{"name":"Other character"}},
                      {"person":{"id":6,"name":"Ludivine Sagnier","image":null},
                       "character":{"name":"Claire","image":{"medium":"https://static.tvmaze.com/character.jpg"}}}
                    ]
                    """)
            default: return .text("Missing", status: 404)
            }
        }
        defer { StubURLProtocol.unregister(host: host) }
        let repository = SeriesCastRepository(session: StubURLProtocol.session(), host: host)
        let result = try #require(await repository.cast(title: "|FR| Lupin (2021) FHD", year: 2021))
        #expect(result.creditURL.absoluteString == "https://www.tvmaze.com/shows/51/lupin")
        #expect(result.people.map(\.name) == ["Omar Sy", "Ludivine Sagnier"])
        #expect(result.people.map(\.role) == ["Assane Diop", "Claire"])
        #expect(result.people.first?.portrait?.absoluteString == "https://static.tvmaze.com/omar.jpg")
        #expect(result.people.last?.portrait == nil)
        #expect(await repository.cast(title: "Lupin", year: 2021)?.people.count == 2)
        #expect(StubURLProtocol.requestCount(host: host) == 2)
    }

    @Test func ambiguityAndMissingYearsSkipCastRequests() async {
        let host = StubURLProtocol.uniqueHost("tvmaze-ambiguous")
        StubURLProtocol.register(host: host) { _ in
            .json("""
                [
                  {"show":{"id":20,"name":"La Série","premiered":"2020-01-01","url":"https://www.tvmaze.com/shows/20/la-serie"}},
                  {"show":{"id":21,"name":"La Serie","premiered":"2020-12-21","url":"https://www.tvmaze.com/shows/21/la-serie"}}
                ]
                """)
        }
        defer { StubURLProtocol.unregister(host: host) }
        let repository = SeriesCastRepository(session: StubURLProtocol.session(), host: host)
        #expect(await repository.cast(title: "La Série", year: 0) == nil)
        #expect(StubURLProtocol.requestCount(host: host) == 0)
        #expect(await repository.cast(title: "La série", year: 2020) == nil)
        #expect(await repository.cast(title: "La série", year: 2020) == nil)
        #expect(StubURLProtocol.requestCount(host: host) == 1)
    }

    @Test func answersSurviveARelaunchThroughTheDiskCache() async throws {
        let host = StubURLProtocol.uniqueHost("tvmaze-disk")
        StubURLProtocol.register(host: host) { request in
            switch request.url?.path {
            case "/search/shows":
                return .json(#"[{"show":{"id":51,"name":"Lupin","premiered":"2021-01-08","url":"https://www.tvmaze.com/shows/51/lupin"}}]"#)
            case "/shows/51/cast":
                return .json(#"[{"person":{"id":4,"name":"Omar Sy","image":null},"character":{"name":"Assane Diop"}}]"#)
            default:
                return .json("[]")
            }
        }
        defer { StubURLProtocol.unregister(host: host) }
        let directory = FileManager.default.temporaryDirectory.appending(path: "prism-tvmaze-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = SeriesCastRepository(session: StubURLProtocol.session(), host: host, directory: directory)
        #expect(await first.cast(title: "Lupin", year: 2021)?.people.map(\.name) == ["Omar Sy"])
        #expect(await first.cast(title: "Inconnue", year: 2020) == nil)
        let requests = StubURLProtocol.requestCount(host: host)
        #expect(requests == 3, "search + cast, then one search without an exact match")

        let relaunched = SeriesCastRepository(session: StubURLProtocol.session(), host: host, directory: directory)
        let cast = try #require(await relaunched.cast(title: "Lupin", year: 2021))
        #expect(cast.people.map(\.role) == ["Assane Diop"])
        #expect(cast.creditURL.absoluteString == "https://www.tvmaze.com/shows/51/lupin")
        #expect(await relaunched.cast(title: "Inconnue", year: 2020) == nil)
        #expect(StubURLProtocol.requestCount(host: host) == requests, "both answers served from disk")
    }
}
