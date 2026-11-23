import Foundation
import Testing
@testable import PrismCore

struct NormalizerCase: Sendable, CustomTestStringConvertible {
    var raw: String
    var title: String
    var key: String? = nil
    var year: Int? = nil
    var quality: VideoQuality = .unknown
    var tags: [String]? = nil
    var containsTags: [String] = []
    var season: Int? = nil
    var episode: Int? = nil
    var isSeparator = false
    var episodeTitle: String? = nil

    var testDescription: String { raw }
}

@Suite("TitleNormalizer")
struct TitleNormalizerTests {
    static let cases: [NormalizerCase] = [
        // Country / language prefixes
        .init(raw: "FR: TF1 HD", title: "TF1", key: "tf1", quality: .hd, tags: ["FR"]),
        .init(raw: "|FR| TF1 FHD", title: "TF1", key: "tf1", quality: .fhd, tags: ["FR"]),
        .init(raw: "FR - France 2", title: "France 2", key: "france 2", tags: ["FR"]),
        .init(raw: "FR| M6", title: "M6", tags: ["FR"]),
        .init(raw: "FR|M6 HD", title: "M6", quality: .hd, tags: ["FR"]),
        .init(raw: "[FR] Canal+", title: "Canal+", key: "canal plus", tags: ["FR"]),
        .init(raw: "(FR) Arte", title: "Arte", tags: ["FR"]),
        .init(raw: "FR ▎TF1", title: "TF1", tags: ["FR"]),
        .init(raw: "UK: BBC One HD", title: "BBC One", key: "bbc one", quality: .hd, tags: ["UK"]),
        .init(raw: "US| CNN", title: "CNN", tags: ["US"]),
        .init(raw: "AR-MBC 1", title: "MBC 1", tags: ["AR"]),
        .init(raw: "USA: HBO", title: "HBO", tags: ["USA"]),
        .init(raw: "FR HD: TF1", title: "TF1", quality: .hd, tags: ["FR"]),
        .init(raw: "🇫🇷 TF1", title: "TF1", tags: ["FR"]),
        .init(raw: "BBC: Planet Earth", title: "BBC: Planet Earth"),
        // Quality tokens
        .init(raw: "TF1 ᴴᴰ", title: "TF1", quality: .hd, tags: []),
        .init(raw: "Canal+ Sport ᵁᴴᴰ", title: "Canal+ Sport", quality: .uhd),
        .init(raw: "Film ⁴ᴷ", title: "Film", quality: .uhd),
        .init(raw: "TF1 HD+", title: "TF1", quality: .hd),
        .init(raw: "TF1 FULL HD", title: "TF1", quality: .fhd),
        .init(raw: "M6 SD", title: "M6", quality: .sd),
        .init(raw: "Arte 1080p", title: "Arte", quality: .fhd),
        .init(raw: "Arte 720p", title: "Arte", quality: .hd),
        .init(raw: "Avatar 2160p", title: "Avatar", quality: .uhd),
        .init(raw: "Avatar UHD", title: "Avatar", quality: .uhd),
        .init(raw: "M6 HD (1080p)", title: "M6", quality: .fhd),
        .init(raw: "4K | Avatar (2009) [MULTI] HDR", title: "Avatar", key: "avatar", year: 2009, quality: .uhd, containsTags: ["MULTI", "HDR"]),
        // Codec / format tags
        .init(raw: "TF1 HEVC", title: "TF1", tags: ["HEVC"]),
        .init(raw: "TF1 H.265", title: "TF1", tags: ["HEVC"]),
        .init(raw: "TF1 FHD (H265)", title: "TF1", quality: .fhd, tags: ["HEVC"]),
        .init(raw: "Dune x265 HDR10", title: "Dune", tags: ["HEVC", "HDR"]),
        .init(raw: "Dune DOLBY VISION", title: "Dune", tags: ["DV"]),
        .init(raw: "Dune DV ATMOS", title: "Dune", tags: ["DV", "ATMOS"]),
        .init(raw: "Avatar 3D", title: "Avatar", tags: ["3D"]),
        .init(raw: "|FR| CANAL+ 4K HDR", title: "CANAL+", quality: .uhd, tags: ["FR", "HDR"]),
        // Language tags
        .init(raw: "Inception VF", title: "Inception", tags: ["VF"]),
        .init(raw: "Inception VFF 1080p", title: "Inception", quality: .fhd, tags: ["VFF"]),
        .init(raw: "Inception (VFQ)", title: "Inception", tags: ["VFQ"]),
        .init(raw: "Parasite VOST", title: "Parasite", tags: ["VOST"]),
        .init(raw: "Parasite [VOSTFR]", title: "Parasite", tags: ["VOSTFR"]),
        .init(raw: "Parasite VO", title: "Parasite", tags: ["VO"]),
        .init(raw: "Dune MULTI-SUB", title: "Dune", tags: ["MULTI-SUB"]),
        .init(raw: "Dune TRUEFRENCH 1080p", title: "Dune", quality: .fhd, tags: ["TRUEFRENCH"]),
        .init(raw: "Dune FRENCH", title: "Dune", tags: ["FRENCH"]),
        .init(raw: "The French Connection", title: "The French Connection", tags: []),
        .init(raw: "Dune SUBFRENCH", title: "Dune", tags: ["SUBFRENCH"]),
        .init(raw: "VOSTFR - The Bear S02 E05", title: "The Bear", key: "the bear", tags: ["VOSTFR"], season: 2, episode: 5),
        // Years
        .init(raw: "Avatar (2009)", title: "Avatar", year: 2009),
        .init(raw: "Avatar [2009]", title: "Avatar", year: 2009),
        .init(raw: "Avatar - 2009", title: "Avatar", year: 2009),
        .init(raw: "Avatar 2009", title: "Avatar", year: 2009),
        .init(raw: "Avatar 2009 MULTI 1080p", title: "Avatar", year: 2009, quality: .fhd, tags: ["MULTI"]),
        .init(raw: "FR - Avatar (2009) 4K", title: "Avatar", year: 2009, quality: .uhd, tags: ["FR"]),
        .init(raw: "1917 (2019)", title: "1917", key: "1917", year: 2019),
        .init(raw: "2012", title: "2012", key: "2012", year: nil),
        .init(raw: "Blade Runner 2049", title: "Blade Runner 2049", year: nil),
        .init(raw: "Blade Runner 2049 (2017)", title: "Blade Runner 2049", year: 2017),
        .init(raw: "Avatar (1850)", title: "Avatar (1850)", year: nil),
        // Series markers
        .init(raw: "Breaking Bad (2008) S01E01", title: "Breaking Bad", key: "breaking bad", year: 2008, season: 1, episode: 1),
        .init(raw: "Breaking Bad S01E01 - Pilot", title: "Breaking Bad", season: 1, episode: 1, episodeTitle: "Pilot"),
        .init(raw: "The Office S1.E2", title: "The Office", season: 1, episode: 2),
        .init(raw: "The Office S01-E02", title: "The Office", season: 1, episode: 2),
        .init(raw: "Friends 1x02", title: "Friends", season: 1, episode: 2),
        .init(raw: "Lupin Saison 1 Episode 2", title: "Lupin", season: 1, episode: 2),
        .init(raw: "Lupin Saison 2 Épisode 10", title: "Lupin", season: 2, episode: 10),
        .init(raw: "Dark Season 1 Episode 3", title: "Dark", season: 1, episode: 3),
        .init(raw: "The.Bear.S02E05.MULTI.1080p.WEB", title: "The Bear", quality: .fhd, tags: ["MULTI"], season: 2, episode: 5),
        .init(raw: "FR - The Bear S02E05 VOSTFR", title: "The Bear", tags: ["FR", "VOSTFR"], season: 2, episode: 5),
        .init(raw: "Season of the Witch", title: "Season of the Witch"),
        // Unicode / decorations
        .init(raw: "Amélie", title: "Amélie", key: "amelie"),
        .init(raw: "Spider-Man: No Way Home", title: "Spider-Man: No Way Home", key: "spider man no way home"),
        .init(raw: "★ TF1 ★", title: "TF1"),
        .init(raw: "▶ Arte ●", title: "Arte"),
        .init(raw: "TF1   Séries    Films", title: "TF1 Séries Films", key: "tf1 series films"),
        .init(raw: "L'Équipe HD", title: "L'Équipe", key: "lequipe", quality: .hd),
        .init(raw: "Cœur de pirate", title: "Cœur de pirate", key: "coeur de pirate"),
        .init(raw: "TF1 HD -", title: "TF1", quality: .hd),
        .init(raw: "TF1 (Backup)", title: "TF1"),
        .init(raw: "Director's Cut (Extended)", title: "Director's Cut (Extended)", key: "directors cut extended"),
        // Separators
        .init(raw: "##### FRANCE #####", title: "FRANCE", isSeparator: true),
        .init(raw: "----- SPORT -----", title: "SPORT", isSeparator: true),
        .init(raw: "★★★ NEWS ★★★", title: "NEWS", isSeparator: true),
        .init(raw: "===== VOD =====", title: "VOD", isSeparator: true),
        .init(raw: "*** MOVIES ***", title: "MOVIES", isSeparator: true),
        .init(raw: "M*A*S*H", title: "M*A*S*H"),
        // Real-world mix
        .init(raw: "Sky Cinema Premiere HD UK", title: "Sky Cinema Premiere", quality: .hd, tags: ["UK"]),
        .init(raw: "TMC ᶠᴴᴰ", title: "TMC", quality: .fhd),
        .init(raw: "TF1 +1", title: "TF1 +1", key: "tf1 plus 1"),
        .init(raw: "[VIP] TF1 HD", title: "TF1", quality: .hd, tags: []),
        .init(raw: "QC: Télé-Québec", title: "Télé-Québec", key: "tele quebec", tags: ["QC"]),
        .init(raw: "EXYU: RTS 1", title: "RTS 1", tags: ["EXYU"]),
        .init(raw: "▶️ VOD | Avatar", title: "Avatar"),
        .init(raw: "Spider-Man.No.Way.Home.2021.MULTI.1080p.WEB.x264", title: "Spider-Man No Way Home", year: 2021, quality: .fhd, tags: ["MULTI", "H264"]),
        .init(raw: "Dune_Part_Two_2024_MULTI_2160p", title: "Dune Part Two", year: 2024, quality: .uhd, tags: ["MULTI"]),
        .init(raw: "Le Seigneur des anneaux : La Communauté de l'anneau (2001) [VFF] [4K HDR]", title: "Le Seigneur des anneaux : La Communauté de l'anneau", year: 2001, quality: .uhd, tags: ["VFF", "HDR"]),
        .init(raw: "Game of Thrones S08E06 - The Iron Throne", title: "Game of Thrones", season: 8, episode: 6, episodeTitle: "The Iron Throne"),
        .init(raw: "La Casa de Papel - Saison 3 Episode 1", title: "La Casa de Papel", season: 3, episode: 1),
        .init(raw: "Friends S10", title: "Friends", season: 10, episode: nil),
        .init(raw: "The Office (US) S05E14", title: "The Office", tags: ["US"], season: 5, episode: 14),
        .init(raw: "1923 S01E01", title: "1923", year: nil, season: 1, episode: 1),
        .init(raw: "Star Wars: Episode IV - A New Hope (1977)", title: "Star Wars: Episode IV - A New Hope", year: 1977),
        .init(raw: "Ocean's Eleven 2001", title: "Ocean's Eleven", key: "oceans eleven", year: 2001),
        .init(raw: "FR: TF1 SD/HD", title: "TF1", quality: .hd, tags: ["FR"]),
        .init(raw: "|| NEWS ||", title: "NEWS", isSeparator: true),
    ]

