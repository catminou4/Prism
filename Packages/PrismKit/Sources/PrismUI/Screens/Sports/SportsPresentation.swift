import Foundation
import Observation
import PrismCore
import PrismData
import SwiftUI

@Observable
final class SportsPresentation {
    private(set) var fixtures: [SportsFixture]
    private(set) var now: Date
    private(set) var hasLoaded: Bool
    private(set) var liveStatus: SportsLiveStatus?
    var destination: SportsDestination?
    @ObservationIgnored private var scheduleKey: SportsScheduleKey?
    @ObservationIgnored private var broadcasts: [SportsBroadcast] = []
    @ObservationIgnored private var displayedKey: SportsScheduleKey?
    @ObservationIgnored private var displayedEvents: [SportsEvent] = []

    init(fixtures: [SportsFixture] = [], now: Date = .now) {
        self.fixtures = fixtures
        self.now = now
        hasLoaded = !fixtures.isEmpty
    }

    func run(app: AppModel, key: SportsScheduleKey) async {
        while !Task.isCancelled {
            now = .now
            async let scores = app.sportsRepository.scoreboard()
            if scheduleKey != key {
                let window = Self.scheduleWindow(from: key.day)
                let schedule = await app.guide.sportsSchedule(channels: app.catalog.channels, in: window)
                guard !Task.isCancelled else { return }
                broadcasts = schedule
                scheduleKey = key
                if !schedule.isEmpty {
                    await updateFixtures(with: displayedEvents, key: key)
                    guard !Task.isCancelled else { return }
                    hasLoaded = true
                }
            }
            let snapshot = await scores
            guard !Task.isCancelled else { return }
            let events = snapshot.liveStatus == .unavailable
                ? snapshot.events.filter { $0.status != .live } : snapshot.events
            await updateFixtures(with: events, key: key)
            guard !Task.isCancelled else { return }
            liveStatus = snapshot.liveStatus
            hasLoaded = true
            do { try await Task.sleep(for: .seconds(60), tolerance: .seconds(6)) } catch { return }
        }
    }

    private func updateFixtures(with events: [SportsEvent], key: SportsScheduleKey) async {
        guard displayedKey != key || displayedEvents != events else { return }
        let values = await Self.combine(events, with: broadcasts)
        guard !Task.isCancelled else { return }
        displayedKey = key
        displayedEvents = events
        if fixtures != values { fixtures = values }
    }

    nonisolated static func scheduleWindow(from day: Date) -> DateInterval {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        let end = calendar.date(byAdding: .day, value: 7, to: day) ?? day.addingTimeInterval(7 * 86_400)
        return DateInterval(start: start, end: end)
    }

    @concurrent private static func combine(_ events: [SportsEvent], with broadcasts: [SportsBroadcast]) async -> [SportsFixture] {
        let matches = await SportsScheduleMatcher.match(events: events, broadcasts: broadcasts)
        let associated = Set(matches.values.lazy.flatMap { $0 }.map(\.id))
        let matchesAndPrograms = events.map { SportsFixture(event: $0, broadcasts: matches[$0.id] ?? []) }
            + broadcasts.filter { !associated.contains($0.id) }.map { SportsFixture(broadcast: $0) }
        return matchesAndPrograms.sorted { ($0.startsAt, $0.id) < ($1.startsAt, $1.id) }
    }
}

nonisolated struct SportsDestination: Equatable, Sendable {
    let fixtureID: String
    let day: Date
    let isLive: Bool

    init(_ fixture: SportsFixture, now: Date) {
        fixtureID = fixture.id
        day = Calendar.current.startOfDay(for: fixture.startsAt)
        isLive = fixture.isAiring(at: now)
    }
}

nonisolated struct SportsScheduleKey: Hashable, Sendable {
    let day: Date
    let guideRevision: Int
    let catalogRevision: Int
    let settingsRevision: Int
}

struct SportsUpdates: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(SportsPresentation.self) private var presentation: SportsPresentation?
    @Environment(\.isPageActive) private var isActive
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        let day = Calendar.current.startOfDay(for: presentation?.now ?? .now)
        let key = isActive && appearsActive ? SportsScheduleKey(
            day: day, guideRevision: app.guideRevision, catalogRevision: app.catalogRevision,
            settingsRevision: app.sportsSettingsRevision
        ) : nil
        content.task(id: key) {
            if let key { await presentation?.run(app: app, key: key) }
        }
    }
}

