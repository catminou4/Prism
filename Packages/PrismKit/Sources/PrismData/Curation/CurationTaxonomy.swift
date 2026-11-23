import Foundation
import PrismCore

/// A small, stable genre vocabulary. Provider genres and category names in many languages
/// ("Horreur/Epouvante", "Terror/Suspense", "افلام اجنبي رعب", "Komedie"…) map onto it.
public enum CanonicalGenre: Int, CaseIterable, Sendable, Hashable, Codable {
    case action, adventure, animation, anime, comedy, crime, documentary, drama, family, fantasy
    case scienceFiction, horror, thriller, romance, war, western, history, music, reality, standup, sport

    /// French label used for chips and tiles.
    public var label: String {
        switch self {
        case .action: "Action"
        case .adventure: "Aventure"
        case .animation: "Animation"
        case .anime: "Anime"
        case .comedy: "Comédie"
        case .crime: "Policier"
        case .documentary: "Documentaire"
        case .drama: "Drame"
        case .family: "Famille"
        case .fantasy: "Fantastique"
        case .scienceFiction: "Science-fiction"
        case .horror: "Horreur"
        case .thriller: "Thriller"
        case .romance: "Romance"
        case .war: "Guerre"
        case .western: "Western"
        case .history: "Histoire"
        case .music: "Musique"
        case .reality: "Téléréalité"
        case .standup: "Humour et spectacles"
        case .sport: "Sport"
        }
    }

    /// Editorial shelf title (Apple TV-style, written for people, not taxonomies).
    public func shelfTitle(for kind: MediaKind?) -> String {
        switch self {
        case .action: kind == .series ? "Séries d’action" : "Action à haute dose"
        case .adventure: "Grandes aventures"
        case .animation: "Animation pour toute la famille"
        case .anime: "Anime incontournables"
        case .comedy: kind == .series ? "Séries comiques" : "Comédies à partager"
        case .crime: kind == .series ? "Polars et enquêtes" : "Polars et films de gangsters"
        case .documentary: "Documentaires captivants"
        case .drama: kind == .series ? "Grands drames" : "Drames bouleversants"
        case .family: "À regarder en famille"
        case .fantasy: "Mondes fantastiques"
        case .scienceFiction: "Science-fiction"
        case .horror: "Frissons garantis"
        case .thriller: "Thrillers haletants"
        case .romance: "Histoires d’amour"
        case .war: "Films de guerre"
        case .western: "Westerns"
        case .history: "Inspirés de faits réels"
        case .music: "Musique et concerts"
        case .reality: "Téléréalité et divertissement"
        case .standup: "Humour et spectacles"
        case .sport: "Sport"
        }
    }

    /// Genres that make good everyday shelves (niche or event genres are browse-only).
    static let editorialRotation: [CanonicalGenre] = [
        .thriller, .comedy, .scienceFiction, .crime, .animation, .action, .horror, .drama,
        .documentary, .romance, .fantasy, .adventure, .history, .war, .western, .anime,
    ]
}

public struct GenreSet: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ genre: CanonicalGenre) { rawValue = 1 << UInt32(genre.rawValue) }

    public func contains(_ genre: CanonicalGenre) -> Bool { rawValue & (1 << UInt32(genre.rawValue)) != 0 }
    public mutating func insert(_ genre: CanonicalGenre) { formUnion(GenreSet(genre)) }
    public var genres: [CanonicalGenre] { CanonicalGenre.allCases.filter(contains) }
    public var count: Int { rawValue.nonzeroBitCount }
}

/// Streaming brands that providers use to organise their catalogues.
public enum StreamingPlatform: Int, CaseIterable, Sendable, Hashable, Codable {
    case netflix, appleTV, disney, prime, max, canalPlus, paramount, hulu, peacock

    public var name: String {
        switch self {
        case .netflix: "Netflix"
        case .appleTV: "Apple TV+"
        case .disney: "Disney+"
        case .prime: "Prime Video"
        case .max: "HBO Max"
        case .canalPlus: "Canal+"
        case .paramount: "Paramount+"
        case .hulu: "Hulu"
        case .peacock: "Peacock"
        }
    }
}

