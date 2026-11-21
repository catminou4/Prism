import Foundation
import Testing
@testable import PrismCore

@Suite("TheSportsDB")
struct SportsClientTests {
    @Test func scheduleInterpretsDatesAndOnlyShowsRecordedScores() throws {
        let data = Data("""
            {"events":[
              {"idEvent":"101","idLeague":"4480","strTimestamp":"2026-11-24T17:45:00","strStatus":"NS",
               "strHomeTeam":"Arsenal","strAwayTeam":"Borussia Dortmund","intHomeScore":"0","intAwayScore":"0",
               "strThumb":"https://r2.thesportsdb.com/fixture.jpg","strPoster":"https://r2.thesportsdb.com/poster.jpg"},
              {"idEvent":"102","idLeague":"4387","dateEvent":"2026-11-21","strTime":"03:00:00","strStatus":"FT",
               "strHomeTeam":"Los Angeles Lakers","strAwayTeam":"Sacramento Kings","intHomeScore":112,"intAwayScore":"108",
               "strThumb":17,"strPoster":"https://www.thesportsdb.com/poster.jpg"},
              {"idEvent":"103","idLeague":"4445","strTimestamp":"2026-11-20T22:00:00",
               "strEvent":"Boxeur A vs Boxeur B","strStatus":"FT","strResult":"Arrêt au huitième round.",
               "strThumb":"https://r2.thesportsdb.com.example.invalid/fixture.jpg","strPoster":"http://r2.thesportsdb.com/poster.jpg"},
              {"idEvent":"unparseable","idLeague":[]}
            ]}
            """.utf8)
        let events = try SportsClient.decode(data, isLiveFeed: false)
        #expect(events.count == 3)
        let next = try #require(events.first)
        #expect(next.startsAt == (try Date.ISO8601FormatStyle().parse("2026-11-24T17:45:00Z")))
        #expect(next.status == .scheduled)
        #expect(next.home.score == nil)
        #expect(next.artworkURL?.lastPathComponent == "fixture.jpg")
        #expect(events[1].status == .final)
        #expect(events[1].home.score == 112)
        #expect(events[1].away.score == 108)
        #expect(events[1].artworkURL?.lastPathComponent == "poster.jpg")
        #expect(events[2].league == .boxing)
        #expect(events[2].home.name == "Boxeur A")
        #expect(events[2].away.name == "Boxeur B")
        #expect(events[2].resultSummary == "Arrêt au huitième round.")
        #expect(events[2].home.score == nil)
        #expect(events[2].artworkURL == nil)
    }

    @Test func premiumLiveFeedAddsClockAndRejectsUnexpectedPayloads() throws {
        let data = Data("""
            {"livescore":[
              {"idEvent":"104","idLeague":"4334","dateEvent":"2026-11-21","strEventTime":"16:15:00",
               "strStatus":"2H","strProgress":"85","strHomeTeam":"Nice","strAwayTeam":"Paris Saint-Germain",
               "intHomeScore":"2","intAwayScore":"1","strHomeTeamBadge":"https://r2.thesportsdb.com/nice.png",
               "strAwayTeamBadge":"http://r2.thesportsdb.com/paris.png"}
            ]}
            """.utf8)
        let match = try #require(SportsClient.decode(data, isLiveFeed: true).first)
        #expect(match.status == .live)
        #expect(match.displayClock == "85′")
        #expect(match.period == 2)
        #expect(match.home.score == 2)
        #expect(match.away.score == 1)
        #expect(match.home.logoURL?.scheme == "https")
        #expect(match.away.logoURL == nil)
        #expect(try SportsClient.decode(Data(#"{"livescore":null}"#.utf8), isLiveFeed: true).isEmpty)
        #expect(throws: URLError.self) { try SportsClient.decode(Data("{}".utf8), isLiveFeed: true) }
    }
}
