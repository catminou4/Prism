import Foundation
import PrismCore

public struct SeriesCast: Sendable {
    public struct Person: Identifiable, Sendable {
        public let id: Int
        public let name: String
        public let role: String?
        public let portrait: URL?
    }

    public let people: [Person]
    public let creditURL: URL
}

/// Looks up a single series page using only its title and premiere year.
public actor SeriesCastRepository {
    public static let shared = SeriesCastRepository()

    private let client: HTTPClient
    private let host: String
    private var cache: [Lookup: Cached] = [:]
    /// Concurrent lookups of the same (title, year) share one request pair.
    private var inFlight: [Lookup: CastRequest] = [:]

    private struct CastRequest {
        let id = UUID()
        let task: Task<SeriesCast?, Never>
    }

    public init(session: URLSession = PrismURLSession.shared) {
        self.init(session: session, host: "api.tvmaze.com")
    }

    init(session: URLSession, host: String) {
        self.client = HTTPClient(session: session, userAgent: nil)
        self.host = host
    }

    public func cast(title: String, year: Int) async -> SeriesCast? {
        guard (1900...2100).contains(year), !Task.isCancelled,
              !title.contains("://"), !title.contains("@") else { return nil }
        let name = TitleNormalizer.normalize(title).title
        guard name.count <= 160 else { return nil }
        let lookup = Lookup(name: TitleNormalizer.key(name), year: year)
        guard !lookup.name.isEmpty else { return nil }
        if let hit = cache[lookup], hit.expiresAt > .now { return hit.cast }

        let request: CastRequest
        if let pending = inFlight[lookup] {
            request = pending
        } else {
            request = CastRequest(task: Task { await self.fetchAndStore(title: name, lookup: lookup) })
            inFlight[lookup] = request
        }
        let cast = await request.task.value
        if inFlight[lookup]?.id == request.id { inFlight[lookup] = nil }
        return cast
    }

    private func fetchAndStore(title: String, lookup: Lookup) async -> SeriesCast? {
        do {
            let cast = try await fetch(title: title, lookup: lookup)
            guard !Task.isCancelled else { return nil }
            if cache.count >= 128 {
                cache = cache.filter { $0.value.expiresAt > .now }
                if cache.count >= 128, let oldest = cache.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
                    cache.removeValue(forKey: oldest)
                }
            }
            let ttl: TimeInterval = cast == nil ? 86_400 : 7 * 86_400
            cache[lookup] = Cached(cast: cast, expiresAt: .now.addingTimeInterval(ttl))
            return cast
        } catch {
            return nil
        }
    }

    private func fetch(title: String, lookup: Lookup) async throws -> SeriesCast? {
        let candidates: [SearchResult] = try await request("/search/shows", query: [URLQueryItem(name: "q", value: title)])
        let premierePrefix = "\(lookup.year)-"
        let exact = candidates.map(\.show).filter { show in
            show.id > 0 && TitleNormalizer.key(show.name) == lookup.name
                && show.premiered?.hasPrefix(premierePrefix) == true
        }
        guard exact.count == 1, let show = exact.first,
              let credit = show.url, Self.isTVmazePage(credit) else { return nil }

        let credits: [Credit] = try await request("/shows/\(show.id)/cast")
        var seen: Set<Int> = []
        var people: [SeriesCast.Person] = []
        for entry in credits {
            let person = entry.person
            guard let name = Self.nonEmpty(person.name), person.id > 0, seen.insert(person.id).inserted else { continue }
            let portrait = person.image?.medium.flatMap { $0.scheme == "https" && $0.host != nil ? $0 : nil }
            people.append(.init(id: person.id, name: name, role: Self.nonEmpty(entry.character?.name), portrait: portrait))
            if people.count == 16 { break }
        }
        return people.isEmpty ? nil : SeriesCast(people: people, creditURL: credit)
    }

    private func request<Value: Decodable>(_ path: String, query: [URLQueryItem]? = nil) async throws -> Value {
        try Task.checkCancellation()
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = query
        guard let url = components.url else { throw URLError(.badURL) }
        let (data, response) = try await client.data(
            for: url, headers: ["Accept": "application/json"], timeout: 4, retries: 0
        )
        guard (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func isTVmazePage(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host == "www.tvmaze.com" || url.host == "tvmaze.com" else { return false }
        return url.path.hasPrefix("/shows/")
    }

    private struct Lookup: Hashable {
        let name: String
        let year: Int
    }

    private struct Cached {
        let cast: SeriesCast?
        let expiresAt: Date
    }

    private struct SearchResult: Decodable {
        struct Show: Decodable {
            let id: Int
            let name: String
            let premiered: String?
            let url: URL?
        }
        let show: Show
    }

    private struct Credit: Decodable {
        struct Person: Decodable {
            let id: Int
            let name: String?
            let image: Image?
        }
        struct Character: Decodable {
            let name: String?
        }
        struct Image: Decodable {
            let medium: URL?
        }
        let person: Person
        let character: Character?
    }
}
