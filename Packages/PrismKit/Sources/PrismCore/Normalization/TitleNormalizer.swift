import Foundation
import Synchronization

/// Result of cleaning a raw IPTV name ("FR: TF1 HD", "4K | Avatar (2009) [MULTI] HDR"…).
public struct NormalizedName: Sendable, Hashable {
    /// Cleaned display title, original casing: "Avatar", "TF1", "The Bear".
    public var title: String
    /// Grouping key: lowercased, diacritics folded, punctuation collapsed to single spaces ("the bear").
    public var key: String
    public var year: Int?
    public var quality: VideoQuality
    /// Uppercase normalized tokens found & removed, deduped, in order of appearance: ["FR"], ["MULTI", "HDR"].
    public var tags: [String]
    public var season: Int?
    public var episode: Int?
    /// "##### FRANCE #####", "----- SPORT -----", "★★★ NEWS ★★★" style dummy entries.
    public var isSeparator: Bool
    /// Text found after a series marker ("Breaking Bad S01E01 Pilot" → "Pilot"), tags removed.
    public var episodeTitle: String?

    public init(
        title: String, key: String, year: Int? = nil, quality: VideoQuality = .unknown, tags: [String] = [],
        season: Int? = nil, episode: Int? = nil, isSeparator: Bool = false, episodeTitle: String? = nil
    ) {
        self.title = title
        self.key = key
        self.year = year
        self.quality = quality
        self.tags = tags
        self.season = season
        self.episode = episode
        self.isSeparator = isSeparator
        self.episodeTitle = episodeTitle
    }
}

/// Fast, allocation-light cleaner for IPTV titles. Pure functions, safe to call from any thread.
public enum TitleNormalizer {
    /// Bounded memoization: `normalize` is pure and runs once per catalog item (100k+) with heavy
    /// duplication across variants and sources. `Mutex` keeps `@concurrent` callers safe.
    private static let cache = NormalizeCache()

    public static func normalize(_ raw: String) -> NormalizedName {
        if let hit = cache.value(for: raw) { return hit }
        var work = NameWork(raw)
        let result = work.normalize()
        cache.store(result, for: raw)
        return result
    }

    /// Grouping key: lowercase, diacritics folded (é → e, œ → oe, ß → ss), apostrophes removed,
    /// `+` spelled " plus ", any other punctuation/symbol collapsed to a single space.
    public static func key(_ text: String) -> String {
        NameFolding.key(text)
    }

    /// "FR | FILMS ACTION" → "Films Action", "|FR| SÉRIES TV ⚽" → "Séries TV".
    /// Strips leading country/language prefixes, separators, emoji and decorations; smart
    /// title-cases only when the input is ALL CAPS.
    public static func cleanCategoryName(_ raw: String) -> String {
        var work = NameWork(raw)
        return work.cleanCategory()
    }

    /// Adult-content heuristic for category names (and other free text): `xxx`, `adult(s)`,
    /// `adulte(s)`, `18+`, `+18`, `porn(o)`, `hot`, `sexy`, adult studio names…
    public static func isAdult(_ text: String) -> Bool {
        NameFolding.isAdult(text, strict: false)
    }

    /// Stricter variant used for content names, where words such as "hot" are legitimate
    /// ("Hot Fuzz"): only strong markers (xxx, porn, 18+, adult…) match.
    public static func isAdultName(_ text: String) -> Bool {
        NameFolding.isAdult(text, strict: true)
    }

    /// `isAdultName` on an already normalized name (title key + removed tags), avoiding a second fold.
    public static func isAdultName(_ name: NormalizedName) -> Bool {
        name.tags.contains("XXX") || NameFolding.isAdult(key: name.key, strict: true)
    }
}

// MARK: - Token tables

enum NameTokenInfo: Sendable, Equatable {
    case quality(VideoQuality)
    case tag(String)
    /// Removed but not recorded (release noise, "BACKUP"…).
    case drop
}

/// Up to 16 uppercase ASCII bytes packed in two words: hashing is much cheaper than `String`.
struct PackedKey: Hashable, Sendable {
    var a: UInt64 = 0
    var b: UInt64 = 0
    var count = 0

    init() {}
    init(_ string: String) {
        for byte in string.utf8 { _ = append(byte) }
    }

    @inline(__always) mutating func append(_ byte: UInt8) -> Bool {
        guard count < 16 else { return false }
        if count < 8 { a |= UInt64(byte) << UInt64(count * 8) } else { b |= UInt64(byte) << UInt64((count - 8) * 8) }
        count += 1
        return true
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(a)
        hasher.combine(b)
        hasher.combine(count)
    }

    static func == (lhs: PackedKey, rhs: PackedKey) -> Bool { lhs.a == rhs.a && lhs.b == rhs.b && lhs.count == rhs.count }
}

/// Thread-safe bounded memo for `TitleNormalizer.normalize` (same pattern as `ResolutionMemo` in PrismData).
private final class NormalizeCache: Sendable {
    private struct State {
        var map: [String: NormalizedName] = [:]
    }
    private let state = Mutex(State())
    private let limit = 100_000

    func value(for key: String) -> NormalizedName? {
        state.withLock { $0.map[key] }
    }

    func store(_ value: NormalizedName, for key: String) {
        state.withLock { state in
            if state.map.count >= limit { state.map.removeAll(keepingCapacity: true) }
            state.map[key] = value
        }
    }
}

struct NameTableEntry: Sendable {
    let info: NameTokenInfo
    /// Only matches when the source token has no lowercase letters ("FRENCH" but not "French").
    let uppercaseOnly: Bool
}

