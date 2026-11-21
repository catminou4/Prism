import Foundation
import Testing

@testable import PrismPlayer

@Suite struct PlayerPreferencesTests {
    static func makeDefaults() throws -> (UserDefaults, String) {
        let name = "prism.player.tests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func defaultsWhenEmpty() throws {
        let (defaults, name) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PlayerPreferences(defaults: defaults)
        #expect(preferences.volume == 1)
        #expect(preferences.subtitlesEnabled == false)
        #expect(preferences.preferredSubtitleLanguage == nil)
        #expect(preferences.preferredAudioLanguage == nil)
        #expect(preferences.defaultEngine == .auto)
        #expect(preferences.networkCachingMilliseconds == 1500)
        #expect(preferences.subtitleStyle == .system)
    }

    @Test func persistsAcrossInstances() throws {
        let (defaults, name) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let first = PlayerPreferences(defaults: defaults)
        first.volume = 0.4
        first.subtitlesEnabled = true
        first.preferredSubtitleLanguage = "fr"
        first.preferredAudioLanguage = "en"
        first.defaultEngine = .vlc
        first.networkCachingMilliseconds = 3000
        first.subtitleStyle = .large
        first.keepsWindowAspectRatio = true

        let second = PlayerPreferences(defaults: defaults)
        #expect(abs(second.volume - 0.4) < 0.0001)
        #expect(second.subtitlesEnabled)
        #expect(second.preferredSubtitleLanguage == "fr")
        #expect(second.preferredAudioLanguage == "en")
        #expect(second.defaultEngine == .vlc)
        #expect(second.networkCachingMilliseconds == 3000)
        #expect(second.subtitleStyle == .large)
        #expect(second.keepsWindowAspectRatio)
        #expect(second.engineConfiguration == EngineConfiguration(networkCachingMilliseconds: 3000, subtitleStyle: .large))
    }

    @Test func clampsAndTolaratesGarbage() throws {
        let (defaults, name) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(7.5, forKey: "prism.player.volume")
        defaults.set("quantum", forKey: "prism.player.defaultEngine")
        defaults.set(50, forKey: "prism.player.networkCaching")
        let preferences = PlayerPreferences(defaults: defaults)
        #expect(preferences.volume == 1)
        #expect(preferences.defaultEngine == .auto)
        #expect(preferences.networkCachingMilliseconds == 300)
        preferences.networkCachingMilliseconds = 99_999
        #expect(preferences.networkCachingMilliseconds == 10_000)
        #expect(defaults.integer(forKey: "prism.player.networkCaching") == 10_000)
    }

    @Test func resetClearsStoredValues() throws {
        let (defaults, name) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PlayerPreferences(defaults: defaults)
        preferences.preferredAudioLanguage = "de"
        preferences.reset()
        #expect(defaults.object(forKey: "prism.player.audioLanguage") == nil)
        #expect(PlayerPreferences(defaults: defaults).preferredAudioLanguage == nil)
    }
}
