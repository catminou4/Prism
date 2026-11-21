import Foundation

public enum SportsLeague: String, CaseIterable, Hashable, Identifiable, Sendable {
    case championsLeague
    case ligue1
    case nba
    case boxing

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .championsLeague: "Ligue des champions"
        case .ligue1: "Ligue 1"
        case .nba: "NBA"
        case .boxing: "Boxe"
        }
    }
}

public enum SportsEventStatus: Hashable, Sendable {
    case scheduled
    case live
    case final
    case postponed
    case cancelled
}

public struct SportsTeam: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let abbreviation: String
    public let logoURL: URL?
    public let score: Int?

    public init(id: String, name: String, abbreviation: String, logoURL: URL? = nil, score: Int? = nil) {
        self.id = id
        self.name = name
        self.abbreviation = abbreviation
        self.logoURL = logoURL
        self.score = score
    }
}

public struct SportsEvent: Identifiable, Hashable, Sendable {
    public let id: String
    public let league: SportsLeague
    public let startsAt: Date
    public let status: SportsEventStatus
    public let home: SportsTeam
    public let away: SportsTeam
    public let displayClock: String?
    public let period: Int?
    public let resultSummary: String?
    public let artworkURL: URL?

    public init(
        id: String, league: SportsLeague, startsAt: Date, status: SportsEventStatus,
        home: SportsTeam, away: SportsTeam, displayClock: String? = nil, period: Int? = nil,
        resultSummary: String? = nil, artworkURL: URL? = nil
    ) {
        self.id = id
        self.league = league
        self.startsAt = startsAt
        self.status = status
        self.home = home
        self.away = away
        self.displayClock = displayClock
        self.period = period
        self.resultSummary = resultSummary
        self.artworkURL = artworkURL
    }
}