enum NameTables {
    static let tokens: [PackedKey: NameTableEntry] = {
        var t: [PackedKey: NameTableEntry] = [:]
        func q(_ keys: [String], _ v: VideoQuality) { for k in keys { t[PackedKey(k)] = NameTableEntry(info: .quality(v), uppercaseOnly: false) } }
        func tag(_ keys: [String], _ v: String, upper: Bool = false) { for k in keys { t[PackedKey(k)] = NameTableEntry(info: .tag(v), uppercaseOnly: upper) } }
        func drop(_ keys: [String], upper: Bool = false) { for k in keys { t[PackedKey(k)] = NameTableEntry(info: .drop, uppercaseOnly: upper) } }

        q(["SD", "360P", "480P", "540P", "576P", "576I", "SDTV"], .sd)
        q(["HD", "HD+", "720P", "720I", "HDTV"], .hd)
        q(["FHD", "FHD+", "FULLHD", "1080P", "1080I", "1440P", "QHD"], .fhd)
        q(["UHD", "4K", "4KUHD", "UHD4K", "ULTRAHD", "2160P", "8K", "4320P", "UHDTV"], .uhd)

        tag(["HEVC", "H265", "X265", "HEVC10"], "HEVC")
        tag(["H264", "X264"], "H264")
        tag(["HDR", "HDR10", "HDR10+", "HLG"], "HDR")
        tag(["DV", "DOVI", "DOLBYVISION"], "DV")
        tag(["ATMOS", "DOLBYATMOS"], "ATMOS")
        tag(["3D"], "3D")
        tag(["10BIT"], "10BIT")
        tag(["VF"], "VF")
        tag(["VFF"], "VFF")
        tag(["VFQ"], "VFQ")
        tag(["VFI"], "VFI")
        tag(["VF2"], "VF2")
        tag(["VOST"], "VOST")
        tag(["VOSTFR", "VOSTF"], "VOSTFR")
        tag(["VOSTA", "VOSTENG"], "VOSTA")
        tag(["VO"], "VO")
        tag(["MULTI", "MULTIAUDIO", "MULTILANG"], "MULTI")
        tag(["MULTISUB", "MULTISUBS"], "MULTI-SUB")
        tag(["TRUEFRENCH"], "TRUEFRENCH")
        tag(["FRENCH"], "FRENCH", upper: true)
        tag(["SUBFRENCH"], "SUBFRENCH")
        tag(["50FPS", "FPS50"], "50FPS")
        tag(["60FPS", "FPS60"], "60FPS")

        drop(["BACKUP", "BKP", "HQ", "LQ", "SDR", "WEBDL", "WEBRIP", "BLURAY", "BDRIP", "BRRIP", "DVDRIP",
              "HDRIP", "REMUX", "HDLIGHT", "4KLIGHT", "AC3", "EAC3", "DTS", "AAC", "DD51", "DDP51",
              "MKV", "MP4", "M4V"])
        drop(["VIP", "RAW", "VOD", "AVI", "WEB"], upper: true)
        return t
    }()

    /// Joined forms of two-word tags ("FULL HD", "DOLBY-VISION", "MULTI-SUB", "H 265"…).
    static let compounds: Set<PackedKey> = Set([
        "FULLHD", "ULTRAHD", "DOLBYVISION", "DOLBYATMOS", "MULTISUB", "MULTISUBS", "MULTIAUDIO", "WEBDL",
        "H265", "H264", "X265", "X264", "HDR10", "HDR10+", "BLURAY", "4KUHD", "UHD4K", "FHD+", "VOSTFR",
    ].map(PackedKey.init))

    /// Three-letter (and a few longer region) codes accepted as prefixes ("USA:", "EXYU |").
    static let longCodes: Set<String> = [
        "USA", "ARA", "FRA", "GER", "DEU", "ITA", "ESP", "SPA", "POR", "TUR", "POL", "RUS", "NLD", "NED",
        "ENG", "LAT", "KUR", "PER", "IND", "PAK", "AFG", "ALB", "BEL", "CAN", "CHN", "MAR", "ALG", "TUN",
        "BRA", "MEX", "ARG", "AUS", "AUT", "SUI", "SWE", "NOR", "DNK", "DEN", "FIN", "GRE", "GRC", "ROM",
        "ROU", "HUN", "CZE", "SVK", "SRB", "HRV", "CRO", "BIH", "MKD", "BGR", "BUL", "UKR", "ISR", "IRN",
        "IRQ", "KSA", "UAE", "QAT", "EGY", "LBN", "SYR", "JOR", "KWT", "OMN", "YEM", "SOM", "ETH", "NGR",
        "GHA", "AFR", "JPN", "KOR", "THA", "VIE", "VNM", "PHI", "PHL", "IDN", "MYS", "SGP", "BGD", "LKA",
        "NEP", "ARM", "AZE", "GEO", "KAZ", "UZB", "LUX", "IRL", "SCO", "WAL", "CYP", "MLT", "SLO", "SVN",
        "EXYU", "LATAM", "ASIA", "ARAB", "AFRICA", "MENA", "CARIB", "INT",
    ]

    /// Two-letter codes stripped at the end of a title when introduced by a separator ("Avatar - FR").
    static let trailingCodes: Set<String> = [
        "FR", "EN", "UK", "US", "DE", "ES", "IT", "PT", "NL", "BE", "CH", "CA", "QC", "AR", "TR", "PL", "RU",
    ]

    static let seasonWords: Set<PackedKey> = Set(["SAISON", "SEASON", "TEMPORADA", "STAFFEL", "STAGIONE", "SEIZOEN", "SEZON"].map(PackedKey.init))
    static let episodeWords: Set<PackedKey> = Set(["EPISODE", "EPISODES", "EPISODIO", "EP", "EPS", "E", "FOLGE", "AFLEVERING", "CAPITULO"].map(PackedKey.init))

    /// Recomputed on access: a frozen value would mislabel the year-boundary `upper` bound
    /// (`currentYear + 2`) for the whole process lifetime.
    static var currentYear: Int { Calendar(identifier: .gregorian).component(.year, from: Date()) }
}

// MARK: - Lexer + pipeline

struct NameToken {
    enum Kind: UInt8 { case word, sep, open, close }
    var kind: Kind
    var start: Int
    var end: Int
    var spaceBefore: Bool
    /// Separator made only of decorative symbols / emoji: rendered as a space.
    var isDeco: Bool
}

/// Placeholder scalar for decorative symbols (★, ▶, ●, emoji, box drawing…).
private let decoScalar = Unicode.Scalar(UInt8(1))
private let spaceScalar = Unicode.Scalar(UInt8(0x20))

struct NameWork {
    var s: [Unicode.Scalar] = []
    var toks: [NameToken] = []
    var tags: [String] = []
    var quality: VideoQuality = .unknown
    var year: Int?
    let raw: String

    init(_ raw: String) {
        self.raw = raw
        var flags: [String] = []
        s = Self.preprocess(raw, flags: &flags)
        tags = flags
        tokenize()
    }

    // MARK: Preprocessing

