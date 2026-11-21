import Foundation
import Observation

/// Player settings persisted in `UserDefaults` (volume, preferred languages, engine override…).
/// Changes are written immediately. Use a custom suite in tests.
@Observable
public final class PlayerPreferences {
    /// Shared instance backed by `UserDefaults.standard`.
    public static let standard = PlayerPreferences()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let prefix: String

    /// 0…1.
    public var volume: Float {
        didSet { defaults.set(Double(volume), forKey: key(.volume)) }
    }
    /// Subtitles are turned on automatically when a track matches `preferredSubtitleLanguage`.
    public var subtitlesEnabled: Bool {
        didSet { defaults.set(subtitlesEnabled, forKey: key(.subtitlesEnabled)) }
    }
    /// Language code (`fr`, `en`…), nil = no preference.
    public var preferredSubtitleLanguage: String? {
        didSet { defaults.set(preferredSubtitleLanguage, forKey: key(.subtitleLanguage)) }
    }
    /// Language code (`fr`, `en`…), nil = stream default.
    public var preferredAudioLanguage: String? {
        didSet { defaults.set(preferredAudioLanguage, forKey: key(.audioLanguage)) }
    }
    /// Engine used for `.auto` items (`.auto` = automatic selection).
    public var defaultEngine: PlaybackEngineKind {
        didSet { defaults.set(defaultEngine.rawValue, forKey: key(.defaultEngine)) }
    }
    /// libvlc network caching for VOD in milliseconds (live adds 1 s). Clamped 300…10 000.
    public var networkCachingMilliseconds: Int {
        didSet {
            let clamped = Self.clampCaching(networkCachingMilliseconds)
            if clamped != networkCachingMilliseconds { networkCachingMilliseconds = clamped }
            defaults.set(clamped, forKey: key(.networkCaching))
        }
    }
    public var subtitleStyle: SubtitleStyle {
        didSet { defaults.set(subtitleStyle.rawValue, forKey: key(.subtitleStyle)) }
    }
    /// Keep the window aspect ratio locked to the video while resizing.
    public var keepsWindowAspectRatio: Bool {
        didSet { defaults.set(keepsWindowAspectRatio, forKey: key(.keepsAspect)) }
    }

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "prism.player.") {
        self.defaults = defaults
        self.prefix = keyPrefix
        func k(_ key: Key) -> String { keyPrefix + key.rawValue }
        if defaults.object(forKey: k(.volume)) != nil {
            volume = Float(min(1, max(0, defaults.double(forKey: k(.volume)))))
        } else {
            volume = 1
        }
        subtitlesEnabled = defaults.bool(forKey: k(.subtitlesEnabled))
        preferredSubtitleLanguage = defaults.string(forKey: k(.subtitleLanguage))
        preferredAudioLanguage = defaults.string(forKey: k(.audioLanguage))
        defaultEngine =
            defaults.string(forKey: k(.defaultEngine)).flatMap(PlaybackEngineKind.init(rawValue:))
            ?? .auto
        if defaults.object(forKey: k(.networkCaching)) != nil {
            networkCachingMilliseconds = Self.clampCaching(defaults.integer(forKey: k(.networkCaching)))
        } else {
            networkCachingMilliseconds = 1500
        }
        subtitleStyle =
            defaults.string(forKey: k(.subtitleStyle)).flatMap(SubtitleStyle.init(rawValue:))
            ?? .system
        keepsWindowAspectRatio = defaults.bool(forKey: k(.keepsAspect))
    }

    /// Engine configuration derived from the preferences.
    public var engineConfiguration: EngineConfiguration {
        EngineConfiguration(
            networkCachingMilliseconds: networkCachingMilliseconds, subtitleStyle: subtitleStyle)
    }

    /// Removes every persisted value (back to defaults on next launch).
    public func reset() {
        volume = 1
        subtitlesEnabled = false
        preferredSubtitleLanguage = nil
        preferredAudioLanguage = nil
        defaultEngine = .auto
        networkCachingMilliseconds = 1500
        subtitleStyle = .system
        keepsWindowAspectRatio = false
        for key in Key.allCases { defaults.removeObject(forKey: self.key(key)) }
    }

    private enum Key: String, CaseIterable {
        case volume, subtitlesEnabled, subtitleLanguage, audioLanguage, defaultEngine
        case networkCaching, subtitleStyle, keepsAspect
    }

    private func key(_ key: Key) -> String { prefix + key.rawValue }

    private static func clampCaching(_ value: Int) -> Int { min(10_000, max(300, value)) }
}
