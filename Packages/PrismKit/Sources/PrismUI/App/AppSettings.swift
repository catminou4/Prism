import Foundation
import PrismCore

struct AppSettings {
    private static let homeAudioKey = "prism.homeAudioLanguages"

    var homeAudioLanguages: Set<HomeAudioLanguage> {
        get {
            let stored = UserDefaults.standard.stringArray(forKey: Self.homeAudioKey) ?? []
            let languages = Set(stored.compactMap(HomeAudioLanguage.init(rawValue:)))
            return languages.isEmpty ? HomeAudioLanguage.defaults : languages
        }
        nonmutating set {
            let codes = HomeAudioLanguage.allCases.filter { newValue.contains($0) }.map(\.rawValue)
            UserDefaults.standard.set(codes, forKey: Self.homeAudioKey)
        }
    }
}