    private static func preprocess(_ raw: String, flags: inout [String]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(raw.utf8.count)
        var hasSpace = false
        var dots = 0
        var underscores = 0
        var pendingRegional: UInt32 = 0
        var inSuper = false

        for c in raw.unicodeScalars {
            let v = c.value
            if v < 0x80 {
                if inSuper { out.append(spaceScalar); inSuper = false }
                pendingRegional = 0
                if v < 0x20 || v == 0x7F {
                    out.append(spaceScalar)
                    hasSpace = true
                } else {
                    if v == 0x20 { hasSpace = true } else if v == 0x2E { dots += 1 } else if v == 0x5F { underscores += 1 }
                    out.append(c)
                }
                continue
            }
            if v >= 0x1F1E6 && v <= 0x1F1FF {
                if pendingRegional != 0 {
                    var code = ""
                    code.unicodeScalars.append(Unicode.Scalar(UInt8(pendingRegional - 0x1F1E6 + 65)))
                    code.unicodeScalars.append(Unicode.Scalar(UInt8(v - 0x1F1E6 + 65)))
                    if code == "GB" { code = "UK" }
                    flags.append(code)
                    pendingRegional = 0
                } else {
                    pendingRegional = v
                    out.append(decoScalar)
                }
                continue
            }
            pendingRegional = 0
            if let sup = superscriptLetter(v) {
                if !inSuper {
                    if let last = out.last, last != spaceScalar { out.append(spaceScalar) }
                    inSuper = true
                }
                out.append(sup)
                continue
            }
            if inSuper { out.append(spaceScalar); inSuper = false }

            // Fast path: Latin-1 / Latin Extended-A letters.
            if (v >= 0xC0 && v <= 0x24F && v != 0xD7 && v != 0xF7) {
                out.append(c)
                continue
            }
            switch v {
            case 0xA0, 0x2000...0x200A, 0x202F, 0x205F, 0x3000, 0x1680:
                out.append(spaceScalar); hasSpace = true; continue
            case 0x200B...0x200D, 0x2060, 0xFEFF, 0xFE00...0xFE0F, 0xE0000...0xE007F, 0x1F3FB...0x1F3FF, 0x20E3, 0xAD:
                continue
            case 0x2010...0x2015, 0x2212, 0xFE58, 0xFE63:
                out.append(Unicode.Scalar(UInt8(0x2D))); continue
            case 0x2018, 0x2019, 0x201B, 0x2032, 0xB4:
                out.append(Unicode.Scalar(UInt8(0x27))); continue
            case 0x201C, 0x201D, 0x201E, 0x2033:
                out.append(Unicode.Scalar(UInt8(0x22))); continue
            case 0x2026:
                out.append(c); continue
            case 0xFF01...0xFF5E:
                if let mapped = Unicode.Scalar(v - 0xFEE0) { out.append(mapped) }
                continue
            default:
                break
            }
            switch c.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber,
                 .connectorPunctuation:
                out.append(c)
            case .spaceSeparator, .lineSeparator, .paragraphSeparator:
                out.append(spaceScalar); hasSpace = true
            case .control, .format:
                continue
            case .dashPunctuation:
                out.append(Unicode.Scalar(UInt8(0x2D)))
            default:
                out.append(decoScalar)
            }
        }

