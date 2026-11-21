import PrismCore

/// Language labels explicitly present in a provider's raw category name.
/// This is catalog evidence. Embedded audio tracks can only be confirmed in the player.
enum ProviderCategoryLanguage {
    private static let labels: [String: String] = [
        "fr": "fr", "fra": "fr", "fre": "fr", "fr fr": "fr", "fr ca": "fr", "francais": "fr", "french": "fr",
        "vf": "fr", "vff": "fr", "vfq": "fr", "vfi": "fr", "truefrench": "fr",
        "en": "en", "eng": "en", "en gb": "en", "en us": "en", "anglais": "en", "english": "en",
        "ar": "ar", "ara": "ar", "arabic": "ar", "arabe": "ar", "العربية": "ar",
        "de": "de", "deu": "de", "ger": "de", "deutsch": "de", "german": "de", "allemand": "de",
        "es": "es", "spa": "es", "espanol": "es", "spanish": "es", "espagnol": "es",
        "hi": "hi", "hin": "hi", "hindi": "hi",
        "it": "it", "ita": "it", "italiano": "it", "italian": "it", "italien": "it",
        "ja": "ja", "jpn": "ja", "japanese": "ja", "japonais": "ja", "日本語": "ja",
        "ko": "ko", "kor": "ko", "korean": "ko", "coreen": "ko", "한국어": "ko",
        "nl": "nl", "nld": "nl", "dutch": "nl", "neerlandais": "nl",
        "pl": "pl", "pol": "pl", "polish": "pl", "polonais": "pl",
        "pt": "pt", "por": "pt", "pt br": "pt", "portugues": "pt", "portuguese": "pt", "portugais": "pt",
        "ru": "ru", "rus": "ru", "russian": "ru", "russe": "ru",
        "ta": "ta", "tam": "ta", "tamil": "ta",
        "te": "te", "tel": "te", "telugu": "te",
        "tr": "tr", "tur": "tr", "turkish": "tr", "turc": "tr", "turkce": "tr",
        "zh": "zh", "zho": "zh", "chinese": "zh", "chinois": "zh", "mandarin": "zh",
    ]
    private static let mediaPrefixes: Set<String> = ["film", "films", "movie", "movies", "serie", "series", "vod", "cinema", "audio"]
    private static let subtitles: Set<String> = ["vost", "vostfr", "vosta", "subfrench", "subtitles", "subtitulos"]
    private static let separators: Set<Character> = Set("|│┃¦•·:;/[](){}»►—–")

    static func codes(in name: String) -> Set<String> {
        let segments = name.split { separators.contains($0) }
        var result: Set<String> = []
        var isSubtitledEdition = false
        var hasFrenchAudioMarker = false
        for (index, segment) in segments.enumerated() {
            let key = TitleNormalizer.key(String(segment))
            let words = key.split(separator: " ")
            if words.contains("vostfr") || words.contains("subfrench") { isSubtitledEdition = true }
            if key.contains("sous titre") || words.contains(where: { subtitles.contains(String($0)) }) { continue }
            if words.contains(where: { ["vf", "vff", "vfq", "vfi", "truefrench"].contains($0) }) {
                hasFrenchAudioMarker = true
            }
            if let code = labels[key] {
                result.insert(code)
                continue
            }

            // Bare short codes can be words, e.g. « Films en famille ». Require a real label boundary.
            let tokens = segment.split { !$0.isLetter && !$0.isNumber && $0 != "-" }.filter { $0 != "-" }
            let candidate = tokens.drop(while: { mediaPrefixes.contains(TitleNormalizer.key(String($0))) }).first
            guard let candidate else { continue }
            let normalized = TitleNormalizer.key(String(candidate))
            if normalized.count <= 2, candidate != candidate.uppercased() { continue }
            guard index == 0 || candidate.uppercased() == candidate || tokens.first.map({ $0.lowercased() == "audio" }) == true else { continue }
            if let code = labels[normalized] { result.insert(code) }
        }
        if isSubtitledEdition, !hasFrenchAudioMarker { result.remove("fr") }
        return result
    }
}
