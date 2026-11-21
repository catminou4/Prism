import Foundation
import PrismCore
import PrismData
import Testing
@testable import PrismUI

@MainActor
struct SportsPresentationTests {
    private let channel = ChannelGroup(id: "stadium", name: "Stadium", variants: [])
    private let now = Calendar.current.startOfDay(for: .now).addingTimeInterval(13 * 3600)

    @Test func homePrioritizesNamedFixturesOverGenericPrograms() {
        let preview = fixture("Brest – Marseille : avant-match", startsIn: -1800)
        let generic = fixture("Football : Ligue des champions", startsIn: -1200)
        let named = fixture("Ligue 1", subtitle: "Brest – Marseille", startsIn: 2400)
        let game = SportsEvent(
            id: "nba", league: .nba, startsAt: now.addingTimeInterval(3600), status: .scheduled,
            home: SportsTeam(id: "chi", name: "Chicago", abbreviation: "CHI"),
            away: SportsTeam(id: "bos", name: "Boston", abbreviation: "BOS")
        )
        let official = SportsFixture(event: game, broadcasts: [])
        #expect(SportsHomeShelf.homeFixtures([preview, generic, named, official], now: now).map(\.id) == [official.id, named.id])
        #expect(SportsHomeShelf.homeFixtures([preview, generic], now: now).map(\.id) == [generic.id])
        #expect(named.title == "Brest – Marseille")
    }

    @Test func upcomingCardTargetsTheRightDayAndCannotPlayBeforeItsSlot() {
        let program = fixture("Brest – Marseille", startsIn: 86_400)
        let destination = SportsDestination(program, now: now)
        #expect(destination.fixtureID == program.id)
        #expect(Calendar.current.isDate(destination.day, inSameDayAs: program.startsAt))
        #expect(!destination.isLive)
        #expect(program.liveBroadcasts(at: now).isEmpty)
    }

    private func fixture(_ title: String, subtitle: String? = nil, startsIn: TimeInterval) -> SportsFixture {
        let start = now.addingTimeInterval(startsIn)
        let program = EPGProgram(channelID: channel.id, start: start, end: start.addingTimeInterval(7200), title: title, subtitle: subtitle)
        return SportsFixture(broadcast: SportsBroadcast(channel: channel, program: program, sport: .football))
    }
}