        // Scene style names: "The.Bear.S02E05.MULTI.1080p" → spaces.
        if !hasSpace && (dots >= 2 || underscores >= 1) {
            let count = out.count
            for i in 0..<count {
                let v = out[i].value
                if v == 0x5F {
                    out[i] = spaceScalar
                } else if v == 0x2E {
                    let prevDigit = i > 0 && isDigit(out[i - 1].value)
                    let nextDigit = i + 1 < count && isDigit(out[i + 1].value)
                    if !(prevDigit && nextDigit) { out[i] = spaceScalar }
                }
            }
        }
        return out
    }

    private static func superscriptLetter(_ v: UInt32) -> Unicode.Scalar? {
        let mapped: UInt8
        switch v {
        case 0x1D2C: mapped = 0x41 // ᴬ
        case 0x1D2E: mapped = 0x42 // ᴮ
        case 0x1D30: mapped = 0x44 // ᴰ
        case 0x1D31: mapped = 0x45 // ᴱ
        case 0x1D33: mapped = 0x47 // ᴳ
        case 0x1D34: mapped = 0x48 // ᴴ
        case 0x1D35: mapped = 0x49 // ᴵ
        case 0x1D36: mapped = 0x4A // ᴶ
        case 0x1D37: mapped = 0x4B // ᴷ
        case 0x1D38: mapped = 0x4C // ᴸ
        case 0x1D39: mapped = 0x4D // ᴹ
        case 0x1D3A: mapped = 0x4E // ᴺ
        case 0x1D3C: mapped = 0x4F // ᴼ
        case 0x1D3E: mapped = 0x50 // ᴾ
        case 0x1D3F: mapped = 0x52 // ᴿ
        case 0x1D40: mapped = 0x54 // ᵀ
        case 0x1D41: mapped = 0x55 // ᵁ
        case 0x1D42: mapped = 0x57 // ᵂ
        case 0x2C7D: mapped = 0x56 // ⱽ
        case 0x02E2: mapped = 0x53 // ˢ
        case 0x1DA0: mapped = 0x46 // ᶠ
        case 0x02E3: mapped = 0x58 // ˣ
        case 0x02B0: mapped = 0x48 // ʰ
        case 0x1D48: mapped = 0x44 // ᵈ
        case 0x1D4F: mapped = 0x4B // ᵏ
        case 0x1D56: mapped = 0x50 // ᵖ
        case 0x1D5B: mapped = 0x56 // ᵛ
        case 0x1D49: mapped = 0x45 // ᵉ
        case 0x029C: mapped = 0x48 // ʜ
        case 0x1D05: mapped = 0x44 // ᴅ
        case 0x1D0B: mapped = 0x4B // ᴋ
        case 0x1D1C: mapped = 0x55 // ᴜ
        case 0xA730: mapped = 0x46 // ꜰ
        case 0xA731: mapped = 0x53 // ꜱ
        case 0x2070: mapped = 0x30 // ⁰
        case 0x00B9: mapped = 0x31 // ¹
        case 0x00B2: mapped = 0x32 // ²
        case 0x00B3: mapped = 0x33 // ³
        case 0x2074...0x2079: mapped = UInt8(0x34 + v - 0x2074) // ⁴…⁹
        case 0x207A: mapped = 0x2B // ⁺
        default: return nil
        }
        return Unicode.Scalar(mapped)
    }

    // MARK: Tokenizer

    @inline(__always) static func isDigit(_ v: UInt32) -> Bool { v >= 0x30 && v <= 0x39 }

    @inline(__always) private static func isSepScalar(_ v: UInt32) -> Bool {
        switch v {
        case 1, 0x7C, 0x3A, 0x2D, 0x2F, 0x5C, 0x2C, 0x3B, 0x7E, 0x3D, 0x23, 0x2A, 0x5F, 0x3C, 0x3E, 0x22: true
        default: false
        }
    }

    private mutating func tokenize() {
        toks.reserveCapacity(16)
        var i = 0
        let n = s.count
        var space = false
        while i < n {
            let v = s[i].value
            if v == 0x20 || v == 0x09 {
                space = true
                i += 1
                continue
            }
            if v == 0x28 || v == 0x5B || v == 0x7B {
                toks.append(NameToken(kind: .open, start: i, end: i + 1, spaceBefore: space, isDeco: false))
                i += 1
            } else if v == 0x29 || v == 0x5D || v == 0x7D {
                toks.append(NameToken(kind: .close, start: i, end: i + 1, spaceBefore: space, isDeco: false))
                i += 1
            } else if Self.isSepScalar(v) {
                let start = i
                var deco = true
                while i < n, Self.isSepScalar(s[i].value) {
                    if s[i].value != 1 { deco = false }
                    i += 1
                }
                toks.append(NameToken(kind: .sep, start: start, end: i, spaceBefore: space, isDeco: deco))
            } else {
                let start = i
                while i < n {
                    let w = s[i].value
                    if w == 0x20 || w == 0x09 || w == 0x28 || w == 0x5B || w == 0x7B || w == 0x29 || w == 0x5D || w == 0x7D || Self.isSepScalar(w) { break }
                    i += 1
                }
                toks.append(NameToken(kind: .word, start: start, end: i, spaceBefore: space, isDeco: false))
            }
            space = false
        }
    }

    // MARK: Token helpers

    /// Appends the uppercase ASCII lookup form of `t` ("." and "'" removed, accented Latin folded).
    /// Returns false when the token can't be a tag (too long, other punctuation, non-Latin).
    func appendUpper(_ t: NameToken, to key: inout PackedKey) -> Bool {
        let len = t.end - t.start
        guard len > 0, len <= 16 else { return false }
        for i in t.start..<t.end {
            let v = s[i].value
            let byte: UInt8
            switch v {
            case 0x61...0x7A: byte = UInt8(v - 32)
            case 0x41...0x5A, 0x30...0x39, 0x2B: byte = UInt8(v)
            case 0x2E, 0x27: continue
            case 0xC8...0xCB, 0xE8...0xEB: byte = 0x45
            case 0xC0...0xC5, 0xE0...0xE5: byte = 0x41
            case 0xCC...0xCF, 0xEC...0xEF: byte = 0x49
            case 0xD2...0xD6, 0xF2...0xF6: byte = 0x4F
            case 0xD9...0xDC, 0xF9...0xFC: byte = 0x55
            default: return false
            }
            guard key.append(byte) else { return false }
        }
        return true
    }

    func upperKey(_ t: NameToken) -> PackedKey? {
        guard t.kind == .word else { return nil }
        var key = PackedKey()
        return appendUpper(t, to: &key) && key.count > 0 ? key : nil
    }

    func hasLowercase(_ t: NameToken) -> Bool {
        for i in t.start..<t.end {
            let v = s[i].value
            if v >= 0x61 && v <= 0x7A { return true }
            if v >= 0xDF && v <= 0xFF && v != 0xF7 { return true }
        }
        return false
    }

    func info(_ t: NameToken) -> NameTokenInfo? {
        guard let key = upperKey(t), let entry = NameTables.tokens[key] else { return nil }
        if entry.uppercaseOnly && hasLowercase(t) { return nil }
        return entry.info
    }

    /// 2 uppercase ASCII letters, or a known longer region code. `lenient` accepts lowercase
    /// ("[fr]") and any 3-letter code (used inside brackets).
    func countryCode(_ t: NameToken, lenient: Bool) -> String? {
        guard t.kind == .word else { return nil }
        let len = t.end - t.start
        guard len >= 2, len <= 6 else { return nil }
        var upper = 0
        var lower = 0
        for i in t.start..<t.end {
            let v = s[i].value
            if v >= 0x41 && v <= 0x5A { upper += 1 } else if v >= 0x61 && v <= 0x7A { lower += 1 } else { return nil }
        }
        if lower > 0 && !(lenient && upper == 0) { return nil }
        var code = ""
        for i in t.start..<t.end { code.unicodeScalars.append(Unicode.Scalar(UInt8(s[i].value & ~0x20))) }
        if len == 2 { return code }
        if len == 3 && lenient { return code }
        return NameTables.longCodes.contains(code) ? code : nil
    }

    func number(_ t: NameToken, maxDigits: Int = 4) -> Int? {
        guard t.kind == .word else { return nil }
        let len = t.end - t.start
        guard len > 0, len <= maxDigits else { return nil }
        var value = 0
        for i in t.start..<t.end {
            let v = s[i].value
            guard Self.isDigit(v) else { return nil }
            value = value * 10 + Int(v - 0x30)
        }
        return value
    }

    func year(_ t: NameToken, upper: Int) -> Int? {
        guard t.end - t.start == 4, let value = number(t) else { return nil }
        return (1900...upper).contains(value) ? value : nil
    }

    func sepContainsPipe(_ t: NameToken) -> Bool {
        guard t.kind == .sep else { return false }
        for i in t.start..<t.end where s[i].value == 0x7C || s[i].value == 1 { return true }
        return false
    }

    mutating func addTag(_ tag: String) {
        if !tags.contains(tag) { tags.append(tag) }
    }

    mutating func apply(_ info: NameTokenInfo) {
        switch info {
        case .quality(let q): if q > quality { quality = q }
        case .tag(let tag): addTag(tag)
        case .drop: break
        }
    }

    /// Compound tag spanning two words ("FULL HD", "DOLBY-VISION", "MULTI-SUB").
    func compound(_ first: NameToken, _ second: NameToken) -> NameTokenInfo? {
        guard first.kind == .word, second.kind == .word else { return nil }
        var key = PackedKey()
        guard appendUpper(first, to: &key), appendUpper(second, to: &key),
              NameTables.compounds.contains(key), let entry = NameTables.tokens[key] else { return nil }
        return entry.info
    }

    @inline(__always) static func hasWord(_ t: ArraySlice<NameToken>) -> Bool {
        for token in t where token.kind == .word { return true }
        return false
    }

    // MARK: Separator lines

    func sepLineCount(_ t: NameToken) -> Int {
        guard t.kind == .sep else { return 0 }
        for i in t.start..<t.end {
            switch s[i].value {
            case 1, 0x23, 0x3D, 0x2D, 0x2A, 0x7E, 0x5F, 0x3C, 0x3E, 0x7C: continue
            default: return 0
            }
        }
        return t.end - t.start
    }

    func separatorLine(_ t: [NameToken]) -> Bool {
        guard !t.isEmpty else { return false }
        var leading = 0
        for token in t {
            let n = sepLineCount(token)
            if n == 0 { break }
            leading += n
        }
        var trailing = 0
        for token in t.reversed() {
            let n = sepLineCount(token)
            if n == 0 { break }
            trailing += n
        }
        return leading >= 3 || trailing >= 3 || (leading >= 2 && trailing >= 2)
    }

    // MARK: Passes

    /// Leading "FR:", "|FR|", "UK -", "4K |", "VOSTFR -", "FR HD:", "FR ▎" … (repeatable).
    mutating func stripPrefixes(strictCodesOnly: Bool = false) {
        while true {
            var p = 0
            while p < toks.count, toks[p].kind == .sep { p += 1 }
            guard p < toks.count, toks[p].kind == .word else { return }

            // Run of up to 3 code/tag words followed by a separator, then real content.
            var q = p
            var count = 0
            while q < toks.count, toks[q].kind == .word, count < 3 {
                if let info = info(toks[q]), !strictCodesOnly || info == .drop {
                } else if countryCode(toks[q], lenient: false) == nil {
                    break
                }
                q += 1
                count += 1
            }
            if count > 0, q < toks.count, toks[q].kind == .sep,
               toks[(q + 1)...].contains(where: { $0.kind == .word || $0.kind == .open }) {
                for k in p..<q {
                    if let info = info(toks[k]), !strictCodesOnly || info == .drop {
                        apply(info)
                    } else if let code = countryCode(toks[k], lenient: false) {
                        addTag(code)
                    }
                }
                toks.removeFirst(q + 1)
                continue
            }
            // Leading quality token without separator ("4K Avatar", "HD TF1").
            if !strictCodesOnly, let info = info(toks[p]), case .quality = info,
               p + 1 < toks.count, toks[p + 1].kind == .word {
                apply(info)
                toks.removeFirst(p + 1)
                continue
            }
            return
        }
    }

    /// Bracket groups: "(2009)" → year, "[MULTI]", "(FR)", "[4K HDR]" → tags. Other groups kept.
    mutating func processBrackets(codesOnly: Bool = false) {
        var hasBracket = false
        for t in toks where t.kind == .open || t.kind == .close { hasBracket = true; break }
        guard hasBracket else { return }

        var removed = [Bool](repeating: false, count: toks.count)
        var stack: [Int] = []
        for i in 0..<toks.count {
            switch toks[i].kind {
            case .open:
                stack.append(i)
            case .close:
                guard let o = stack.popLast() else {
                    toks[i].kind = .sep
                    continue
                }
                var absorb = true
                var foundYear: Int?
                var infos: [NameTokenInfo] = []
                var codes: [String] = []
                var k = o + 1
                while k < i {
                    let t = toks[k]
                    if removed[k] || t.kind != .word { k += 1; continue }
                    var next = k + 1
                    while next < i, removed[next] || toks[next].kind == .sep { next += 1 }
                    if next < i, !codesOnly, let info = compound(t, toks[next]) {
                        infos.append(info)
                        k = next + 1
                        continue
                    }
                    if !codesOnly, foundYear == nil, let y = year(t, upper: 2100) {
                        foundYear = y
                    } else if !codesOnly, let info = info(t) {
                        infos.append(info)
                    } else if let code = countryCode(t, lenient: true) {
                        codes.append(code)
                    } else {
                        absorb = false
                        break
                    }
                    k += 1
                }
                if absorb {
                    if let foundYear, year == nil { year = foundYear }
                    for info in infos { apply(info) }
                    for code in codes { addTag(code) }
                    for k in o...i { removed[k] = true }
                }
            default:
                continue
            }
        }
        for o in stack { toks[o].kind = .sep }
        var kept: [NameToken] = []
        kept.reserveCapacity(toks.count)
        for i in toks.indices where !removed[i] { kept.append(toks[i]) }
        toks = kept
    }

    struct SeriesMatch {
        var season: Int?
        var episode: Int?
        var first: Int
        var last: Int
    }

    /// Finds S01E02 / S01 E02 / S1.E2 / 1x02 / Saison 1 Épisode 2 / Season 1 Episode 2 / trailing "S02".
    func findSeries(_ t: [NameToken]) -> SeriesMatch? {
        var seenWord = false
        for i in 0..<t.count where t[i].kind == .word {
            let token = t[i]
            let first = s[token.start].value | 0x20
            let isFirstWord = !seenWord
            seenWord = true
            if Self.isDigit(s[token.start].value) {
                if let (season, episode) = parseX(token) {
                    return SeriesMatch(season: season, episode: episode, first: i, last: i)
                }
                continue
            }
            guard first == 0x73 else { continue } // s / S
            if let (season, episode) = parseSE(token) {
                return SeriesMatch(season: season, episode: episode, first: i, last: i)
            }
            if let season = parseSeasonToken(token) {
                if let n = nextWord(t, after: i, allowSep: true) {
                    if let episode = parseEpisodeToken(t[n]) {
                        return SeriesMatch(season: season, episode: episode, first: i, last: n)
                    }
                    if let k = upperKey(t[n]), NameTables.episodeWords.contains(k),
                       let m = nextWord(t, after: n, allowSep: false), let episode = number(t[m]) {
                        return SeriesMatch(season: season, episode: episode, first: i, last: m)
                    }
                }
                // Season pack: "The Bear S02" (only tags after it).
                if !isFirstWord, t[(i + 1)...].allSatisfy({ $0.kind != .word || info($0) != nil }) {
                    return SeriesMatch(season: season, episode: nil, first: i, last: i)
                }
                continue
            }
            // Saison 1 Episode 2
            let len = token.end - token.start
            guard len >= 6, len <= 9, let k = upperKey(token), NameTables.seasonWords.contains(k),
                  let n = nextWord(t, after: i, allowSep: false), let season = number(t[n], maxDigits: 3) else { continue }
            var last = n
            var episode: Int?
            if let e = nextWord(t, after: n, allowSep: true) {
                if let ep = parseEpisodeToken(t[e]) {
                    episode = ep
                    last = e
                } else if let ek = upperKey(t[e]), NameTables.episodeWords.contains(ek),
                          let m = nextWord(t, after: e, allowSep: false), let ep = number(t[m]) {
                    episode = ep
                    last = m
                }
            }
            if isFirstWord && !Self.hasWord(t[(last + 1)...]) { continue }
            return SeriesMatch(season: season, episode: episode, first: i, last: last)
        }
        return nil
    }

    /// Index of the next word after `i`, separated only by spaces or (when `allowSep`) one short separator.
    func nextWord(_ t: [NameToken], after i: Int, allowSep: Bool) -> Int? {
        var n = i + 1
        if allowSep, n < t.count, t[n].kind == .sep, t[n].end - t[n].start == 1 { n += 1 }
        return n < t.count && t[n].kind == .word ? n : nil
    }

    func parseSE(_ t: NameToken) -> (Int, Int)? {
        var i = t.start
        let end = t.end
        guard end - i >= 4, s[i].value | 0x20 == 0x73 else { return nil }
        i += 1
        var season = 0, digits = 0
        while i < end, Self.isDigit(s[i].value), digits < 3 { season = season * 10 + Int(s[i].value - 0x30); i += 1; digits += 1 }
        guard digits > 0, i < end else { return nil }
        if s[i].value == 0x2E || s[i].value == 0x5F { i += 1 }
        guard i < end, s[i].value | 0x20 == 0x65 else { return nil }
        i += 1
        if i < end, s[i].value | 0x20 == 0x70 { i += 1 }
        var episode = 0
        digits = 0
        while i < end, Self.isDigit(s[i].value), digits < 4 { episode = episode * 10 + Int(s[i].value - 0x30); i += 1; digits += 1 }
        guard digits > 0 else { return nil }
        if i < end, s[i].value | 0x20 != 0x65 { return nil }
        return (season, episode)
    }

    func parseX(_ t: NameToken) -> (Int, Int)? {
        var i = t.start
        let end = t.end
        var season = 0, digits = 0
        // Digit runs are bounded before accumulating: a 20-digit run would overflow `Int`.
        while i < end, Self.isDigit(s[i].value) {
            if digits < 3 { season = season * 10 + Int(s[i].value - 0x30) }
            i += 1; digits += 1
        }
        guard digits >= 1, digits <= 2, i < end, s[i].value | 0x20 == 0x78 else { return nil }
        i += 1
        var episode = 0
        digits = 0
        while i < end, Self.isDigit(s[i].value) {
            if digits < 4 { episode = episode * 10 + Int(s[i].value - 0x30) }
            i += 1; digits += 1
        }
        guard i == end, digits >= 2, digits <= 3 else { return nil }
        return (season, episode)
    }

    func parseSeasonToken(_ t: NameToken) -> Int? {
        let len = t.end - t.start
        guard len >= 2, len <= 4, s[t.start].value | 0x20 == 0x73 else { return nil }
        var value = 0
        for i in (t.start + 1)..<t.end {
            guard Self.isDigit(s[i].value) else { return nil }
            value = value * 10 + Int(s[i].value - 0x30)
        }
        return value
    }

    func parseEpisodeToken(_ t: NameToken) -> Int? {
        let len = t.end - t.start
        guard t.kind == .word, len >= 2, len <= 6, s[t.start].value | 0x20 == 0x65 else { return nil }
        var i = t.start + 1
        if s[i].value | 0x20 == 0x70 { i += 1 }
        guard i < t.end else { return nil }
        var value = 0
        while i < t.end {
            guard Self.isDigit(s[i].value) else { return nil }
            value = value * 10 + Int(s[i].value - 0x30)
            i += 1
        }
        return value
    }

    /// Removes trailing tags, quality, years and separators from `t`. Tags are recorded in
    /// order of appearance.
    mutating func stripTrailing(_ t: inout [NameToken], keepOneWord: Bool) {
        var found: [NameTokenInfo] = []
        var codes: [String] = []
        defer {
            for info in found.reversed() { apply(info) }
            for code in codes.reversed() { addTag(code) }
        }
        while true {
            var z = t.count - 1
            var droppedPipe = false
            var droppedAny = false
            while z >= 0, t[z].kind == .sep || t[z].kind == .open {
                if sepContainsPipe(t[z]) { droppedPipe = true }
                droppedAny = true
                z -= 1
            }
            guard z >= 0, t[z].kind == .word else { return }
            let wordsBefore = Self.hasWord(t[..<z])
            if keepOneWord && !wordsBefore { return }
            let last = t[z]

            // Compound with the previous word.
            if z >= 1 {
                var y = z - 1
                if t[y].kind == .sep, t[y].end - t[y].start == 1, !t[y].spaceBefore, !last.spaceBefore { y -= 1 }
                if y >= 0, t[y].kind == .word, let info = compound(t[y], last), !keepOneWord || Self.hasWord(t[..<y]) {
                    found.append(info)
                    t.removeSubrange(y...)
                    continue
                }
            }
            if let info = info(last) {
                found.append(info)
                t.removeSubrange(z...)
                continue
            }
            if year == nil, wordsBefore, let y = self.year(last, upper: NameTables.currentYear + 2) {
                year = y
                t.removeSubrange(z...)
                continue
            }
            if wordsBefore, z >= 1, let code = countryCode(last, lenient: false), code.count == 2 {
                let prev = t[z - 1]
                let introducedBySeparator = prev.kind == .sep
                    && ((sepContainsPipe(prev) && droppedPipe) || (NameTables.trailingCodes.contains(code) && !droppedAny))
                // "Sky Cinema HD UK": a country code right after a quality / tag token.
                let afterTag = prev.kind == .word && NameTables.trailingCodes.contains(code) && info(prev) != nil
                if introducedBySeparator || afterTag {
                    codes.append(code)
                    t.removeSubrange(z...)
                    continue
                }
            }
            return
        }
    }

    /// Renders tokens, trimming leading/trailing separators; decorative separators become spaces.
    func render(_ t: [NameToken]) -> String {
        var a = 0
        var b = t.count - 1
        while a <= b, t[a].kind == .sep || t[a].kind == .close { a += 1 }
        while b >= a, t[b].kind == .sep || t[b].kind == .open { b -= 1 }
        guard a <= b else { return "" }
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        var first = true
        for k in a...b {
            let token = t[k]
            if token.isDeco {
                pendingSpace = true
                continue
            }
            if !first && (token.spaceBefore || pendingSpace) { out.append(spaceScalar) }
            out.append(contentsOf: s[token.start..<token.end])
            first = false
            pendingSpace = false
        }
        return String(out)
    }

    func fallbackTitle() -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for c in s {
            if c == decoScalar || c == spaceScalar {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace { out.append(spaceScalar); pendingSpace = false }
            out.append(c)
        }
        return String(out)
    }

    // MARK: Entry points

    mutating func normalize() -> NormalizedName {
        if separatorLine(toks) { return separatorResult() }
        stripPrefixes()
        if separatorLine(toks) { return separatorResult() }
        processBrackets()
        stripPrefixes()

        var season: Int?
        var episode: Int?
        var episodeTitle: String?
        var titleTokens = toks
        var rest: [NameToken] = []
        if let match = findSeries(toks) {
            season = match.season
            episode = match.episode
            rest = Array(toks[(match.last + 1)...])
            if Self.hasWord(toks[..<match.first]) {
                titleTokens = Array(toks[..<match.first])
            } else {
                titleTokens = rest
                rest = []
            }
        }
        stripTrailing(&titleTokens, keepOneWord: true)
        if !rest.isEmpty {
            stripTrailing(&rest, keepOneWord: false)
            let restTitle = render(rest)
            episodeTitle = restTitle.isEmpty ? nil : restTitle
        }

        var title = render(titleTokens)
        if title.isEmpty {
            if let y = year {
                title = String(y)
                year = nil
            } else {
                title = fallbackTitle()
            }
        }
        return NormalizedName(
            title: title, key: NameFolding.key(title), year: year, quality: quality, tags: tags,
            season: season, episode: episode, isSeparator: false, episodeTitle: episodeTitle
        )
    }

    private mutating func separatorResult() -> NormalizedName {
        for i in toks.indices where sepLineCount(toks[i]) > 0 { toks[i].isDeco = true }
        let title = render(toks)
        return NormalizedName(title: title, key: NameFolding.key(title), tags: tags, isSeparator: true)
    }

    mutating func cleanCategory() -> String {
        stripPrefixes(strictCodesOnly: true)
        processBrackets(codesOnly: true)
        stripPrefixes(strictCodesOnly: true)
        // Separator decorations ("===== SPORT =====") are rendered as spaces.
        for i in toks.indices where sepLineCount(toks[i]) >= 2 { toks[i].isDeco = true }
        // Trailing "|FR|" style codes.
        var z = toks.count - 1
        var droppedPipe = false
        while z >= 0, toks[z].kind == .sep {
            if sepContainsPipe(toks[z]) { droppedPipe = true }
            z -= 1
        }
        if z >= 2, droppedPipe, countryCode(toks[z], lenient: false)?.count == 2,
           sepContainsPipe(toks[z - 1]), Self.hasWord(toks[..<(z - 1)]) {
            toks.removeSubrange(z...)
        }
        var name = render(toks)
        if name.isEmpty { name = fallbackTitle() }
        if name.isEmpty { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
        return NameCasing.smartTitleCaseIfAllCaps(name)
    }
}

