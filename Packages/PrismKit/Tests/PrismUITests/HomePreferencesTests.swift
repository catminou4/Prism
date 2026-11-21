import PrismCore
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
}
