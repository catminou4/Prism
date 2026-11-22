import Foundation
import PrismCore
import Testing
@testable import PrismData

struct SportsBroadcastTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func scheduleOnlyUsesLinkedChannelsAndOmitsHighlights() async {
        let guide = EPGGuide(programs: [
            program("uel", "UEFA Ligue des champions : Paris SG - Inter"),
            program("boxe", "Soirée de boxe anglaise"),
            program("nba", "Lakers / Celtics", category: "NBA"),
            program("resume", "Résumé NBA : Lakers / Celtics"),
            program("nfl", "Football américain NFL"),
            program("college", "College Football", category: "Football"),
            program("unknown", "UEFA Champions League"),
        ])
        let matches = await guide.sportsSchedule(
            channels: ["uel", "boxe", "nba", "resume", "nfl", "college", "unmatched"].map(channel)
                + [ChannelGroup(id: "empty", name: "Inaccessible", epgID: "unknown", variants: [])],
            in: DateInterval(start: start, duration: 7_200)
        )
        #expect(Set(matches.map(\.sport)) == [.football, .basketball, .boxing])
        #expect(Set(matches.map(\.channel.id)) == ["uel", "boxe", "nba"])
        #expect(matches.allSatisfy { $0.guideVariantID == $0.channel.primary?.id })
    }

    @Test func scoreLinksRequireBothTeamsRightCompetitionAndKickoff() async throws {
        let fixture = SportsEvent(
            id: "fixture", league: .championsLeague, startsAt: start, status: .scheduled,
            home: SportsTeam(id: "psg", name: "Paris Saint-Germain", abbreviation: "PSG"),
            away: SportsTeam(id: "inter", name: "Internazionale", abbreviation: "INT")
        )
        let channels: [(id: String, title: String, offset: TimeInterval, sport: BroadcastSport)] = [
            ("good", "UEFA : Paris-SG – Inter Milan", -600, .football),
            ("good2", "Football : PSG / Internazionale", 0, .football),
            ("preview", "Avant-match UEFA : Paris SG – Inter Milan", -1_800, .football),
            ("post-game", "UEFA : PSG / Internazionale, le débrief après-match", 600, .football),
            ("late", "UEFA Paris SG - Inter Milan", 3_600, .football),
            ("other", "UEFA Paris SG - Bayern", 0, .football),
            ("partial", "UEFA Paris SG - Internationale Juniors", 0, .football),
            ("wrong-league", "Ligue 1 : Paris SG / Inter Milan", 0, .football),
            ("wrong-sport", "Paris SG / Inter Milan", 0, .basketball),
        ]
        let broadcasts = channels.map {
            SportsBroadcast(channel: channel($0.id), program: program($0.id, $0.title, offset: $0.offset), sport: $0.sport)
        }
        let result = await SportsScheduleMatcher.match(events: [fixture], broadcasts: broadcasts)
        let links = try #require(result[fixture.id])
        #expect(links.map(\.channel.id) == ["good", "good2"])
    }

    @Test func linksBoxersToTheFightFromSpecificGuideGenre() async {
        let bout = SportsEvent(
            id: "fight", league: .boxing, startsAt: start, status: .live,
            home: SportsTeam(id: "a", name: "Oleksandr Usyk", abbreviation: ""),
            away: SportsTeam(id: "b", name: "Tyson Fury", abbreviation: "")
        )
        var match = program("boxing", "Usyk vs Fury", category: "Sport")
        match.categoryLabels = ["Sport", "Boxe anglaise"]
        let guide = EPGGuide(programs: [match])
        let broadcasts = await guide.sportsSchedule(channels: [channel("boxing")], in: match.interval)
        let links = await SportsScheduleMatcher.match(events: [bout], broadcasts: broadcasts)
        #expect(links[bout.id]?.map(\.channel.id) == ["boxing"])
    }

    @Test func memoisedClassificationAgreesWithTheFullMatcher() {
        let titles: [(String, String?)] = [
            ("UEFA Ligue des champions : Paris SG - Inter", nil), ("SOIRÉE DE BOXE", nil), ("Lakers / Celtics", "NBA"),
            ("Le journal de 20 heures", "Information"), ("Météo", nil), ("FOOTBALL : OM - OL", nil),
            ("Football américain NFL", nil), ("Résumé", "Basket-ball"), ("Ｆｏｏｔｂａｌｌ", nil), ("Fútbol", "Soccer"),
        ]
        var memo: [SportsScheduleMatcher.ClassifyKey: BroadcastSport?] = [:]
        for (title, category) in titles + titles {
            let item = program("x", title, category: category)
            #expect(SportsScheduleMatcher.classify(item, memo: &memo) == SportsScheduleMatcher.classify(item), "\(title)")
        }
        #expect(!SportsScheduleMatcher.mayMentionSport("Le journal de 20 heures\u{1F}\u{1F}Information"))
        #expect(SportsScheduleMatcher.mayMentionSport("SOCCER night"))
    }

    private func channel(_ id: String) -> ChannelGroup {
        ChannelGroup(id: id, name: id, epgID: id, variants: [Fixture.channel(Fixture.a, id, id, epg: id)])
    }

    private func program(_ id: String, _ title: String, category: String? = nil, offset: TimeInterval = 0) -> EPGProgram {
        let airing = start.addingTimeInterval(offset)
        return EPGProgram(channelID: id, start: airing, end: airing.addingTimeInterval(7_200), title: title, category: category)
    }
}