// MARK: - Casing

enum NameCasing {
    static let keepUpper: Set<String> = [
        "TV", "HD", "FHD", "UHD", "SD", "4K", "8K", "HDR", "VF", "VO", "VOST", "VOSTFR", "VFF", "VFQ", "MULTI",
        "USA", "UK", "US", "FR", "BE", "CH", "CA", "QC", "NL", "TR", "UAE",
        "NBA", "NFL", "NHL", "MLB", "UFC", "WWE", "MMA", "PPV", "VIP", "BBC", "CNN", "ESPN", "DAZN", "RMC",
        "BFM", "TNT", "HBO", "AMC", "MTV", "OCS", "DTS", "3D", "XXX", "TF1", "M6", "LCI", "TMC", "TFX", "NRJ",
        "RTL", "RTBF", "RTS", "RAI", "ZDF", "ARD", "ORF", "SRF", "TVE", "RTP", "SIC", "MBC", "OSN", "ART",
        "DIY", "DC", "NHK", "KBS", "ABC", "NBC", "CBS", "FOX", "SKY", "BT", "ITV", "DMAX", "AXN", "TCM",
        "FX", "SYFY", "E!", "VOD", "PPV", "UEFA", "FIFA", "ATP", "WTA", "NASCAR", "MBC", "OCS", "BEIN",
        "CINE+", "ITA", "ESP", "GER", "ENG", "EXYU", "LATAM", "MENA",
    ]
    static let smallWords: Set<String> = [
        "de", "du", "des", "la", "le", "les", "et", "en", "au", "aux", "à", "of", "the", "and", "in", "on",
        "for", "y", "el", "los", "las", "di", "da", "del", "und", "der", "die", "das", "von", "sur", "par",
        "pour", "avec", "a", "an", "or", "ou", "to",
    ]

