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
    /// One refresh per source at a time: concurrent callers (guide screen, sports page, import)
    /// share the same download/parse cycle instead of duplicating it.
    private var refreshes: [SourceID: GuideRequest] = [:]

    private struct GuideRequest {
        let id = UUID()
        let task: Task<EPGGuide, any Error>
    }

    private enum FeedDownload: Sendable {
        case success(XMLTVDocument)
        case failure(any Error)
    }

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
        var ordered: [EPGGuide] = []
        for source in sources where source.isEnabled {
            guard !Task.isCancelled else { return .empty }
            if let entry = await cache.load(source.id) {
                let guide = await Self.makeGuide(entry.programs, channels: entry.channels)
                guides[source.id] = guide
                fetchedAt[source.id] = entry.fetchedAt
                ordered.append(guide)
            } else if DemoContent.isDemo(source) {
                let guide = DemoContent.makeGuide()
                guides[source.id] = guide
                ordered.append(guide)
            }
        }
        return await Self.merge(ordered)
    }

    /// Off the actor: building the merged name index normalizes every channel name.
    @concurrent private static func merge(_ guides: [EPGGuide]) async -> EPGGuide {
        EPGGuide.merged(guides)
    }

    /// Merged in-memory guide of the given sources (after `cachedGuide` / `refresh`).
    public func currentGuide(for sources: [Source]) async -> EPGGuide {
        await Self.merge(sources.filter(\.isEnabled).compactMap { guides[$0.id] })
    }

    /// When the guide of a source was last downloaded (archive header only — never decodes
    /// the programme segments).
    public func lastFetched(_ id: SourceID) async -> Date? {
        if let date = fetchedAt[id] { return date }
        return await cache.fetchedAt(id)
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
    /// Returns this source's guide. Concurrent calls for the same source share one refresh.
    public func refresh(_ source: Source, playlistEPGURLs: [URL]) async throws -> EPGGuide {
        if DemoContent.isDemo(source) {
            let guide = DemoContent.makeGuide()
            guides[source.id] = guide
            fetchedAt[source.id] = .now
            return guide
        }
        let request: GuideRequest
        if let pending = refreshes[source.id] {
            request = pending
        } else {
            request = GuideRequest(task: Task { try await self.performRefresh(source, playlistEPGURLs: playlistEPGURLs) })
            refreshes[source.id] = request
        }
        defer {
            if refreshes[source.id]?.id == request.id { refreshes[source.id] = nil }
        }
        return try await request.task.value
    }

    private func performRefresh(_ source: Source, playlistEPGURLs: [URL]) async throws -> EPGGuide {
        let urls = guideURLs(for: source, playlistEPGURLs: playlistEPGURLs)
        guard !urls.isEmpty else { throw SourceError.noGuide }
        let now = Date.now
        let window = DateInterval(start: now.addingTimeInterval(-Self.pastWindow), end: now.addingTimeInterval(Self.futureWindow))
        let timeShift = source.epgTimeShiftHours
        let http = HTTPClient(session: session, userAgent: source.userAgent)

        // Up to three feeds (explicit / Xtream XMLTV / playlist headers): download and parse
        // them concurrently, then merge in URL order so earlier feeds win same-start
        // conflicts, exactly like the previous sequential loop.
        let results = await withTaskGroup(of: (Int, FeedDownload).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    do {
                        let (data, response) = try await http.data(for: url, timeout: 120, retries: 1)
                        try SourceError.check(status: response.statusCode)
                        let document = try await Self.parse(data, window: window, timeShift: timeShift)
                        return (index, .success(document))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var collected: [(Int, FeedDownload)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }
        }
        try Task.checkCancellation()

        var programs: [EPGProgram] = []
        var channels: [XMLTVChannel] = []
        var firstError: (any Error)?
        for (_, result) in results {
            switch result {
            case .success(let document):
                programs += document.programs
                channels += document.channels
            case .failure(let error):
                if error is CancellationError { throw CancellationError() }
                if let urlError = error as? URLError {
                    if urlError.code == .cancelled { throw CancellationError() }
                    firstError = firstError ?? SourceError.from(urlError)
                } else {
                    firstError = firstError ?? error
                }
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

    /// Drops the cached guide of a deleted source (and cancels its refresh if still running).
    public func forget(_ id: SourceID) async {
        guides[id] = nil
        fetchedAt[id] = nil
        refreshes[id]?.task.cancel()
        refreshes[id] = nil
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
