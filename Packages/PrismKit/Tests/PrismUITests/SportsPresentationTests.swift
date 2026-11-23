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

    @Test func agendaPromotesWatchableLiveAndKeepsEveryFixtureInOneSection() {
        let liveEvent = SportsEvent(
            id: "nba-live", league: .nba, startsAt: now.addingTimeInterval(-3600), status: .live,
            home: SportsTeam(id: "chi", name: "Chicago", abbreviation: "CHI", score: 96),
            away: SportsTeam(id: "bos", name: "Boston", abbreviation: "BOS", score: 94)
        )
        let scoresOnly = SportsFixture(event: liveEvent, broadcasts: [])
        let onAir = fixture("Brest – Marseille", startsIn: -1800)
        let next = fixture("Lille – Lens", startsIn: 2400)
        let ended = fixture("Nice – Rennes", startsIn: -10_800)
        let preview = fixture("Avant-match : Lille – Lens", startsIn: 1800)
        let fixtures = [ended, scoresOnly, onAir, preview, next]

        let agenda = SportsAgenda(fixtures: fixtures, now: now, day: now, sport: nil)
        #expect(agenda.featured?.id == onAir.id)
        #expect(agenda.sections.map(\.kind) == [.live, .upcoming, .past])
        #expect(agenda.sections.flatMap(\.fixtures).map(\.id) == [scoresOnly.id, next.id, ended.id])
        #expect(agenda.otherPrograms.map(\.id) == [preview.id])

        let live = SportsAgenda(fixtures: fixtures, now: now, day: nil, sport: .basketball)
        #expect(live.featured?.id == scoresOnly.id)
        #expect(live.sections.isEmpty)
        #expect(live.otherPrograms.isEmpty)
    }

    @Test func agendaCanShowAProgrammeWithoutAMatch() {
        let generic = fixture("Football : Ligue des champions", startsIn: 2400)
        let tomorrow = fixture("Lille – Lens", startsIn: 86_400)
        let agenda = SportsAgenda(fixtures: [generic, tomorrow], now: now, day: now, sport: nil)
        #expect(agenda.featured?.id == generic.id)
        #expect(agenda.sections.isEmpty)
        #expect(agenda.otherPrograms.isEmpty)
    }

    private func fixture(_ title: String, subtitle: String? = nil, startsIn: TimeInterval) -> SportsFixture {
        let start = now.addingTimeInterval(startsIn)
        let program = EPGProgram(channelID: channel.id, start: start, end: start.addingTimeInterval(7200), title: title, subtitle: subtitle)
        return SportsFixture(broadcast: SportsBroadcast(channel: channel, program: program, sport: .football))
    }
}
