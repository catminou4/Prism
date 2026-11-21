import Foundation
import PrismCore
import Testing
@testable import PrismData

@Suite("Mise en cache des scores", .serialized)
struct SportsRepositoryTests {
    @Test func readersShareSchedulesAndPremiumCanBeConfiguredIndependently() async throws {
        let host = "www.thesportsdb.com"
        StubURLProtocol.register(host: host) { request in
            #expect(request.url?.scheme == "https")
            if request.url?.path.contains("/livescore/") == true {
                #expect(request.value(forHTTPHeaderField: "X_API_KEY") == "exemple-sport")
                return .json("""
                    {"livescore":[{
                      "idEvent":"104","idLeague":"4334","dateEvent":"2026-11-21","strEventTime":"16:15:00",
                      "strStatus":"2H","strProgress":"85","strHomeTeam":"Nice","strAwayTeam":"Paris Saint-Germain",
                      "intHomeScore":"2","intAwayScore":"1","strThumb":"https://r2.thesportsdb.com/other.jpg",
                      "strAwayTeamBadge":"https://r2.thesportsdb.com/paris.png"
                    }]}
                    """)
            }
            #expect(request.value(forHTTPHeaderField: "X_API_KEY") == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            if request.queryValue("id") == "4387" { return .text("", status: 503) }
            if request.queryValue("id") == "4334", request.url?.lastPathComponent == "eventsnextleague.php" {
                return .json("""
                    {"events":[{
                      "idEvent":"104","idLeague":"4334","strTimestamp":"2026-11-21T16:15:00","strStatus":"NS",
                      "strHomeTeam":"Nice","strAwayTeam":"Paris Saint-Germain",
                      "strThumb":"https://r2.thesportsdb.com/fixture.jpg","strHomeTeamBadge":"https://r2.thesportsdb.com/nice.png"
                    }]}
                    """)
            }
            return .json(#"{"events":[]}"#)
        }
        defer { StubURLProtocol.unregister(host: host) }

        let credentials = InMemoryCredentialStore()
        let repository = SportsRepository(credentials: credentials, client: SportsClient(session: StubURLProtocol.session()))
        let scheduleRequestCount = SportsLeague.allCases.count * 2
        async let first = repository.scoreboard()
        async let second = repository.scoreboard()
        let (a, b) = await (first, second)

        #expect(a.liveStatus == .needsKey)
        #expect(a.unavailableLeagues == [.nba])
        #expect(b.unavailableLeagues == a.unavailableLeagues)
        #expect(a.updatedAt != nil)
        #expect(StubURLProtocol.requestCount(host: host) == scheduleRequestCount)

        try credentials.setSecret("exemple-sport", named: CredentialKeys.theSportsDB)
        let live = await repository.scoreboard()
        #expect(live.liveStatus == .available)
        let match = try #require(live.events.first)
        #expect(match.status == .live)
        #expect(match.home.score == 2)
        #expect(match.artworkURL?.lastPathComponent == "fixture.jpg")
        #expect(match.home.logoURL?.lastPathComponent == "nice.png")
        #expect(match.away.logoURL?.lastPathComponent == "paris.png")
        #expect(StubURLProtocol.requestCount(host: host) == scheduleRequestCount + 1)
        try credentials.setSecret(nil, named: CredentialKeys.theSportsDB)
        #expect(await repository.scoreboard().liveStatus == .needsKey)
        #expect(StubURLProtocol.requestCount(host: host) == scheduleRequestCount + 1)
    }

    @Test func lateLiveRowsCannotReopenTerminalResults() async throws {
        let host = "www.thesportsdb.com"
        StubURLProtocol.register(host: host) { request in
            func fixture(_ id: String, status: String, homeScore: Int, artwork: String, badge: String) -> String {
                """
                {"idEvent":"\(id)","idLeague":"4334","strTimestamp":"2026-11-21T16:15:00","strStatus":"\(status)",
                 "strHomeTeam":"Nice","strAwayTeam":"Paris Saint-Germain","intHomeScore":\(homeScore),"intAwayScore":1,
                 "strThumb":"https://r2.thesportsdb.com/\(artwork)","strHomeTeamBadge":"https://r2.thesportsdb.com/\(badge)"}
                """
            }
            if request.url?.path.contains("/livescore/") == true {
                let rows = [
                    fixture("played", status: "2H", homeScore: 1, artwork: "live.jpg", badge: "live.png"),
                    fixture("cancelled", status: "2H", homeScore: 1, artwork: "live.jpg", badge: "live.png"),
                    fixture("reviewed", status: "FT", homeScore: 4, artwork: "live.jpg", badge: "live.png"),
                ]
                return .json("{\"livescore\":[\(rows.joined(separator: ","))]}")
            }
            guard request.queryValue("id") == "4334", request.url?.lastPathComponent == "eventspastleague.php"
            else { return .json(#"{"events":[]}"#) }
            let rows = [
                fixture("played", status: "FT", homeScore: 3, artwork: "schedule.jpg", badge: "schedule.png"),
                fixture("cancelled", status: "CANC", homeScore: 0, artwork: "schedule.jpg", badge: "schedule.png"),
                fixture("reviewed", status: "FT", homeScore: 3, artwork: "schedule.jpg", badge: "schedule.png"),
            ]
            return .json("{\"events\":[\(rows.joined(separator: ","))]}")
        }
        defer { StubURLProtocol.unregister(host: host) }
        let repository = SportsRepository(
            credentials: InMemoryCredentialStore(secrets: [CredentialKeys.theSportsDB: "exemple-sport"]),
            client: SportsClient(session: StubURLProtocol.session())
        )

        let snapshot = await repository.scoreboard()
        let played = try #require(snapshot.events.first { $0.id == "played" })
        #expect(played.status == .final)
        #expect(played.home.score == 3)
        #expect(played.artworkURL?.lastPathComponent == "schedule.jpg")
        #expect(played.home.logoURL?.lastPathComponent == "schedule.png")
        #expect(snapshot.events.first { $0.id == "cancelled" }?.status == .cancelled)
        #expect(snapshot.events.first { $0.id == "reviewed" }?.home.score == 4)
    }
}
