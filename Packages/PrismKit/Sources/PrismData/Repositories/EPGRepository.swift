import Foundation
import PrismCore

/// XMLTV guide download, parsing and per-source caching, plus the Xtream short-EPG fallback.
public actor EPGRepository {
    public nonisolated let directories: AppDirectories
    public nonisolated let cache: EPGCache
    nonisolated let credentials: any CredentialStoring
    nonisolated let session: URLSession
    private var guides: [SourceID: EPGGuide] = [:]
    private var fetchedAt: [SourceID: Date] = [:]

    /// Programmes kept around "now" (the XMLTV of large providers covers weeks).
    public static let pastWindow: TimeInterval = 2 * 86_400
    public static let futureWindow: TimeInterval = 4 * 86_400

    public init(directories: AppDirectories, credentials: any CredentialStoring, session: URLSession = PrismURLSession.shared) {
        self.directories = directories
        self.credentials = credentials
        self.session = session
        self.cache = EPGCache(directories: directories)
    }

    /// Merged guide of every enabled source from the disk caches (source order = priority).
    public func cachedGuide(for sources: [Source]) async -> EPGGuide {
        let cache = self.cache
        let loaded = await withTaskGroup(of: (Int, SourceID, EPGGuide?, Date?).self) { group in
            for (index, source) in sources.enumerated() where source.isEnabled {
                group.addTask {
                    if let entry = await cache.load(source.id) {
                        return (index, source.id, await Self.makeGuide(entry.programs, channels: entry.channels), entry.fetchedAt)
                    }
                    if DemoContent.isDemo(source) { return (index, source.id, DemoContent.makeGuide(), nil) }
                    return (index, source.id, nil, nil)
                }
            }
            var results: [(Int, SourceID, EPGGuide?, Date?)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }
        var merged = EPGGuide.empty
        for (_, id, guide, date) in loaded {
            guard let guide else { continue }
            guides[id] = guide
            if let date { fetchedAt[id] = date }
            merged = merged.merging(guide)
        }
        return merged
    }

    /// Merged in-memory guide of the given sources (after `cachedGuide` / `refresh`).
    public func currentGuide(for sources: [Source]) -> EPGGuide {
        sources.filter(\.isEnabled).compactMap { guides[$0.id] }.reduce(EPGGuide.empty) { $0.merging($1) }
    }

    /// When the guide of a source was last downloaded.
    public func lastFetched(_ id: SourceID) async -> Date? {
        if let date = fetchedAt[id] { return date }
        return await cache.load(id)?.fetchedAt
    }

    /// XMLTV URL of a source: explicit `epgURL`, else Xtream `xmltv.php`, else the playlist header.
    public nonisolated func guideURLs(for source: Source, playlistEPGURLs: [URL]) -> [URL] {
        if let explicit = source.epgURL { return [explicit] }
        if source.kind == .xtream, let credentials = xtreamCredentials(for: source) {
            return [XtreamURLBuilder.xmltv(credentials)]
        }
        return Array(playlistEPGURLs.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }.prefix(3))
    }

    /// Downloads and caches the guide around the current time, including two days of replay when available.
    /// Returns this source's guide.
    public func refresh(_ source: Source, playlistEPGURLs: [URL]) async throws -> EPGGuide {
        if DemoContent.isDemo(source) {
            let guide = DemoContent.makeGuide()
            guides[source.id] = guide
            fetchedAt[source.id] = .now
            return guide
        }
        let urls = guideURLs(for: source, playlistEPGURLs: playlistEPGURLs)
        guard !urls.isEmpty else { throw SourceError.noGuide }
        let now = Date.now
        let window = DateInterval(start: now.addingTimeInterval(-Self.pastWindow), end: now.addingTimeInterval(Self.futureWindow))
        let http = HTTPClient(session: session, userAgent: source.userAgent)

        var programs: [EPGProgram] = []
        var channels: [XMLTVChannel] = []
        var firstError: (any Error)?
        for url in urls {
            do {
                let (data, response) = try await http.data(for: url, timeout: 120, retries: 1)
                try SourceError.check(status: response.statusCode)
                let document = try await Self.parse(data, window: window, timeShift: source.epgTimeShiftHours)
                programs += document.programs
                channels += document.channels
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                firstError = firstError ?? SourceError.from(error)
            } catch {
                firstError = firstError ?? error
            }
        }
        if programs.isEmpty, channels.isEmpty, let firstError { throw firstError }

        let entry = EPGCache.Entry(programs: programs, channels: channels, fetchedAt: now)
        try? await cache.save(entry, for: source.id)
        let guide = await Self.makeGuide(programs, channels: channels)
        guides[source.id] = guide
        fetchedAt[source.id] = now
        return guide
    }

    /// Short EPG from the Xtream API, used when no XMLTV data matches a channel.
    public func shortEPG(for channel: Channel, source: Source, limit: Int = 12) async throws -> [EPGProgram] {
        guard source.kind == .xtream, let credentials = xtreamCredentials(for: source) else { return [] }
        let client = XtreamClient(credentials: credentials, sourceID: source.id, userAgent: source.userAgent, session: session)
        let programs = try await client.shortEPG(streamID: channel.nativeID, epgChannelID: channel.epgID, limit: limit)
        return programs.map { program in
            guard source.epgTimeShiftHours != 0 else { return program }
            var shifted = program
            shifted.start = program.start.addingTimeInterval(source.epgTimeShiftHours * 3_600)
            shifted.end = program.end.addingTimeInterval(source.epgTimeShiftHours * 3_600)
            return shifted
        }
    }

    /// Drops the cached guide of a deleted source.
    public func forget(_ id: SourceID) async {
        guides[id] = nil
        fetchedAt[id] = nil
        await cache.remove(id)
    }

    // MARK: - Helpers

    private nonisolated func xtreamCredentials(for source: Source) -> XtreamCredentials? {
        guard let serverText = source.serverURL?.absoluteString, let server = XtreamCredentials.normalizeServer(serverText),
              let username = source.username, !username.isEmpty,
              let password = credentials.password(for: source.id), !password.isEmpty else { return nil }
        return XtreamCredentials(server: server, username: username, password: password)
    }

    @concurrent
    static func parse(_ data: Data, window: DateInterval, timeShift: Double) async throws -> XMLTVDocument {
        do {
            return try XMLTVParser.parse(data, window: window, timeShiftHours: timeShift)
        } catch {
            throw SourceError.invalidGuide
        }
    }

    @concurrent
    static func makeGuide(_ programs: [EPGProgram], channels: [XMLTVChannel]) async -> EPGGuide {
        EPGGuide(programs: programs, channels: channels)
    }
}
