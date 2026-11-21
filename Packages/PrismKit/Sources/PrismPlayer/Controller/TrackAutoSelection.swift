import Foundation

/// Language-code normalisation for messy IPTV track metadata.
nonisolated public enum TrackLanguage {
    /// ISO 639-2/B codes Foundation does not map, plus common IPTV tags.
    static let aliases: [String: String] = [
        "fre": "fr", "ger": "de", "dut": "nl", "chi": "zh", "cze": "cs", "gre": "el", "per": "fa",
        "rum": "ro", "slo": "sk", "alb": "sq", "arm": "hy", "baq": "eu", "bur": "my", "geo": "ka",
        "ice": "is", "mac": "mk", "mao": "mi", "may": "ms", "tib": "bo", "wel": "cy",
        "vf": "fr", "vff": "fr", "vfq": "fr", "vfi": "fr", "truefrench": "fr", "vost": "fr",
        "vostfr": "fr", "jap": "ja", "gr": "el", "esp": "es", "cat": "ca",
    ]

    /// "fr-FR" → "fr", "fra"/"fre" → "fr", "VF" → "fr", "English" → "en", "und"/garbage → nil.
    public static func normalizedCode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let base = String(trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
        if let alias = aliases[base] { return alias }
        if base.count == 2 || base.count == 3, base.allSatisfy(\.isLetter) {
            let code = Locale.LanguageCode(base)
            if code.isISOLanguage, let alpha2 = code.identifier(.alpha2), alpha2 != "und" {
                return alpha2
            }
            if code.isISOLanguage, base.count == 3, !["und", "mul", "zxx", "mis"].contains(base) {
                return base
            }
        }
        return codeFromName(trimmed)
    }

    /// Language code found in a free-form track name ("Piste 1 - [Français]", "English (SDH)").
    public static func codeFromName(_ name: String) -> String? {
        let tokens = words(in: name)
        guard !tokens.isEmpty else { return nil }
        for token in tokens {
            if let alias = aliases[token] { return alias }
        }
        for (name, code) in languageNames where tokens.contains(name) {
            return code
        }
        // Bracketed ISO codes: "[fra]", "(eng)".
        for token in tokens where token.count == 3 {
            let code = Locale.LanguageCode(token)
            if code.isISOLanguage, let alpha2 = code.identifier(.alpha2), alpha2 != "und" {
                return alpha2
            }
        }
        return nil
    }

    /// Whether a track is in `language` (code or name).
    public static func matches(_ track: MediaTrack, language: String) -> Bool {
        guard let wanted = normalizedCode(language) else { return false }
        if let code = normalizedCode(track.language), code == wanted { return true }
        if track.language == nil || normalizedCode(track.language) == nil {
            return codeFromName(track.name) == wanted
        }
        return false
    }

    /// Lower-cased, diacritic-folded words.
    static func words(in text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
    }

    /// Language names in English, French and the native language, diacritic-folded.
    static let languageNames: [(String, String)] = {
        let codes = [
            "fr", "en", "es", "de", "it", "pt", "ar", "tr", "nl", "pl", "ru", "ja", "zh", "ko",
            "hi", "sv", "no", "da", "fi", "el", "he", "ro", "hu", "cs", "uk", "fa", "ur", "bn",
            "th", "vi", "id", "ms", "ca", "hr", "sr", "bg", "sk", "sl", "lt", "lv", "et", "sq",
        ]
        let locales = [Locale(identifier: "en"), Locale(identifier: "fr")]
        var pairs: [(String, String)] = []
        for code in codes {
            var names = locales.compactMap { $0.localizedString(forLanguageCode: code) }
            if let native = Locale(identifier: code).localizedString(forLanguageCode: code) {
                names.append(native)
            }
            for name in names {
                for word in words(in: name) where word.count > 3 {
                    pairs.append((word, code))
                }
            }
        }
        pairs.append(("francais", "fr"))
        pairs.append(("english", "en"))
        pairs.append(("castellano", "es"))
        pairs.append(("latino", "es"))
        pairs.append(("arabe", "ar"))
        return pairs
    }()
}

/// Pure track choice from user preferences.
nonisolated public enum TrackAutoSelector {
    /// Best track for `preferredLanguage`: full (non-forced) tracks first, regular before
    /// SDH/audio-description, then source order. nil when nothing matches.
    public static func bestTrack(
        in tracks: [MediaTrack], preferredLanguage: String?
    ) -> MediaTrack? {
        guard let preferredLanguage, normalizedLanguage(preferredLanguage) != nil else { return nil }
        let matching = tracks.filter { TrackLanguage.matches($0, language: preferredLanguage) }
        return matching.min { lhs, rhs in
            rank(lhs) < rank(rhs)
        }
    }

    /// Subtitle decision on ready: `.some(nil)` = turn off, `.some(id)` = select, nil = keep
    /// the engine default.
    public static func subtitleSelection(
        in tracks: [MediaTrack], enabled: Bool, preferredLanguage: String?
    ) -> MediaTrack.ID?? {
        guard enabled else { return .some(nil) }
        guard let track = bestTrack(in: tracks, preferredLanguage: preferredLanguage) else {
            return nil
        }
        return .some(track.id)
    }

    /// Audio decision on ready: id to select, nil = keep the engine default.
    public static func audioSelection(
        in tracks: [MediaTrack], preferredLanguage: String?
    ) -> MediaTrack.ID? {
        bestTrack(in: tracks, preferredLanguage: preferredLanguage)?.id
    }

    private static func normalizedLanguage(_ raw: String) -> String? {
        TrackLanguage.normalizedCode(raw)
    }

    private static func rank(_ track: MediaTrack) -> Int {
        (track.isForced ? 2 : 0) + (track.isAccessibility ? 1 : 0)
    }
}