nonisolated struct SportsFixture: Identifiable, Equatable, Sendable {
    struct Opponents: Equatable, Sendable {
        let home: String
        let away: String
    }

    let id: String
    let startsAt: Date
    let sport: BroadcastSport
    let title: String
    let event: SportsEvent?
    let broadcasts: [SportsBroadcast]
    let guideOpponents: Opponents?
    let isCompanionProgram: Bool

    var isNamedBroadcast: Bool { guideOpponents != nil }
    var isIdentifiedMatch: Bool { event != nil || (isNamedBroadcast && !isCompanionProgram) }

    init(event: SportsEvent, broadcasts: [SportsBroadcast]) {
        id = "score:\(event.id)"
        startsAt = event.startsAt
        sport = BroadcastSport(league: event.league)
        title = "\(event.home.name) – \(event.away.name)"
        self.event = event
        self.broadcasts = broadcasts
        guideOpponents = nil
        isCompanionProgram = false
    }

    init(broadcast: SportsBroadcast) {
        id = "guide:\(broadcast.id)"
        startsAt = broadcast.program.start
        sport = broadcast.sport
        let named = [broadcast.program.title, broadcast.program.subtitle].lazy.compactMap { $0 }
            .compactMap { label in Self.opponents(in: label).map { (label, $0) } }.first
        title = named?.0 ?? broadcast.program.title
        event = nil
        broadcasts = [broadcast]
        guideOpponents = named?.1
        let text = " \(TitleNormalizer.key(broadcast.program.title + " " + (broadcast.program.subtitle ?? ""))) "
        isCompanionProgram = Self.companionLabels.contains { text.contains(" \($0) ") }
    }

    var competition: String { event?.league.displayName ?? sport.displayName }

    var showsScore: Bool { event?.status == .live || event?.status == .final }

    var scoreline: String? {
        guard showsScore, let event, event.home.score != nil || event.away.score != nil else { return nil }
        let home = event.home.score?.formatted() ?? "–"
        let away = event.away.score?.formatted() ?? "–"
        return "\(home) : \(away)"
    }

    var channelSummary: String? {
        let names = broadcasts.map(\.channel.name)
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }

    func isAiring(at date: Date) -> Bool {
        isLive(at: date) || (event != nil && !liveBroadcasts(at: date).isEmpty)
    }

    func liveBroadcasts(at date: Date) -> [SportsBroadcast] {
        switch event?.status {
        case .cancelled, .postponed, .final: return []
        case .scheduled where startsAt > date: return []
        default: break
        }
        return broadcasts.filter { $0.program.isAiring(at: date) }
    }

    func isLive(at date: Date) -> Bool {
        if let event { return event.status == .live }
        return !liveBroadcasts(at: date).isEmpty
    }

    func state(at date: Date) -> String {
        switch event?.status {
        case .live: liveState
        case .final: "Terminé"
        case .postponed: "Reporté"
        case .cancelled: "Annulé"
        case .scheduled: "À venir"
        case nil:
            isLive(at: date) ? "À l’antenne" : (startsAt > date ? "À venir" : "Diffusé")
        }
    }

    private var liveState: String {
        let stage: String = if event?.league == .nba, let period = event?.period, period > 0 {
            period <= 4 ? "QT \(period)" : "Prol. \(period - 4)"
        } else {
            "En cours"
        }
        guard let clock = event?.displayClock, !clock.isEmpty else { return stage }
        return "\(stage) · \(clock)"
    }

    private static let companionLabels = [
        "avant match", "apres match", "pre match", "preview", "pre game", "pregame", "post game", "postgame", "debrief",
        "nba today", "nba countdown", "inside the nba", "sportscenter", "sports center",
    ]

    private static let genericOpponents: Set<String> = [
        "football", "soccer", "basket", "basket ball", "basketball", "boxe", "boxing", "nba", "ligue 1",
        "ligue des champions", "champions league", "uefa champions league", "en direct", "live", "direct",
    ]

    private static func opponents(in title: String) -> Opponents? {
        for separator in [" – ", " — ", " - ", " vs ", " vs. ", " contre "] {
            guard let range = title.range(of: separator, options: .caseInsensitive) else { continue }
            let home = title[..<range.lowerBound].split(separator: ":").last.map(String.init) ?? ""
            let away = String(title[range.upperBound...])
            if [home, away].allSatisfy({ candidate in
                let name = TitleNormalizer.key(candidate)
                return name.count >= 2 && !genericOpponents.contains(name)
            }) { return Opponents(home: home, away: away) }
        }
        return nil
    }
}

nonisolated extension BroadcastSport {
    var symbol: String {
        switch self {
        case .football: "soccerball"
        case .basketball: "basketball"
        case .boxing: "figure.boxing"
        }
    }
}

struct SportsPlayback {
    let app: AppModel
    let play: PrismPlaybackAction

    func callAsFunction(_ broadcast: SportsBroadcast) {
        guard broadcast.program.isAiring(at: .now),
              let channel = app.catalog.channelGroup(broadcast.channel.id) else { return }
        let variant: Channel? = if let guideVariantID = broadcast.guideVariantID {
            channel.variants.first { $0.id == guideVariantID }
        } else {
            LivePlayback.preferredVariant(in: channel, library: app.library)
        }
        guard let variant else { return }
        var compatibleChannel = channel
        if broadcast.guideVariantID != nil {
            compatibleChannel.variants = [variant]
        }
        let item = LivePlayback.makeItem(group: compatibleChannel, variant: variant, program: broadcast.program)
        play(item, .channel(groupID: channel.id), variant.id)
    }
}