public struct PlatformSet: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public init(_ platform: StreamingPlatform) { rawValue = 1 << UInt16(platform.rawValue) }

    public func contains(_ platform: StreamingPlatform) -> Bool { rawValue & (1 << UInt16(platform.rawValue)) != 0 }
    public var platforms: [StreamingPlatform] { StreamingPlatform.allCases.filter(contains) }
}

/// Signals read from a provider category name or a title.
public struct TraitFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Children's programming (kept out of general shelves).
    public static let kids = TraitFlags(rawValue: 1 << 0)
    /// Provider "Top IMDb", "Oscar", "Golden Globe", "Top Cinema"… collections.
    public static let acclaimed = TraitFlags(rawValue: 1 << 1)
    /// Provider "New releases", "Latest", "2026"… collections.
    public static let newRelease = TraitFlags(rawValue: 1 << 2)
    public static let uhd = TraitFlags(rawValue: 1 << 3)
    public static let classic = TraitFlags(rawValue: 1 << 4)
    public static let christmas = TraitFlags(rawValue: 1 << 5)
    public static let religious = TraitFlags(rawValue: 1 << 6)
    /// Camera recordings and pre-releases.
    public static let lowQualityRelease = TraitFlags(rawValue: 1 << 7)
    /// French productions ("French Movies", "Acteurs français", "Louis de Funès"…).
    public static let frenchOrigin = TraitFlags(rawValue: 1 << 8)
    /// Content aimed at one regional audience (Bollywood, telenovelas, Turkish dizi…).
    public static let regional = TraitFlags(rawValue: 1 << 9)
    /// Sport events and fight cards filed as VOD.
    public static let sportEvent = TraitFlags(rawValue: 1 << 10)
    /// Asian cinema and K-dramas.
    public static let asian = TraitFlags(rawValue: 1 << 11)
    /// Part of a franchise collection ("Saga", "Marvel", "Collections").
    public static let franchise = TraitFlags(rawValue: 1 << 12)
    /// The title's name looks like an episode or a clip filed as a movie.
    public static let episodeLike = TraitFlags(rawValue: 1 << 13)
    /// At least one category contributed a general-audience (non-regional) signal.
    public static let international = TraitFlags(rawValue: 1 << 14)
    /// Matched against `AcclaimedSelection`: recognised by awards, critics and audiences over time.
    public static let canon = TraitFlags(rawValue: 1 << 15)
}

/// Everything one provider category name tells about its members.
struct CategoryTraits: Sendable, Hashable {
    var genres: GenreSet = []
    var platforms: PlatformSet = []
    var flags: TraitFlags = []
}

/// Keyword classifier for provider category names and genre labels.
enum CurationTaxonomy {
    /// Classifies a provider category name ("MULTI| Netflix Series 4K", "Horreur/Epouvante").
    static func traits(forCategory name: String, currentYear: Int) -> CategoryTraits {
        let text = " " + normalize(name) + " "
        var traits = CategoryTraits()
        traits.genres = genres(in: text)
        for (platform, keys) in platformKeywords where keys.contains(where: text.contains) {
            traits.platforms.insert(PlatformSet(platform))
        }
        for (flag, keys) in flagKeywords where keys.contains(where: text.contains) {
            traits.flags.insert(flag)
        }
        // "Films 2026", "Series 2026", "Película 2025/2026": the current season of releases.
        for year in [currentYear, currentYear + 1] where text.contains(String(year)) {
            traits.flags.insert(.newRelease)
        }
        if traits.flags.contains(.kids) { traits.genres.insert(.family) }
        if traits.genres.contains(.sport) { traits.flags.insert(.sportEvent) }
        if !traits.flags.contains(.regional) { traits.flags.insert(.international) }
        return traits
    }