    @Test(arguments: cases)
    func normalize(_ c: NormalizerCase) {
        let n = TitleNormalizer.normalize(c.raw)
        #expect(n.title == c.title)
        if let key = c.key { #expect(n.key == key) }
        #expect(n.year == c.year)
        #expect(n.quality == c.quality)
        if let tags = c.tags { #expect(n.tags == tags) }
        for tag in c.containsTags { #expect(n.tags.contains(tag)) }
        #expect(n.season == c.season)
        #expect(n.episode == c.episode)
        #expect(n.isSeparator == c.isSeparator)
        if let episodeTitle = c.episodeTitle { #expect(n.episodeTitle == episodeTitle) }
    }

    @Test(arguments: [
        ("FR | FILMS ACTION", "Films Action"),
        ("|FR| SÉRIES TV", "Séries TV"),
        ("FR: SPORT ⚽", "Sport"),
        ("Films d'action", "Films d'action"),
        ("UK | BBC CHANNELS", "BBC Channels"),
        ("FRANCE HD", "France HD"),
        ("===== DOCUMENTAIRES =====", "Documentaires"),
        ("FR - FILMS DE GUERRE", "Films de Guerre"),
        ("[FR] Cinéma", "Cinéma"),
        ("🇫🇷 ENFANTS", "Enfants"),
        ("4K | FILMS", "4K | Films"),
        ("NETFLIX SÉRIES |FR|", "Netflix Séries"),
    ])
    func cleanCategoryName(_ raw: String, _ expected: String) {
        #expect(TitleNormalizer.cleanCategoryName(raw) == expected)
    }

    @Test(arguments: [
        ("XXX", true), ("FR | ADULTS", true), ("Adulte", true), ("ADULTES +18", true), ("18+ ONLY", true),
        ("+18", true), ("Porn", true), ("FR: HOT", true), ("Dorcel TV", true), ("Films Action", false),
        ("Hotel", false), ("Sport 18", false), ("Kids", false), ("Photographie", false),
    ])
    func adultCategories(_ text: String, _ expected: Bool) {
        #expect(TitleNormalizer.isAdult(text) == expected)
    }

    @Test func adultNamesAreStricter() {
        #expect(!TitleNormalizer.isAdultName("Hot Fuzz"))
        #expect(TitleNormalizer.isAdultName("XXX Channel"))
        #expect(TitleNormalizer.isAdult("Hot Fuzz"))
    }

    @Test func keyFolding() {
        #expect(TitleNormalizer.key("Amélie") == "amelie")
        #expect(TitleNormalizer.key("  Spider-Man:  No Way Home ") == "spider man no way home")
        #expect(TitleNormalizer.key("Œuvre & Straße") == "oeuvre strasse")
        #expect(TitleNormalizer.key("Canal +") == "canal plus")
        #expect(TitleNormalizer.key("Москва") == "москва")
        #expect(TitleNormalizer.key("Tiếng Việt") == "tieng viet")
    }

    @Test func hostileInputsNeverCrash() {
        let inputs = ["", " ", "()", "[[[", ")))", "|||", "-", "S", "S01", "E01", "1x", "x01", "Saison", "Saison 1", "(", "🇫", "🇫🇷🇧🇪", "ᴴᴰ", "\u{0}\u{1}", "\u{FEFF}TF1", "a\u{0301}", String(repeating: "★", count: 200)]
        for input in inputs {
            let n = TitleNormalizer.normalize(input)
            #expect(n.key == TitleNormalizer.key(n.title))
            _ = TitleNormalizer.cleanCategoryName(input)
            _ = TitleNormalizer.isAdult(input)
        }
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("ABCxyz0129 :|-[]()★▶🇫🇷ᴴᴰéÉœ+.'_SExX#=*")
        for _ in 0..<2000 {
            let length = Int.random(in: 0...24, using: &generator)
            let text = String((0..<length).map { _ in alphabet.randomElement(using: &generator) ?? "a" })
            let n = TitleNormalizer.normalize(text)
            #expect(!n.title.hasPrefix(" ") && !n.title.hasSuffix(" "))
            _ = TitleNormalizer.cleanCategoryName(text)
        }
    }

    @Test func performance() {
        let samples = Self.cases.map(\.raw)
        let iterations = 150_000
        let clock = ContinuousClock()
        var sink = 0
        let elapsed = clock.measure {
            for i in 0..<iterations {
                sink &+= TitleNormalizer.normalize(samples[i % samples.count]).key.utf8.count
            }
        }
        let perCall = elapsed / iterations
        print("TitleNormalizer: \(iterations) calls in \(elapsed) (\(perCall) per call)")
        #expect(sink > 0)
        #expect(elapsed < .seconds(20))
    }

    @Test func hugeDigitRunsDoNotOverflow() {
        _ = TitleNormalizer.normalize("Série 99999999999999999999x12 FR")
        _ = TitleNormalizer.normalize("Série 12x99999999999999999999 FR")
        #expect(TitleNormalizer.normalize("The Office 2x05").title.isEmpty == false)
    }

    @Test func memoizedResultsNeverLeakAcrossInputs() {
        // Every bounded memo is keyed by the complete raw string: interleaved calls on
        // distinct inputs must each return their own result — the second pass below is
        // entirely cache hits and must return identical values.
        struct Case {
            let raw: String
            let title: String
            let key: String?
            let quality: VideoQuality
            let tags: [String]?
            let containsTags: [String]
        }
        let cases: [Case] = [
            .init(raw: "FR: TF1 HD", title: "TF1", key: "tf1", quality: .hd, tags: ["FR"], containsTags: []),
            .init(raw: "UK: BBC One HD", title: "BBC One", key: "bbc one", quality: .hd, tags: ["UK"], containsTags: []),
            .init(raw: "[FR] Canal+", title: "Canal+", key: "canal plus", quality: .unknown, tags: ["FR"], containsTags: []),
            .init(raw: "FR - France 2", title: "France 2", key: "france 2", quality: .unknown, tags: ["FR"], containsTags: []),
            .init(raw: "Dune DV ATMOS", title: "Dune", key: nil, quality: .unknown, tags: ["DV", "ATMOS"], containsTags: []),
            .init(raw: "4K | Avatar (2009) [MULTI] HDR", title: "Avatar", key: "avatar", quality: .uhd, tags: nil, containsTags: ["MULTI", "HDR"]),
            .init(raw: "Inception VF", title: "Inception", key: nil, quality: .unknown, tags: ["VF"], containsTags: []),
        ]
        for _ in 0..<2 {
            for (index, testCase) in cases.enumerated() {
                _ = TitleNormalizer.normalize(cases[(index + 1) % cases.count].raw) // interleave: keys can't cross-talk
                let n = TitleNormalizer.normalize(testCase.raw)
                #expect(n.title == testCase.title, "\(testCase.raw)")
                if let key = testCase.key { #expect(n.key == key, "\(testCase.raw)") }
                #expect(n.quality == testCase.quality, "\(testCase.raw)")
                if let tags = testCase.tags { #expect(n.tags == tags, "\(testCase.raw)") }
                for tag in testCase.containsTags { #expect(n.tags.contains(tag), "\(testCase.raw)") }
            }
        }
    }

    @Test func memoizedHelpersNeverLeakAcrossInputs() {
        // Same keyed-memo contract for `cleanCategoryName` and the strict/loose adult
        // verdicts: distinct inputs — and distinct strictness levels — stay isolated.
        let categories = [
            ("FR | FILMS ACTION", "Films Action"),
            ("|FR| SÉRIES TV", "Séries TV"),
            ("UK | BBC CHANNELS", "BBC Channels"),
            ("===== DOCUMENTAIRES =====", "Documentaires"),
        ]
        for _ in 0..<2 {
            for (index, pair) in categories.enumerated() {
                _ = TitleNormalizer.cleanCategoryName(categories[(index + 1) % categories.count].0)
                #expect(TitleNormalizer.cleanCategoryName(pair.0) == pair.1, "\(pair.0)")
            }
        }
        // "hot" is an adult marker in the loose pass but legitimate in titles: the strict
        // and loose memos must never share a verdict.
        for _ in 0..<2 {
            #expect(TitleNormalizer.isAdult("Hot Fuzz") == true)
            #expect(TitleNormalizer.isAdultName("Hot Fuzz") == false)
            #expect(TitleNormalizer.isAdult("XXX Films") == true)
            #expect(TitleNormalizer.isAdultName("XXX Films") == true)
            #expect(TitleNormalizer.isAdult("Films Action") == false)
            #expect(TitleNormalizer.isAdultName("Films Action") == false)
        }
    }
}
