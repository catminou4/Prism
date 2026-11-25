import Foundation
import PrismCore
import PrismData
import Testing
@testable import PrismUI

/// Laziness of the raw per-source catalog decode after a built-catalog artifact hit.
///
/// The artifact-hit launch path must never decode the raw object graphs in a fresh-cache
/// session: settings metadata comes from the small cache meta segments, staleness from the
/// persisted source records, and the full decode waits for a semantic rebuild or a completed
/// refresh. These tests use local M3U file sources so no network is involved.
@MainActor
@Suite("Décodage paresseux des catalogues bruts")
struct LazyRawCatalogTests {
    private static let playlistA = """
        #EXTM3U
        #EXTINF:-1 tvg-type="movie" group-title="Films",Premier Contact (2016) VF
        https://example.invalid/movie/french.mp4
        #EXTINF:-1 tvg-type="movie" group-title="Films",Premier Contact (2016) VOSTFR
        https://example.invalid/movie/original.mp4
        #EXTINF:-1 tvg-type="live" group-title="Infos",Chaîne Info
        https://example.invalid/live/info.m3u8
        """

    private static let playlistB = """
        #EXTM3U
        #EXTINF:-1 tvg-type="movie" group-title="Films",Le Deuxième Film (2021)
        https://example.invalid/movie/second.mp4
        """

    private func makeEnvironment() throws -> (directories: AppDirectories, playlist: URL) {
        let directories = AppDirectories.temporary()
        let playlist = directories.root.appending(path: "playlist.m3u")
        try FileManager.default.createDirectory(at: directories.root, withIntermediateDirectories: true)
        try Self.playlistA.write(to: playlist, atomically: true, encoding: .utf8)
        return (directories, playlist)
    }