    static func smartTitleCaseIfAllCaps(_ text: String) -> String {
        guard text.contains(where: { $0.isLetter }), !text.contains(where: { $0.isLowercase }) else { return text }
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var word = ""
        var wordIndex = 0
        func flush() {
            guard !word.isEmpty else { return }
            result += caseWord(word, isFirst: wordIndex == 0)
            wordIndex += 1
            word = ""
        }
        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "’" || ch == "+" || ch == "!" || ch == "&" || ch == "." {
                word.append(ch)
            } else {
                flush()
                result.append(ch)
            }
        }
        flush()
        return result
    }

    static let romanNumerals: Set<String> = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII", "XIII"]

    private static func caseWord(_ word: String, isFirst: Bool) -> String {
        if word.contains(where: { $0.isNumber }) || romanNumerals.contains(word) { return word }
        let folded = NameFolding.key(word).replacingOccurrences(of: " ", with: "").uppercased()
        if keepUpper.contains(word) || keepUpper.contains(folded) { return word }
        let letters = word.filter { $0.isLetter }
        if letters.count >= 2 && letters.count <= 4 && !letters.contains(where: { "AEIOUYÀÂÄÉÈÊËÎÏÔÖÙÛÜŸ".contains($0) }) {
            return word
        }
        let lower = word.lowercased()
        if !isFirst && smallWords.contains(lower) { return lower }
        // L'ÉQUIPE → L'Équipe, D'ACTION → d'Action
        if let apostrophe = lower.firstIndex(where: { $0 == "'" || $0 == "’" }), lower.distance(from: lower.startIndex, to: apostrophe) == 1 {
            let head = lower[..<apostrophe]
            let tail = lower[lower.index(after: apostrophe)...]
            let headCased = isFirst ? head.uppercased() : String(head)
            return headCased + String(lower[apostrophe]) + capitalizeFirst(String(tail))
        }
        return capitalizeFirst(lower)
    }

    private static func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}

