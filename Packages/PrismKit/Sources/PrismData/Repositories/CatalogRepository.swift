import Foundation
import Synchronization
import PrismCore

/// Loads source catalogs from the disk cache and refreshes them from the network / local files.
public actor CatalogRepository {
    public nonisolated let directories: AppDirectories
    public nonisolated let cache: CatalogCache
    nonisolated let credentials: any CredentialStoring
    nonisolated let session: URLSession
    private var lastCatalogs: [SourceID: SourceCatalog] = [:]

    public init(directories: AppDirectories, credentials: any CredentialStoring, cache: CatalogCache, session: URLSession = PrismURLSession.shared) {
        self.directories = directories
        self.credentials = credentials
        self.cache = cache
        self.session = session
    }

    // MARK: - Cache

    /// Cached catalogs in source order. Decode one source at a time to bound launch memory.
    public func cachedCatalogs(for sources: [Source]) async -> [SourceCatalog] {
        var loaded: [SourceCatalog] = []
        for source in sources {
            guard !Task.isCancelled else { return [] }
            if DemoContent.isDemo(source) {
                loaded.append(DemoContent.makeCatalog())
            } else if let catalog = await cache.load(source.id) {
                loaded.append(catalog)
            }
        }
        for catalog in loaded where lastCatalogs[catalog.sourceID] == nil {
            lastCatalogs[catalog.sourceID] = catalog
        }
        return loaded
    }

    /// The most recent catalog refreshed or loaded for `id` during this session.
    public func lastRefreshed(_ id: SourceID) -> SourceCatalog? {
        lastCatalogs[id]
    }

    /// Removes the cached catalog and metadata of a deleted source.
    public func forget(_ id: SourceID) async {
        lastCatalogs[id] = nil
        await cache.remove(id)
        try? FileManager.default.removeItem(at: playlistMetaFile(id))
    }

    /// XMLTV URLs announced by the last imported playlist of this source (`url-tvg`).
    public nonisolated func playlistEPGURLs(for id: SourceID) -> [URL] {
        guard let data = try? Data(contentsOf: playlistMetaFile(id)),
              let strings = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return strings.compactMap(URL.init(string:))
    }

    private nonisolated func playlistMetaFile(_ id: SourceID) -> URL {
        AppDirectories.ensure(directories.caches.appending(path: "Catalogs", directoryHint: .isDirectory))
            .appending(path: SafeFileName.make(id.rawValue) + ".epg-urls.json", directoryHint: .notDirectory)
    }

    private nonisolated func savePlaylistEPGURLs(_ urls: [URL], for id: SourceID) {
        guard let data = try? JSONEncoder().encode(urls.map(\.absoluteString)) else { return }
        try? data.write(to: playlistMetaFile(id), options: [.atomic])
    }

    // MARK: - Credentials

    /// Xtream credentials of a source (password from the credential store unless given).
    public nonisolated func xtreamCredentials(for source: Source, password: String? = nil) -> XtreamCredentials? {
        guard source.kind == .xtream,
              let serverText = source.serverURL?.absoluteString, let server = XtreamCredentials.normalizeServer(serverText),
              let username = source.username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty,
              let password = password ?? credentials.password(for: source.id), !password.isEmpty else { return nil }
        return XtreamCredentials(server: server, username: username, password: password)
    }

    // MARK: - Refresh

    /// Imports a source. Elements report progress; the last one has stage `.finished` and carries the
    /// catalog (also saved to the cache). Cancelling the consuming task cancels the import.
    public nonisolated func refresh(_ source: Source) -> AsyncThrowingStream<ImportProgress, any Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    var (catalog, epgURLs) = try await self.performRefresh(source) { continuation.yield($0) }
                    try Task.checkCancellation()
                    catalog.shareRepeatedValues()
                    if !DemoContent.isDemo(source) {
                        do {
                            try await self.cache.save(catalog)
                        } catch {
                            // A cache write failure must not fail the import.
                        }
                        self.savePlaylistEPGURLs(epgURLs, for: source.id)
                    }
                    await self.remember(catalog)
                    continuation.yield(ImportProgress(stage: .finished, counts: ImportCounts(catalog), fraction: 1, catalog: catalog, epgURLs: epgURLs))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func remember(_ catalog: SourceCatalog) {
        lastCatalogs[catalog.sourceID] = catalog
    }

    typealias Reporter = @Sendable (ImportProgress) -> Void

    private nonisolated func performRefresh(_ source: Source, report: @escaping Reporter) async throws -> (SourceCatalog, [URL]) {
        if DemoContent.isDemo(source) {
            report(ImportProgress(stage: .connecting, fraction: 0.1))
            let catalog = DemoContent.makeCatalog()
            reportCounts(catalog, report: report)
            return (catalog, [])
        }
        switch source.kind {
        case .xtream:
            return (try await refreshXtream(source, report: report), [])
        case .m3uURL:
            guard let url = source.serverURL else { throw SourceError.missingURL }
            if url.isFileURL {
                return try await refreshLocalFile(source, url: url, report: report)
            }
            report(ImportProgress(stage: .connecting, fraction: 0.02))
            let data = try await download(url, userAgent: source.userAgent, report: report)
            return try await finishPlaylist(data, source: source, report: report)
        case .m3uFile:
            return try await refreshLocalFile(source, url: nil, report: report)
        }
    }

    private nonisolated func reportCounts(_ catalog: SourceCatalog, report: Reporter) {
        var counts = ImportCounts()
        counts.channels = catalog.channels.count
        report(ImportProgress(stage: .channels(counts.channels), counts: counts, fraction: 0.9))
        counts.movies = catalog.movies.count
        report(ImportProgress(stage: .movies(counts.movies), counts: counts, fraction: 0.93))
        counts.series = catalog.series.count
        report(ImportProgress(stage: .series(counts.series), counts: counts, fraction: 0.96))
    }

    // MARK: Xtream

    private enum XtreamList: Sendable {
        case channels([Channel])
        case movies([Movie])
        case series([Series])
        case failed(MediaKind, any Error)
    }

    private nonisolated func refreshXtream(_ source: Source, report: Reporter) async throws -> SourceCatalog {
        guard let credentials = xtreamCredentials(for: source) else { throw SourceError.missingCredentials }
        let client = XtreamClient(credentials: credentials, sourceID: source.id, userAgent: source.userAgent, session: session)
        report(ImportProgress(stage: .connecting, fraction: 0.02))
        let account = try await client.authenticate()
        report(ImportProgress(stage: .account(account), fraction: 0.1))

        // Categories are small but their fetch used to sit serially in front of the giant
        // lists: run both passes concurrently. The list endpoints only need the adult-ID
        // sets (which join these same in-flight fetches inside the client), so nothing
        // waits on the category responses before the list GETs start.
        async let liveCategories = try? client.categories(.live)
        async let movieCategories = try? client.categories(.movie)
        async let seriesCategories = try? client.categories(.series)
        try Task.checkCancellation()
        report(ImportProgress(stage: .downloading(fraction: nil), fraction: 0.2))

        let preferHLS = source.preferHLSForLive
        var catalog = SourceCatalog(sourceID: source.id, categories: [], account: account, fetchedAt: .now)
        var counts = ImportCounts()
        var failures: [(kind: MediaKind, error: any Error)] = []
        try await withThrowingTaskGroup(of: XtreamList.self) { group in
            group.addTask {
                do { return .channels(try await client.liveStreams(preferHLS: preferHLS, account: account)) } catch { return .failed(.live, error) }
            }
            group.addTask {
                do { return .movies(try await client.vodStreams()) } catch { return .failed(.movie, error) }
            }
            group.addTask {
                do { return .series(try await client.series()) } catch { return .failed(.series, error) }
            }
            var completed = 0
            for try await result in group {
                completed += 1
                let fraction = 0.2 + 0.25 * Double(completed)
                switch result {
                case .channels(let channels):
                    catalog.channels = channels
                    counts.channels = channels.count
                    report(ImportProgress(stage: .channels(channels.count), counts: counts, fraction: fraction))
                case .movies(let movies):
                    catalog.movies = movies
                    counts.movies = movies.count
                    report(ImportProgress(stage: .movies(movies.count), counts: counts, fraction: fraction))
                case .series(let series):
                    catalog.series = series
                    counts.series = series.count
                    report(ImportProgress(stage: .series(series.count), counts: counts, fraction: fraction))
                case .failed(let kind, let error):
                    if error is CancellationError { throw error }
                    failures.append((kind, error))
                }
            }
        }
        try Task.checkCancellation()
        // The category fetches ran concurrently with the lists; collect them now (they are
        // long done — the lists are the slow pole).
        let fetchedCategories = await (live: liveCategories, movie: movieCategories, series: seriesCategories)
        let categories = (fetchedCategories.live ?? []) + (fetchedCategories.movie ?? []) + (fetchedCategories.series ?? [])
        var failedCategoryKinds: Set<MediaKind> = []
        if fetchedCategories.live == nil { failedCategoryKinds.insert(.live) }
        if fetchedCategories.movie == nil { failedCategoryKinds.insert(.movie) }
        if fetchedCategories.series == nil { failedCategoryKinds.insert(.series) }
        catalog.categories = categories
        // Panels often fail on one endpoint: keep what worked, fail only when everything failed.
        if failures.count == 3, let first = failures.first { throw first.error }
        // A list or category endpoint that failed this time keeps its previous content instead of
        // wiping it from the UI and from the cache until the next fully successful refresh.
        let stale = Set(failures.map(\.kind)).union(failedCategoryKinds)
        if !stale.isEmpty, let previous = await previousCatalog(source.id) {
            catalog.merge(kinds: stale, from: previous, listsOnly: Set(failures.map(\.kind)))
        }
        return catalog
    }

    private func previousCatalog(_ id: SourceID) async -> SourceCatalog? {
        if let last = lastCatalogs[id] { return last }
        return await cache.load(id)
    }

    // MARK: M3U

    private nonisolated func download(_ url: URL, userAgent: String?, report: @escaping Reporter) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue(Self.userAgent(userAgent), forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        report(ImportProgress(stage: .downloading(fraction: nil), fraction: 0.05))
        // URLSession accumulates the body natively; iterating `AsyncBytes` byte by byte costs
        // seconds of CPU on 100 MB playlists. Progress comes from the task's byte counters.
        let observer = TransferObserver { received, expected in
            let fraction = expected > 0 ? min(Double(received) / Double(expected), 1) : nil
            report(ImportProgress(stage: .downloading(fraction: fraction), fraction: 0.05 + 0.6 * (fraction ?? 0.5)))
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: observer)
        } catch let error as URLError {
            throw SourceError.from(error)
        }
        observer.invalidate()
        if let http = response as? HTTPURLResponse { try SourceError.check(status: http.statusCode) }
        report(ImportProgress(stage: .downloading(fraction: 1), fraction: 0.65))
        return data
    }

    private nonisolated func refreshLocalFile(_ source: Source, url: URL?, report: Reporter) async throws -> (SourceCatalog, [URL]) {
        report(ImportProgress(stage: .connecting, fraction: 0.02))
        let data = try await Self.readLocalPlaylist(bookmark: source.fileBookmark, fallbackURL: url ?? source.serverURL)
        report(ImportProgress(stage: .downloading(fraction: 1), fraction: 0.5))
        return try await finishPlaylist(data, source: source, report: report)
    }

    private nonisolated func finishPlaylist(_ data: Data, source: Source, report: Reporter) async throws -> (SourceCatalog, [URL]) {
        try Task.checkCancellation()
        report(ImportProgress(stage: .parsing, fraction: 0.7))
        let (catalog, epgURLs) = try await Self.parsePlaylist(data, sourceID: source.id)
        reportCounts(catalog, report: report)
        return (catalog, epgURLs)
    }

    @concurrent
    static func parsePlaylist(_ data: Data, sourceID: SourceID) async throws -> (SourceCatalog, [URL]) {
        // Local `.gz` files or broken servers can deliver gzip without Content-Encoding:
        // URLSession only decompresses when the header is present. A failed inflate falls
        // back to the raw bytes, preserving the previous notAPlaylist error.
        let bytes = Gzip.isCompressed(data) ? (try? Gzip.decompress(data)) ?? data : data
        guard looksLikePlaylist(bytes.prefix(8_192)) else { throw SourceError.notAPlaylist }
        let playlist = M3UParser.parse(bytes)
        guard !playlist.entries.isEmpty else { throw SourceError.emptyPlaylist }
        try Task.checkCancellation()
        let catalog = M3UCatalogMapper.makeCatalog(from: playlist, sourceID: sourceID, now: .now)
        guard !(catalog.channels.isEmpty && catalog.movies.isEmpty && catalog.series.isEmpty) else { throw SourceError.emptyPlaylist }
        return (catalog, playlist.epgURLs)
    }

    /// `#EXTM3U` / `#EXTINF` near the start (after an optional BOM / whitespace).
    static func looksLikePlaylist(_ prefix: Data) -> Bool {
        let text = String(decoding: prefix, as: UTF8.self).uppercased()
        return text.contains("#EXTM3U") || text.contains("#EXTINF")
    }

    @concurrent
    static func readLocalPlaylist(bookmark: Data?, fallbackURL: URL?) async throws -> Data {
        var url: URL?
        if let bookmark {
            var stale = false
            url = (try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale))
                ?? (try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
        }
        if url == nil, let fallbackURL, fallbackURL.isFileURL { url = fallbackURL }
        guard let url else { throw bookmark == nil ? SourceError.missingFile : SourceError.fileAccessDenied }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { throw SourceError.missingFile }
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw SourceError.fileAccessDenied
        }
    }

    static func userAgent(_ custom: String?) -> String {
        let trimmed = custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? HTTPClient.defaultUserAgent : trimmed
    }

    // MARK: - Validation

    /// Quick check used by the "add source" form: Xtream authentication, M3U header sniffing, file access.
    public func validate(_ source: Source, password: String?) async throws -> SourceValidation {
        if DemoContent.isDemo(source) {
            return SourceValidation(sampleCounts: ImportCounts(DemoContent.makeCatalog()))
        }
        switch source.kind {
        case .xtream:
            guard source.serverURL.flatMap({ XtreamCredentials.normalizeServer($0.absoluteString) }) != nil else { throw XtreamError.invalidServer }
            guard let credentials = xtreamCredentials(for: source, password: password) else { throw SourceError.missingCredentials }
            let client = XtreamClient(credentials: credentials, sourceID: source.id, userAgent: source.userAgent, session: session)
            return SourceValidation(account: try await client.authenticate())
        case .m3uURL:
            guard let url = source.serverURL, ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { throw SourceError.missingURL }
            var prefix: Data
            if url.isFileURL {
                prefix = try await Self.readLocalPlaylist(bookmark: nil, fallbackURL: url).prefix(8_192)
                if Gzip.isCompressed(prefix), let inflated = try? Gzip.decompress(prefix) { prefix = inflated }
            } else {
                prefix = try await sniff(url, userAgent: source.userAgent)
            }
            guard Self.looksLikePlaylist(prefix) else { throw SourceError.notAPlaylist }
            return SourceValidation()
        case .m3uFile:
            var data = try await Self.readLocalPlaylist(bookmark: source.fileBookmark, fallbackURL: source.serverURL)
            if Gzip.isCompressed(data), let inflated = try? Gzip.decompress(data) { data = inflated }
            guard Self.looksLikePlaylist(data.prefix(8_192)) else { throw SourceError.notAPlaylist }
            let (catalog, _) = try await Self.parsePlaylist(data, sourceID: source.id)
            return SourceValidation(sampleCounts: ImportCounts(catalog))
        }
    }

    /// First bytes of a remote playlist.
    private nonisolated func sniff(_ url: URL, userAgent: String?) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(Self.userAgent(userAgent), forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-8191", forHTTPHeaderField: "Range")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse { try SourceError.check(status: http.statusCode) }
            var prefix = Data()
            prefix.reserveCapacity(8_192)
            for try await byte in bytes {
                prefix.append(byte)
                if prefix.count >= 8_192 { break }
            }
            bytes.task.cancel()
            // Gzipped playlists decompress partially from the first chunk: enough to see
            // the #EXTM3U header a few KB in.
            if Gzip.isCompressed(prefix), let inflated = try? Gzip.decompress(prefix) {
                prefix = inflated
            }
            return prefix
        } catch let error as URLError {
            throw SourceError.from(error)
        }
    }
}