    private func cleanup(_ directories: AppDirectories) {
        try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent())
    }

    /// Imports the local playlist in a first model and waits for the background derived-artifact
    /// save, so later bootstraps take the artifact-hit path (verified by direct validation).
    private func importAndWaitForArtifact(directories: AppDirectories, playlist: URL) async throws -> Source {
        let model = AppModel(directories: directories, credentials: InMemoryCredentialStore(), library: .inMemory())
        let source = Source(name: "Playlist locale", kind: .m3uFile, serverURL: playlist)
        var last: ImportProgress?
        for try await update in model.importSource(source, password: nil) { last = update }
        #expect(last?.stage == .finished)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: directories.builtCatalogFile.path(percentEncoded: false)),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: directories.builtCatalogFile.path(percentEncoded: false)))
        return source
    }

    /// The build options an `AppModel` resolves in this process. `hideAdultContent` comes from
    /// `UserDefaults`, which test runs may have persisted either way — the artifact validation
    /// must use the same value the producing/consuming models see, whatever it is.
    private func appBuildOptions() -> CatalogBuildOptions {
        let probe = AppModel(directories: .temporary(), credentials: InMemoryCredentialStore(), library: .inMemory(), isEphemeral: true)
        return CatalogBuildOptions(hideAdult: probe.hideAdultContent)
    }

    private func artifactValidates(directories: AppDirectories) async -> Bool {
        let sources = SourceStore(directories: directories).load()
        guard !sources.isEmpty else { return false }
        return await BuiltCatalogCache(directories: directories).load(sources: sources, options: appBuildOptions()) != nil
    }

    @Test func artifactHitWithFreshCacheNeverDecodesRawCatalogs() async throws {
        let (directories, playlist) = try makeEnvironment()
        defer { cleanup(directories) }
        let source = try await importAndWaitForArtifact(directories: directories, playlist: playlist)
        #expect(await artifactValidates(directories: directories))

        let model = AppModel(directories: directories, credentials: InMemoryCredentialStore(), library: .inMemory())
        await model.bootstrap()
        #expect(model.phase == .ready)
        #expect(model.catalog.movies.count == 1)
        await model.bootstrapMaintenanceTask?.value
        // Let any wrongly spawned refresh reach its decode kick before asserting.
        try? await Task.sleep(for: .milliseconds(100))

        // Fresh cache: no refresh, no rebuild — the raw object graph is never decoded.
        #expect(model.rawCatalogDecodeWaves == 0)
        #expect(!model.isImportingAnything)
        // …while settings metadata is still complete, served by the cheap meta segments.
        #expect(!model.sourceCategories(for: source.id).isEmpty)
        #expect(model.catalog.movies.count == 1)
        #expect(model.catalog.movies.first?.variants.count == 2)
    }

    @Test func semanticRebuildDecodesExactlyOnceAndConcurrentRebuildsShareTheWave() async throws {
        let (directories, playlist) = try makeEnvironment()
        defer { cleanup(directories) }
        _ = try await importAndWaitForArtifact(directories: directories, playlist: playlist)
        #expect(await artifactValidates(directories: directories))

        let model = AppModel(directories: directories, credentials: InMemoryCredentialStore(), library: .inMemory())
        await model.bootstrap()
        await model.bootstrapMaintenanceTask?.value
        #expect(model.rawCatalogDecodeWaves == 0)

        // Three overlapping semantic rebuilds: the decode happens exactly once, shared.
        async let first: Void = model.rebuild()
        async let second: Void = model.rebuild()
        async let third: Void = model.rebuild()
        _ = await (first, second, third)

        #expect(model.rawCatalogDecodeWaves == 1)
        #expect(model.catalog.movies.count == 1)
        #expect(model.catalog.movies.first?.variants.count == 2)
        #expect(!model.catalog.channels.isEmpty)

        // Later rebuilds reuse the in-memory catalogs: still exactly one wave in the session.
        await model.rebuild()
        #expect(model.rawCatalogDecodeWaves == 1)
    }

    @Test func manualRefreshDecodesExactlyOnceAndRepublishes() async throws {
        let (directories, playlist) = try makeEnvironment()
        defer { cleanup(directories) }
        let source = try await importAndWaitForArtifact(directories: directories, playlist: playlist)
        #expect(await artifactValidates(directories: directories))

        let model = AppModel(directories: directories, credentials: InMemoryCredentialStore(), library: .inMemory())
        await model.bootstrap()
        await model.bootstrapMaintenanceTask?.value
        #expect(model.rawCatalogDecodeWaves == 0)
        let beforeRefresh = model.source(source.id)?.lastRefreshedAt

        await model.refresh(source.id)

        // The import kicked the shared decode (overlapping the refresh) and the rebuild after
        // it shared the same wave: exactly one decode in the session.
        #expect(model.rawCatalogDecodeWaves == 1)
        #expect(model.catalog.movies.count == 1)
        #expect(model.catalog.movies.first?.variants.count == 2)
        #expect(model.source(source.id)?.lastRefreshedAt != beforeRefresh)
    }

    @Test func missingCacheUnderArtifactHitIsRefreshedWithoutExtraDecodes() async throws {
        let directories = AppDirectories.temporary()
        defer { cleanup(directories) }
        try FileManager.default.createDirectory(at: directories.root, withIntermediateDirectories: true)
        let playlistA = directories.root.appending(path: "playlist-a.m3u")
        let playlistB = directories.root.appending(path: "playlist-b.m3u")
        try Self.playlistA.write(to: playlistA, atomically: true, encoding: .utf8)
        try Self.playlistB.write(to: playlistB, atomically: true, encoding: .utf8)

        // Import both sources so real caches exist, then delete B's cache and hand-craft the
        // artifact the app would have written had B never been imported: input fingerprint for
        // A, missing-input sentinel for B.
        let model1 = AppModel(directories: directories, credentials: InMemoryCredentialStore(), library: .inMemory())
        let sourceA = Source(name: "Source A", kind: .m3uFile, serverURL: playlistA)
        let sourceB = Source(name: "Source B", kind: .m3uFile, serverURL: playlistB)
        for try await _ in model1.importSource(sourceA, password: nil) {}
        for try await _ in model1.importSource(sourceB, password: nil) {}
        let artifactDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: directories.builtCatalogFile.path(percentEncoded: false)),
              ContinuousClock.now < artifactDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let sources = SourceStore(directories: directories).load()
        #expect(sources.map(\.id) == [sourceA.id, sourceB.id])
        let catalogCache = CatalogCache(directories: directories)
        let catalogA = try #require(await catalogCache.load(sourceA.id))
        try FileManager.default.removeItem(at: directories.builtCatalogFile)
        try FileManager.default.removeItem(at: directories.catalogCacheFile(for: sourceB.id))

        let options = appBuildOptions()
        let built = await CatalogBuilder.build(sources: sources, catalogs: [catalogA], options: options)
        await BuiltCatalogCache(directories: directories).save(
            catalog: built, sources: sources, catalogs: [catalogA], options: options,
            generation: UInt64(max(0, Date.now.timeIntervalSince1970) * 1_000_000) &+ 1_000_000_000
        )
        #expect(await artifactValidates(directories: directories))
        let persistedRefreshedAt = try #require(SourceStore(directories: directories).load().first { $0.id == sourceA.id }?.lastRefreshedAt)

        let model = AppModel(directories: directories, credentials: InMemoryCredentialStore(), library: .inMemory())
        await model.bootstrap()
        #expect(model.catalog.movies.count == 1) // A's content published from the artifact alone
        await model.bootstrapMaintenanceTask?.value

        // B has no readable cache meta: stale, refreshed automatically (local file, offline-OK).
        // A is fresh and must not be refreshed.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.catalog.movies.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.catalog.movies.count == 2)
        // B's import overlapped exactly one decode wave (A's raw catalog), shared by its rebuild.
        #expect(model.rawCatalogDecodeWaves == 1)
        #expect(model.source(sourceA.id)?.lastRefreshedAt == persistedRefreshedAt)
        #expect(model.source(sourceB.id)?.lastRefreshedAt != nil)
    }
}