// MARK: - Folding

enum NameFolding {
    private struct KeyBuilder {
        var out: [UInt8]
        var pendingSpace = false

        @inline(__always) mutating func emit(_ byte: UInt8) {
            if pendingSpace {
                if !out.isEmpty { out.append(0x20) }
                pendingSpace = false
            }
            out.append(byte)
        }

        mutating func emit(_ ascii: StaticString) {
            let pointer = ascii.utf8Start
            for i in 0..<ascii.utf8CodeUnitCount { emit(pointer[i]) }
        }
    }

    static func key(_ text: String) -> String {
        var b = KeyBuilder(out: [])
        b.out.reserveCapacity(text.utf8.count + 4)
        for c in text.unicodeScalars {
            let v = c.value
            if v < 0x80 {
                switch v {
                case 0x61...0x7A, 0x30...0x39: b.emit(UInt8(v))
                case 0x41...0x5A: b.emit(UInt8(v + 32))
                case 0x27, 0x60: continue // apostrophes join words
                case 0x2B:
                    b.pendingSpace = true
                    b.emit("plus")
                    b.pendingSpace = true
                default: b.pendingSpace = true
                }
                continue
            }
            if let folded = foldLatin(v) {
                b.emit(folded)
                continue
            }
            switch v {
            case 0x2018, 0x2019, 0xB4, 0x2032: continue
            case 0x0300...0x036F: continue // combining diacritics
            default: break
            }
            let props = c.properties
            if props.isAlphabetic || props.numericType != nil {
                switch props.generalCategory {
                case .nonspacingMark, .spacingMark, .enclosingMark: continue
                default: break
                }
                var mapped = props.lowercaseMapping
                if (v >= 0x1E00 && v <= 0x1EFF) || (v >= 0x180 && v <= 0x24F) || (v >= 0x370 && v <= 0x3FF) {
                    let decomposed = mapped.decomposedStringWithCanonicalMapping
                    mapped = String(String.UnicodeScalarView(decomposed.unicodeScalars.filter { !($0.value >= 0x300 && $0.value <= 0x36F) }))
                }
                for byte in mapped.utf8 { b.emit(byte) }
            } else {
                b.pendingSpace = true
            }
        }
        return String(decoding: b.out, as: UTF8.self)
    }

