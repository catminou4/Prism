import Foundation

/// Documented TheSportsDB API. This session uses HTTPS only and does not share IPTV credentials,
/// cookies or connection settings. The optional v2 key stays in the request header.
public struct SportsClient: Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? Self.session
    }

    @concurrent
    public func schedule(for league: SportsLeague, upcoming: Bool) async throws -> [SportsEvent] {
        let endpoint = upcoming ? "eventsnextleague.php" : "eventspastleague.php"
        let data = try await get(path: "/api/v1/json/123/" + endpoint, query: [.init(name: "id", value: league.providerID)])
        return try Self.decode(data, isLiveFeed: false)
    }

    @concurrent
    public func live(apiKey: String) async throws -> [SportsEvent] {
        let data = try await get(path: "/api/v2/json/livescore/all", apiKey: apiKey)
        return try Self.decode(data, isLiveFeed: true)
    }

    private func get(path: String, query: [URLQueryItem] = [], apiKey: String? = nil) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.thesportsdb.com"
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "X_API_KEY") }
        let (data, response) = try await session.data(for: request, delegate: NoSportsRedirects())
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 12
        return URLSession(configuration: configuration)
    }()

    static func decode(_ data: Data, isLiveFeed: Bool) throws -> [SportsEvent] {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let rows = isLiveFeed ? envelope.live : envelope.schedule else { throw URLError(.cannotParseResponse) }
        let normal = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        return rows.compactMap { $0.record?.event(isLiveFeed: isLiveFeed) { timestamp in
            // Provider timestamps without an explicit offset are UTC.
            normal.date(from: timestamp) ?? fractional.date(from: timestamp)
                ?? normal.date(from: timestamp + "Z") ?? fractional.date(from: timestamp + "Z")
        } }
    }

    private struct Envelope: Decodable {
        let schedule: [Row]?
        let live: [Row]?

        enum CodingKeys: String, CodingKey {
            case events
            case livescore
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schedule = container.contains(.events) ? try container.decodeIfPresent([Row].self, forKey: .events) ?? [] : nil
            live = container.contains(.livescore) ? try container.decodeIfPresent([Row].self, forKey: .livescore) ?? [] : nil
        }
    }

    private struct Row: Decodable {
        let record: Record?

        init(from decoder: any Decoder) { record = try? Record(from: decoder) }
    }

    private struct WireNumber: Decodable {
        let number: Int?

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            number = (try? container.decode(Int.self)) ?? (try? container.decode(String.self)).flatMap(Int.init)
        }
    }

    private struct WireImage: Decodable {
        let url: URL?

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            guard let raw = try? container.decode(String.self),
                  let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
                  let host = url.host?.lowercased(),
                  host == "thesportsdb.com" || host.hasSuffix(".thesportsdb.com") else {
                self.url = nil
                return
            }
            self.url = url
        }
    }

    private struct Record: Decodable {
        let idEvent: String?
        let idLeague: String?
        let strTimestamp: String?
        let dateEvent: String?
        let strTime: String?
        let strEventTime: String?
        let strStatus: String?
        let strProgress: String?
        let strEvent: String?
        let strResult: String?
        let idHomeTeam: String?
        let idAwayTeam: String?
        let strHomeTeam: String?
        let strAwayTeam: String?
        let strHomeTeamBadge: WireImage?
        let strAwayTeamBadge: WireImage?
        let strThumb: WireImage?
        let strPoster: WireImage?
        let intHomeScore: WireNumber?
        let intAwayScore: WireNumber?

        func event(isLiveFeed: Bool, parseDate: (String) -> Date?) -> SportsEvent? {
            guard let idEvent, !idEvent.isEmpty, let idLeague,
                  let league = SportsLeague.allCases.first(where: { $0.providerID == idLeague }),
                  let (homeName, awayName) = participants(league) else { return nil }
            let start = strTimestamp.flatMap(parseDate) ?? {
                guard let dateEvent, let time = strEventTime ?? strTime else { return nil }
                return parseDate(dateEvent + "T" + time)
            }()
            guard let start else { return nil }

            let code = strStatus?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
            let status = Self.status(code, isLiveFeed: isLiveFeed)
            let showScore = league != .boxing && (status == .final || status == .live)
            return SportsEvent(
                id: idEvent, league: league, startsAt: start, status: status,
                home: Self.team(idHomeTeam, homeName, strHomeTeamBadge?.url, showScore ? intHomeScore?.number : nil),
                away: Self.team(idAwayTeam, awayName, strAwayTeamBadge?.url, showScore ? intAwayScore?.number : nil),
                displayClock: status == .live && league != .boxing ? Self.clock(strProgress, league: league) : nil,
                period: status == .live && league != .boxing ? Self.period(code, league: league) : nil,
                resultSummary: status == .final && league == .boxing ? Self.cleaned(strResult) : nil,
                artworkURL: strThumb?.url ?? strPoster?.url
            )
        }

        private func participants(_ league: SportsLeague) -> (String, String)? {
            if league == .boxing, let strEvent, let separator = strEvent.range(of: " vs ", options: .caseInsensitive),
               let first = Self.cleaned(String(strEvent[..<separator.lowerBound])),
               let second = Self.cleaned(String(strEvent[separator.upperBound...])) {
                return (first, second)
            }
            guard let home = Self.cleaned(strHomeTeam), let away = Self.cleaned(strAwayTeam) else { return nil }
            return (home, away)
        }

        private static func status(_ code: String, isLiveFeed: Bool) -> SportsEventStatus {
            switch code {
            case "FT", "AET", "AP", "PEN", "FINAL", "ENDED", "FINISHED", "MATCH FINISHED": .final
            case "PST", "PPD", "POSTPONED", "SUSPENDED", "INT": .postponed
            case "CANC", "ABD", "ABANDONED", "CANCELED", "CANCELLED": .cancelled
            case "1H", "2H", "HT", "ET", "BT", "P", "LIVE", "IN PLAY", "IN PROGRESS", "Q1", "Q2", "Q3", "Q4", "OT":
                isLiveFeed ? .live : .scheduled
            default: .scheduled
            }
        }

        private static func period(_ code: String, league: SportsLeague) -> Int? {
            if league == .nba, code.hasPrefix("Q") { return Int(code.dropFirst()) }
            switch code {
            case "1H", "HT": return 1
            case "2H": return 2
            default: return nil
            }
        }

        private static func clock(_ raw: String?, league: SportsLeague) -> String? {
            guard let value = cleaned(raw), value.count <= 12 else { return nil }
            if league != .nba, Int(value) != nil { return value + "′" }
            return value
        }

        private static func team(_ id: String?, _ name: String, _ badge: URL?, _ score: Int?) -> SportsTeam {
            let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            let abbreviation = words.count > 1 ? String(words.prefix(3).compactMap(\.first)) : String(name.prefix(3))
            return SportsTeam(id: id ?? name, name: name, abbreviation: abbreviation.uppercased(), logoURL: badge, score: score)
        }

        private static func cleaned(_ value: String?) -> String? {
            guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
    }
}

private extension SportsLeague {
    var providerID: String {
        switch self {
        case .championsLeague: "4480"
        case .ligue1: "4334"
        case .nba: "4387"
        case .boxing: "4445"
        }
    }
}

private final class NoSportsRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
