public enum HomeAudioLanguage: String, CaseIterable, Hashable, Sendable {
    case french = "fr"
    case english = "en"

    public static let defaults: Set<Self> = [.french, .english]
}
