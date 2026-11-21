import Foundation
import PrismCore

public enum SportsLiveStatus: Equatable, Sendable {
    case needsKey
    case available
    case unavailable
}

public struct SportsSnapshot: Sendable {
    public static let empty = SportsSnapshot()

    public let events: [SportsEvent]
    public let updatedAt: Date?
    public let unavailableLeagues: Set<SportsLeague>
    public let staleLeagues: Set<SportsLeague>
    public let liveStatus: SportsLiveStatus

    public init(
        events: [SportsEvent] = [], updatedAt: Date? = nil,
        unavailableLeagues: Set<SportsLeague> = [], staleLeagues: Set<SportsLeague> = [],
        liveStatus: SportsLiveStatus = .needsKey
    ) {
        self.events = events
        self.updatedAt = updatedAt
        self.unavailableLeagues = unavailableLeagues
        self.staleLeagues = staleLeagues
        self.liveStatus = liveStatus
    }
}

/// Shares requests between the home shelf and the full sports page. Schedules refresh every five
/// minutes; the optional live feed refreshes at most once a minute while a view is showing scores.
public actor SportsRepository {
    private enum Feed: Hashable {
        case upcoming(SportsLeague)
        case recent(SportsLeague)
        case live
    }

    private struct CachedFeed: Sendable {
        let events: [SportsEvent]
        let updatedAt: Date?
        let retryAfter: Date
        let failed: Bool

        static var unavailable: Self {
            .init(events: [], updatedAt: nil, retryAfter: .now, failed: true)
        }
    }

    private struct Request: Sendable {
        let id = UUID()
        let task: Task<CachedFeed, Never>
    }

    private let credentials: any CredentialStoring
    private let client: SportsClient
    private var cache: [Feed: CachedFeed] = [:]
    private var inFlight: [Feed: Request] = [:]
    private var liveKey: String?
    private var previousEvents: [String: SportsEvent] = [:]

    public init(credentials: any CredentialStoring, client: SportsClient = SportsClient()) {
        self.credentials = credentials
        self.client = client
    }

    public func scoreboard() async -> SportsSnapshot {
        let key = credentials.secret(named: CredentialKeys.theSportsDB)
        if key != liveKey {
            liveKey = key
            inFlight.removeValue(forKey: .live)?.task.cancel()
            cache[.live] = nil
        }

        var feeds = SportsLeague.allCases.flatMap { [Feed.upcoming($0), .recent($0)] }
        if key != nil { feeds.append(.live) }
        let results = await withTaskGroup(of: (Feed, CachedFeed).self) { group in
            for feed in feeds {
                group.addTask { (feed, await self.load(feed, key: key)) }
            }
            var values: [Feed: CachedFeed] = [:]
            for await (feed, value) in group { values[feed] = value }
            return values
        }

        var events: [String: SportsEvent] = [:]
        var unavailable: Set<SportsLeague> = []
        var stale: Set<SportsLeague> = []
        for league in SportsLeague.allCases {
            let upcoming = results[.upcoming(league)] ?? .unavailable
            let recent = results[.recent(league)] ?? .unavailable
            if upcoming.updatedAt == nil && recent.updatedAt == nil { unavailable.insert(league) }
            else if upcoming.failed || recent.failed { stale.insert(league) }
            for event in upcoming.events { events[event.id] = event }
            for event in recent.events {
                events[event.id] = Self.retainingArtwork(in: event, from: events[event.id])
            }
        }
        let live = results[.live]
        if key == liveKey {
            for event in live?.events ?? [] {
                let schedule = events[event.id]
                let previous = previousEvents[event.id]
                let update = Self.retainingArtwork(in: event, from: previous)
                let terminal = Self.terminalResult(from: schedule, over: update)
                    ?? Self.terminalResult(from: previous, over: update)
                let current = terminal.map { Self.retainingArtwork(in: $0, from: update) } ?? update
                events[event.id] = Self.retainingArtwork(in: current, from: schedule)
            }
            // An active event can disappear from the schedule as soon as its start time passes.
            previousEvents = events
        }
        let liveStatus: SportsLiveStatus = key == nil ? .needsKey : (live?.failed == false ? .available : .unavailable)
        return SportsSnapshot(
            events: events.values.sorted {
                $0.startsAt == $1.startsAt ? $0.id < $1.id : $0.startsAt < $1.startsAt
            },
            updatedAt: results.values.compactMap(\.updatedAt).max(),
            unavailableLeagues: unavailable, staleLeagues: stale, liveStatus: liveStatus
        )
    }

    /// The live feed can lag after a match has ended. A reported final result can still replace
    /// a scheduled match or update its scores after review.
    private static func terminalResult(from event: SportsEvent?, over update: SportsEvent) -> SportsEvent? {
        guard let event, event.league == update.league,
              (event.status == .final || event.status == .cancelled),
              (update.status != .final && update.status != .cancelled) else { return nil }
        return event
    }

    private static func retainingArtwork(in event: SportsEvent, from earlier: SportsEvent?) -> SportsEvent {
        guard let earlier, earlier.league == event.league else { return event }
        func team(_ fresh: SportsTeam, previous: SportsTeam) -> SportsTeam {
            guard let logo = previous.logoURL, fresh.id == previous.id || fresh.name == previous.name else { return fresh }
            return SportsTeam(id: fresh.id, name: fresh.name, abbreviation: fresh.abbreviation, logoURL: logo, score: fresh.score)
        }
        return SportsEvent(
            id: event.id, league: event.league, startsAt: event.startsAt, status: event.status,
            home: team(event.home, previous: earlier.home), away: team(event.away, previous: earlier.away),
            displayClock: event.displayClock, period: event.period, resultSummary: event.resultSummary,
            artworkURL: earlier.artworkURL ?? event.artworkURL
        )
    }

    private func load(_ feed: Feed, key: String?) async -> CachedFeed {
        guard feed != .live || key == liveKey else { return .unavailable }
        if let cached = cache[feed], cached.retryAfter > .now { return cached }
        let request: Request
        if let pending = inFlight[feed] {
            request = pending
        } else {
            let previous = cache[feed]
            let client = self.client
            request = Request(task: Task {
                do {
                    let events: [SportsEvent]
                    switch feed {
                    case .upcoming(let league):
                        events = try await client.schedule(for: league, upcoming: true)
                    case .recent(let league):
                        events = try await client.schedule(for: league, upcoming: false)
                    case .live:
                        guard let key else { return .unavailable }
                        events = try await client.live(apiKey: key)
                    }
                    let now = Date.now
                    return CachedFeed(events: events, updatedAt: now, retryAfter: now.addingTimeInterval(feed == .live ? 60 : 300), failed: false)
                } catch {
                    let now = Date.now
                    let usable = feed != .live && previous?.updatedAt.map { now.timeIntervalSince($0) < 7_200 } == true
                    return CachedFeed(
                        events: usable ? previous?.events ?? [] : [],
                        updatedAt: usable ? previous?.updatedAt : nil,
                        retryAfter: now.addingTimeInterval(120), failed: true
                    )
                }
            })
            inFlight[feed] = request
        }

        let result = await request.task.value
        if inFlight[feed]?.id == request.id {
            cache[feed] = result
            inFlight[feed] = nil
        }
        if feed == .live, key != liveKey { return .unavailable }
        return result
    }
}