    /// Maps provider genre labels ("Action & Adventure", "Science-Fiction & Fantastique", "دراما").
    static func genres(forLabel label: String) -> GenreSet {
        genres(in: " " + normalize(label) + " ")
    }

    /// Lowercase, diacritic-free text with separators collapsed to spaces.
    /// Iterates unicode scalars, not Characters: grapheme breaking costs ~100 ns/cluster and
    /// dominated `looksLikeEpisode` (~20 µs/title). Scalar-wise output is identical — appended
    /// content scalars reproduce the same UTF-8 sequence `append(Character)` produced.
    static func normalize(_ text: String) -> String {
        let folded = TextFolding.fold(text)
        var result = ""
        result.reserveCapacity(folded.utf8.count)
        // Starting "already spaced" makes leading separators collapse into nothing — the same
        // net result the old `trimmingCharacters` produced. Only a trailing space can remain.
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            if isSeparator(scalar) {
                if !lastWasSpace {
                    result.unicodeScalars.append(" ")
                    lastWasSpace = true
                }
            } else {
                result.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        if result.hasSuffix(" ") { result.removeLast() }
        return result
    }

    /// The separator set of `normalize`: the punctuation list plus every Unicode `White_Space`
    /// scalar (0009–000D, 0020, 0085, 00A0, 1680, 2000–200A, 2028, 2029, 202F, 205F, 3000).
    private static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x7C, 0x2F, 0x26, 0x2C, 0x28, 0x29, 0x3A, 0x5F, 0x2E: return true
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default: return false
        }
    }

    private static func genres(in text: String) -> GenreSet {
        var set: GenreSet = []
        for (genre, keys) in genreKeywords where keys.contains(where: text.contains) {
            set.insert(genre)
        }
        return set
    }

    /// Titles that are clearly episodes, clips or uploads filed as movies.
    static func looksLikeEpisode(_ title: String) -> Bool {
        let text = " " + normalize(title) + " "
        // Every marker is a short ASCII needle: a second-byte-bucketed scan over the UTF-8
        // storage replaces sixteen `String.contains` calls (~17 µs → ~1 µs per title). ASCII
        // needles can only match literal bytes — never inside a multi-byte scalar — so the
        // byte search returns exactly what the string search did. If a marker ever contains
        // non-ASCII bytes the byte path is skipped entirely (`episodeNeedlesASCIIOnly`).
        if episodeNeedlesASCIIOnly,
           let found = text.utf8.withContiguousStorageIfAvailable({ containsNeedle($0) }) {
            return found
        }
        return episodeMarkers.contains { text.contains($0) }
    }

    /// `false` if any marker is not pure ASCII — the byte search is only exact for ASCII
    /// needles (a non-ASCII needle could byte-match inside another scalar's UTF-8 sequence).
    private static let episodeNeedlesASCIIOnly = episodeMarkers.allSatisfy {
        $0.utf8.allSatisfy { $0 < 0x80 }
    }

    /// `episodeMarkers` as UTF-8 needles. Every prepared marker starts with a space, so
    /// first-byte bucketing is useless — bucket by the *second* byte instead (the memcmp
    /// still verifies the whole needle, so any marker shape stays correct). A first-byte
    /// gate skips positions that cannot start any needle.
    private static let episodeNeedles: (pairs: [[[UInt8]]], singles: [[UInt8]], firstBytes: [Bool]) = {
        var pairs = [[[UInt8]]](repeating: [], count: 256)
        var singles: [[UInt8]] = []
        var firstBytes = [Bool](repeating: false, count: 256)
        for marker in episodeMarkers {
            let bytes = [UInt8](marker.utf8)
            if let first = bytes.first { firstBytes[Int(first)] = true }
            if bytes.count > 1 {
                pairs[Int(bytes[1])].append(bytes)
            } else if !bytes.isEmpty {
                singles.append(bytes)
            }
        }
        return (pairs, singles, firstBytes)
    }()

    private static func containsNeedle(_ buffer: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let base = buffer.baseAddress else { return false }
        let count = buffer.count
        let (pairs, singles, firstBytes) = episodeNeedles
        var position = 0
        while position < count {
            guard firstBytes[Int(base[position])] else {
                position += 1
                continue
            }
            for needle in singles where base[position] == needle[0] { return true }
            // Multi-byte needles are bucketed by their second byte, aligned with
            // `base[position + 1]`; the memcmp verifies every byte including the first.
            if position + 1 < count {
                for needle in pairs[Int(base[position + 1])] {
                    guard position + needle.count <= count else { continue }
                    var matched = true
                    for offset in needle.indices where base[position + offset] != needle[offset] {
                        matched = false
                        break
                    }
                    if matched { return true }
                }
            }
            position += 1
        }
        return false
    }

    private static let episodeMarkers = prepared([(0, [
        " bolum ", " bolumu ", " full bolum", " episode ", " episodio ", " odcinek ", " folge ", " capitulo ",
        " ep ", " s01e", " s02e", " s1e", " @", " trailer ", " teaser ", " making of ",
    ])])[0].1

    // Keywords are matched on the normalized text padded with spaces: a leading space marks a word start.
    private static let genreKeywords: [(CanonicalGenre, [String])] = prepared([
        (.action, [" action", " accion", " akcja", " azione", " actie", " اكشن", " أكشن", " sensacja", " martiaux", " martial", " sztuki walki", " superhero", " marvel", " dc universe", " chuck norris", " jackie chan", " جاكي شان", " james bond", " جيمس بوند"]),
        (.adventure, [" aventure", " adventure", " aventura", " avventura", " przygod", " abenteuer", " مغامر"]),
        (.animation, [" animation", " animacion", " animazione", " animatie", " cartoon", " dessin anime", " bajki", " pixar", " كرتون", " انيميشن", " رسوم متحركة", " animations"]),
        (.anime, [" anime", " manga", " مانجا", " انمي"]),
        (.comedy, [" comed", " comedia", " commedia", " komedi", " komodie", " humor", " كوميد", " kabarety", " comedie"]),
        (.crime, [" crime", " crimen", " kryminal", " policier", " polar", " gangster", " mafia", " جريمة", " krimi", " misdaad"]),
        (.documentary, [" document", " dokument", " docu", " doku", " وثائق", " national geographic", " discovery", " nature"]),
        (.drama, [" drama", " drame", " dramat", " drammatico", " دراما", " telenovela"]),
        (.family, [" kids", " enfant", " jeunesse", " family", " famil", " children", " kinder", " ninos", " crianca", " cocuk", " اطفال", " أطفال", " dla dzieci", " decije", " barn ", " børne", " borne", " hallmark"]),
        (.fantasy, [" fantas", " fantastique", " fantascienza"]),
        (.scienceFiction, [" science fiction", " science-fiction", " sci-fi", " sci fi", " scifi", " netflix sf", " ciencia ficcion", " fantascienza", " katastrof", " sf "]),
        (.horror, [" horror", " horreur", " epouvante", " terror", " رعب", " grusel", " slasher"]),
        (.thriller, [" thriller", " suspense", " mystery", " mystere", " suspens", " إثارة", " اثارة"]),
        (.romance, [" romance", " romant", " romans", " milosc", " رومانس", " رومانسي"]),
        (.war, [" war", " guerre", " guerra", " belico", " wojenn", " حرب", " krieg", " oorlog"]),
        (.western, [" western"]),
        (.history, [" history ", " histoire ", " historia ", " historique", " historical", " hechos reales", " hechosreales", " biopic", " biograph"]),
        (.music, [" music", " musique", " musik", " concert", " musical", " broadway", " muzyka", " taniec"]),
        (.reality, [" reality", " realite", " tele-realite", " telerealite", " emission", " varietes", " joyn reality", " برامج منوعه"]),
        (.standup, [" stand-up", " stand up", " spectacle", " theatre", " teatroteka", " kabaret", " مسرحيات", " one man"]),
        (.sport, [" sport", " wwe", " ufc", " boxing", " formule 1", " formula 1", " glory", " walki", " ppv"]),
    ])

    private static let platformKeywords: [(StreamingPlatform, [String])] = prepared([
        (.netflix, [" netflix", " نتفليكس"]),
        (.appleTV, [" apple"]),
        (.disney, [" disney"]),
        (.prime, [" prime", " amazon"]),
        (.max, [" hbo", " max "]),
        (.canalPlus, [" canal", " mycanal"]),
        (.paramount, [" paramount", " skyshowtime", " sky showtime", " cbs "]),
        (.hulu, [" hulu"]),
        (.peacock, [" peacock", " nbc"]),
    ])

    private static let flagKeywords: [(TraitFlags, [String])] = prepared([
        (.kids, [" kids", " enfant", " jeunesse", " children", " kinder", " ninos", " crianca", " cocuk", " اطفال", " أطفال", " dla dzieci", " decije", " bajki", " barn ", " børne", " borne", " cartoon"]),
        (.acclaimed, [" top imdb", " imdb top", " oscar", " golden globe", " emmy", " cannes", " cesar", " palme", " افضل"]),
        (.newRelease, [" new release", " latest", " nouveaute", " ostatnio dodane", " aggiunto recenti", " estreno", " يعرض الأن", " يعرض الان", " now showing", " recently added", " ajouts"]),
        (.uhd, [" 4k", " uhd", " dolby vision", " 3840", " hdr"]),
        (.classic, [" classic", " classique", " old but gold", " ancienne", " antiguas", " classico", " كلاسيكية", " 1940", " 1900", " jaren 90", " film 1980", " زمان"]),
        (.christmas, [" christmas", " noel", " kerst", " weihnacht", " swiateczn", " navidad", " de noel"]),
        (.religious, [" biblical", " religious", " biblique", " islam", " القرآن", " دينية", " إسلامية", " اسلامية"]),
        (.lowQualityRelease, [" cam ", " hdcam", " pre-release", " pre release"]),
        (.frenchOrigin, [" french", " francais", " acteurs francais", " louis de funes", " cinema francais", " films francais"]),
        (.asian, [" asia", " asiatique", " korean", " asian", " اسيوي", " أسيوية", " k-drama", " kdrama"]),
        // Plural "Collections" are franchise boxes; "Classic Movies Collection" is a catalogue section.
        (.franchise, [" saga", " collections", " kollektion", " marvel", " dc universe", " james bond", " جيمس بوند", " trilog", " universe "]),
        (.regional, [
            " hindi", " tamil", " telugu", " telegu", " bollywood", " punjabi", " malayalam", " kannada", " bangla",
            " marathi", " maharati", " gujarati", " gugarati", " urdu", " pakistan", " turkish", " turske", " dizi",
            " yerli", " telenovela", " latino", " polsk", " greece", " albanian", " romanian", " bulgaria", " persian",
            " russia", " somalia", " african", " hebrew", " philippines", " brazil", " portugal", " danske", " norsk",
            " swedish", " nordic", " sca ", " عربية", " مصري", " خليجي", " سوري", " مغربي", " تونسي", " عراقي",
            " جزائري", " تركي", " هندية", " إيرانية", " أمازيغية", " رمضان", " exxen", " tabii", " gain ", " videoland",
            " npo ", " ziet", " vtmgo", " ziggo", " ruutu", " sorozat", " domace", " strane", " seriale", " dokumentalne",
        ]),
    ])

    /// Keywords go through the same folding as the text they are matched against (Arabic hamza,
    /// diacritics…), keeping their word-boundary spaces.
    private static func prepared<Key>(_ table: [(Key, [String])]) -> [(Key, [String])] {
        table.map { key, words in
            (key, words.map { word in
                (word.hasPrefix(" ") ? " " : "") + normalize(word) + (word.hasSuffix(" ") ? " " : "")
            })
        }
    }
}