extension SourceCatalog {
    /// Restores the categories of `kinds` from `previous`, and their item lists for `listsOnly`.
    /// Categories are restored only when this refresh brought none for that kind.
    mutating func merge(kinds: Set<MediaKind>, from previous: SourceCatalog, listsOnly: Set<MediaKind>) {
        for kind in kinds where !categories.contains(where: { $0.kind == kind }) {
            categories += previous.categories.filter { $0.kind == kind }
        }
        if listsOnly.contains(.live), channels.isEmpty { channels = previous.channels }
        if listsOnly.contains(.movie), movies.isEmpty { movies = previous.movies }
        if listsOnly.contains(.series), series.isEmpty { series = previous.series }
    }
}

/// Reports download progress of an async `URLSession` call, at most every 512 KB.
private final class TransferObserver: NSObject, URLSessionTaskDelegate, Sendable {
    private struct State {
        var observation: NSKeyValueObservation?
        var lastReported: Int64 = 0
    }

    private let state = Mutex(State())
    private let onProgress: @Sendable (_ received: Int64, _ expected: Int64) -> Void

    init(onProgress: @escaping @Sendable (_ received: Int64, _ expected: Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let observation = task.observe(\.countOfBytesReceived, options: [.new]) { [weak self] task, _ in
            self?.received(task.countOfBytesReceived, of: task.countOfBytesExpectedToReceive)
        }
        state.withLock { $0.observation = observation }
    }

    private func received(_ received: Int64, of expected: Int64) {
        let shouldReport = state.withLock { state -> Bool in
            guard received - state.lastReported >= 1 << 19 else { return false }
            state.lastReported = received
            return true
        }
        if shouldReport { onProgress(received, expected) }
    }

    func invalidate() {
        let observation = state.withLock { state -> NSKeyValueObservation? in
            defer { state.observation = nil }
            return state.observation
        }
        observation?.invalidate()
    }
}
