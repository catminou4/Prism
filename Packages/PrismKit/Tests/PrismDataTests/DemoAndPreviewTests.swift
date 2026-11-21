import Foundation
import PrismCore
import Testing
@testable import PrismData

@Suite("Demo & preview data")
struct DemoAndPreviewTests {
    @Test func demoCatalogIsConsistent() async {
        let sources = DemoContent.makeSources()
        let catalogs = DemoContent.makeCatalogs()
        #expect(sources.count == 1)
        #expect(sources[0].id == DemoContent.sourceID)
        #expect(sources[0].serverURL?.scheme == DemoContent.scheme)
        #expect(DemoContent.isDemo(sources[0]))
        let raw = catalogs[0]
        #expect(raw.channels.count == 11, "every channel URL parses (TV5Monde has parentheses)")
        #expect(raw.movies.count == 10)
        #expect(raw.series.count == 1)
        #expect(raw.series[0].seasons?.count == 2)
        for url in raw.channels.map(\.streamURL) + raw.movies.map(\.streamURL) {
            #expect(url.scheme == "https", "ATS-friendly stream URL: \(url)")
        }
        for movie in raw.movies {
            #expect(movie.plot?.isEmpty == false)
            #expect(movie.durationSeconds ?? 0 > 0)
            #expect(raw.categories.contains { $0.id == movie.categoryID })
        }
        let catalog = await CatalogBuilder.build(sources: sources, catalogs: catalogs)
        #expect(catalog.movies.count == raw.movies.count - 2, "Big Buck Bunny and Tears of Steel have two variants each")
        let bunny = catalog.movies.first { $0.title == "Big Buck Bunny" }
        #expect(bunny?.variants.map(\.quality) == [.fhd, .sd])
        #expect(catalog.movies.allSatisfy { $0.posterURL != nil && $0.backdropURL != nil })
        #expect(catalog.series.first?.posterURL != nil)
        #expect(catalog.featured(limit: 3).allSatisfy { $0.backdropURL != nil })
        let guide = DemoContent.makeGuide()
        #expect(guide.channelCount == raw.channels.count)
        for group in catalog.channels {
            #expect(guide.nowAndNext(forEPGID: guide.resolveEPGID(for: group) ?? "-", at: .now).now != nil)
        }
    }

    @Test func builtInDemoIgnoresItsOlderDiskSnapshot() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let source = DemoContent.makeSource()
        let cache = CatalogCache(directories: directories)
        try await cache.save(SourceCatalog(sourceID: source.id))

        let repository = CatalogRepository(directories: directories, credentials: InMemoryCredentialStore(), cache: cache)
        let catalogs = await repository.cachedCatalogs(for: [source])
        let catalog = try #require(catalogs.first)
        #expect(catalog.movies.contains { $0.nativeID == "agent-327" && $0.posterURL != nil })
    }

    @Test func previewDataIsRichAndDeterministic() async {
        #expect(PreviewData.sources.map(\.kind) == [.xtream, .m3uURL, .m3uURL])
        let catalog = await PreviewData.catalog()
        let again = await PreviewData.catalog()
        #expect(catalog.movies.map(\.id) == again.movies.map(\.id))
        #expect(catalog.channels.count >= 40)
        #expect(catalog.liveCategories.map(\.name).prefix(6) == ["Généralistes", "Info", "Sport", "Cinéma", "Jeunesse", "Documentaires"])
        #expect(catalog.movies.count >= 55)
        #expect(catalog.series.count >= 18)
        let multi = catalog.movies.filter { $0.variants.count >= 3 }
        #expect(!multi.isEmpty, "some films exist in 4K + HD + VOSTFR / other source")
        #expect(multi.contains { title in Set(title.variants.map(\.sourceID)).count > 1 })
        #expect(catalog.movies.first { $0.variants.count >= 3 }?.variants.first?.quality == .uhd)
        let channel = catalog.channelGroup("tf1")
        #expect(channel?.variants.count == 2)

        let guide = PreviewData.guide
        let now = Date.now
        for group in catalog.channels where group.variants.contains(where: { $0.sourceID != DemoContent.sourceID }) {
            let id = guide.resolveEPGID(for: group)
            #expect(id != nil, "guide for \(group.name)")
            if let id {
                #expect(guide.nowAndNext(forEPGID: id, at: now).now != nil)
                let covered = guide.programs(forEPGID: id, in: DateInterval(start: now.addingTimeInterval(-3 * 3_600 + 1_800), end: now.addingTimeInterval(11 * 3_600)))
                #expect(covered.count >= 5)
            }
        }
    }

    @MainActor
    @Test func previewLibrary() async {
        let catalog = await PreviewData.catalog()
        let library = PreviewData.makeLibrary(for: catalog)
        #expect(library.watchlist.count == 4)
        #expect(library.favoriteChannels.count == 5)
        #expect(!library.continueWatching(in: catalog).isEmpty)
    }
}
