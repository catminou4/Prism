import PrismCore
import PrismData
import Testing
@testable import PrismUI

@MainActor
@Suite("Langues de l’accueil")
struct HomePreferencesTests {
    @Test func languageSelectionUpdatesOnlyPreferences() async {
        let model = await AppModel.preview()
        let revision = model.catalogRevision
        let searchIndex = model.searchIndex

        #expect(model.homeAudioLanguages == [.french, .english])
        model.setHomeAudioLanguages([.french])
        #expect(model.homeAudioLanguages == [.french])
        model.setHomeAudioLanguages([.english])
        model.setHomeAudioLanguages([])

        #expect(model.homeAudioLanguages == [.english])
        #expect(model.catalogRevision == revision)
        #expect(model.searchIndex === searchIndex)
    }

    @Test func curatedFeedsAreIsolatedPerScope() async {
        // Each scope owns its feed state: refreshing .home must not populate .movies or
        // .series, and a scope stays empty until its own refresh completes.
        let model = await AppModel.preview()
        for scope in [CurationScope.home, .movies, .series] {
            #expect(!model.hasFeed(for: scope), "\(scope) starts without a feed")
            #expect(model.feed(for: scope).isEmpty)
        }

        await model.refreshFeed(model.curationRequest(for: .home))
        #expect(model.hasFeed(for: .home))
        #expect(!model.hasFeed(for: .movies), ".movies keeps its placeholder until its own refresh")
        #expect(!model.hasFeed(for: .series))

        await model.refreshFeed(model.curationRequest(for: .series))
        #expect(model.hasFeed(for: .series))
        #expect(!model.hasFeed(for: .movies))

        await model.refreshFeed(model.curationRequest(for: .movies))
        #expect(model.hasFeed(for: .movies))
        // A repeated refresh for an already-current request is deduplicated: the stored
        // feed stays the one produced by the first matching request.
        let homeFeed = model.feed(for: .home)
        await model.refreshFeed(model.curationRequest(for: .home))
        #expect(model.feed(for: .home).shelves.map(\.id) == homeFeed.shelves.map(\.id))
    }
}
