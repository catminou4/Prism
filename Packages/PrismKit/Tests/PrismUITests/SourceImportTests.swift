import Foundation
import PrismCore
import PrismData
import Testing
@testable import PrismUI

@MainActor
@Suite("Ajout d’une source")
struct SourceImportTests {
    @Test func localPlaylistIsAvailableWhenImportFinishes() async throws {
        let directories = AppDirectories.temporary()
        let playlist = directories.root.appending(path: "playlist.m3u")
        try FileManager.default.createDirectory(at: directories.root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }

        try """
            #EXTM3U
            #EXTINF:-1 tvg-type="movie" group-title="Films",Premier Contact (2016) VF
            https://example.invalid/movie/french.mp4
            #EXTINF:-1 tvg-type="movie" group-title="Films",Premier Contact (2016) VOSTFR
            https://example.invalid/movie/original.mp4
            """.write(to: playlist, atomically: true, encoding: .utf8)

        let credentials = InMemoryCredentialStore()
        let model = AppModel(directories: directories, credentials: credentials, library: .inMemory())
        let source = Source(name: "Playlist locale", kind: .m3uFile, serverURL: playlist)
        var last: ImportProgress?
        for try await update in model.importSource(source, password: nil) { last = update }

        #expect(last?.stage == .finished)
        #expect(last?.counts.movies == 2)
        #expect(model.source(source.id)?.lastRefreshedAt != nil)
        #expect(SourceStore(directories: directories).load().map(\.id) == [source.id])
        #expect(model.catalog.movies.count == 1)
        #expect(model.catalog.movies.first?.variants.count == 2)
        #expect(model.searchIndex?.search("premier contact").movies.count == 1)
        #expect(model.imports.isEmpty)
    }

    @Test func failedNewSourceDoesNotStayInTheLibrary() async {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let credentials = InMemoryCredentialStore()
        let model = AppModel(directories: directories, credentials: credentials, library: .inMemory())
        let source = Source(name: "Adresse manquante", kind: .xtream, username: "test")
        var failure: (any Error)?
        do {
            for try await _ in model.importSource(source, password: "mot de passe factice") {}
        } catch {
            failure = error
        }

        #expect(failure != nil)
        #expect(model.source(source.id) == nil)
        #expect(SourceStore(directories: directories).load().isEmpty)
        #expect(credentials.password(for: source.id) == nil)
        #expect(model.imports.isEmpty)
    }

    @Test func overlappingRebuildsPublishSearchForTheLatestCatalog() async throws {
        let model = await AppModel.preview()
        let source = try #require(model.sources.first)
        let prior = Task { await model.rebuild() }
        await Task.yield()

        model.setEnabled(false, for: source.id)
        await model.rebuild()
        await prior.value

        #expect(model.catalog.source(source.id) == nil)
        #expect(model.searchIndex?.entryCount == model.catalog.channels.count + model.catalog.movies.count + model.catalog.series.count)
    }
}