    /// Folds Latin-1 Supplement / Latin Extended-A letters to lowercase ASCII.
    static func foldLatin(_ v: UInt32) -> StaticString? {
        switch v {
        case 0xC0...0xC5, 0xE0...0xE5, 0x100...0x105: "a"
        case 0xC6, 0xE6: "ae"
        case 0xC7, 0xE7, 0x106...0x10D: "c"
        case 0xC8...0xCB, 0xE8...0xEB, 0x112...0x11B: "e"
        case 0xCC...0xCF, 0xEC...0xEF, 0x128...0x131: "i"
        case 0xD0, 0xF0, 0x10E...0x111: "d"
        case 0xD1, 0xF1, 0x143...0x14B: "n"
        case 0xD2...0xD6, 0xD8, 0xF2...0xF6, 0xF8, 0x14C...0x151: "o"
        case 0xD9...0xDC, 0xF9...0xFC, 0x168...0x173: "u"
        case 0xDD, 0xFD, 0xFF, 0x176...0x178: "y"
        case 0xDE, 0xFE: "th"
        case 0xDF: "ss"
        case 0x11C...0x123: "g"
        case 0x124...0x127: "h"
        case 0x132, 0x133: "ij"
        case 0x134, 0x135: "j"
        case 0x136...0x138: "k"
        case 0x139...0x142: "l"
        case 0x152, 0x153: "oe"
        case 0x154...0x159: "r"
        case 0x15A...0x161, 0x17F: "s"
        case 0x162...0x167: "t"
        case 0x174, 0x175: "w"
        case 0x179...0x17E: "z"
        default: nil
        }
    }

    static let adultWords: Set<PackedKey> = Set([
        "xxx", "adult", "adults", "adulte", "adultes", "porn", "porno", "pornographie", "pornographique",
        "dorcel", "brazzers", "playboy", "hustler", "penthouse", "redlight", "vivid", "hentai",
    ].map(PackedKey.init))
    static let softAdultWords: Set<PackedKey> = Set(["hot", "sexy", "sex", "erotic", "erotique", "erotica", "erotico", "eroticos", "xx"].map(PackedKey.init))
    static let eighteen = PackedKey("18")
    static let plus = PackedKey("plus")

    static func isAdult(_ text: String, strict: Bool) -> Bool {
        isAdult(key: key(text), strict: strict)
    }

    /// Scans an already folded key word by word (no substring allocations).
    static func isAdult(key: String, strict: Bool) -> Bool {
        var word = PackedKey()
        var overflow = false
        var previous = PackedKey()
        func check(_ word: PackedKey, previous: PackedKey) -> Bool {
            if adultWords.contains(word) { return true }
            if !strict && softAdultWords.contains(word) { return true }
            return (previous == eighteen && word == plus) || (previous == plus && word == eighteen)
        }
        for byte in key.utf8 {
            if byte == 0x20 {
                if word.count > 0, !overflow {
                    if check(word, previous: previous) { return true }
                    previous = word
                } else if overflow {
                    previous = PackedKey()
                }
                word = PackedKey()
                overflow = false
            } else if !word.append(byte) {
                overflow = true
            }
        }
        if word.count > 0, !overflow, check(word, previous: previous) { return true }
        return false
    }
}
