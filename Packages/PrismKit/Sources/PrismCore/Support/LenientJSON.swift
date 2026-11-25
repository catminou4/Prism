import Foundation

/// Indexed view over a JSON array. `JSONSerialization` arrays are immutable `NSArray`s on Darwin:
/// retaining the backing store and reading elements on demand avoids the O(element count) bridge
/// copy that `as? [Any]` performs, while native arrays keep their existing storage.
struct LenientArray: Collection {
    private enum Storage {
        case swift([Any])
        case foundation(NSArray)
    }

    private let storage: Storage
    let count: Int

    init?(_ value: Any?) {
        guard let value else { return nil }
        if type(of: value) == [Any].self, let array = value as? [Any] {
            self.init(swift: array)
        } else if let array = value as? NSArray {
            self.init(foundation: array)
        } else if let array = value as? [Any] {
            self.init(swift: array)
        } else {
            return nil
        }
    }

    private init(swift array: [Any]) {
        storage = .swift(array)
        count = array.count
    }

    private init(foundation array: NSArray) {
        storage = .foundation(array)
        count = array.count
    }

    static var empty: LenientArray { LenientArray(swift: []) }

    static func materialized(_ array: [Any]) -> LenientArray {
        LenientArray(swift: array)
    }

    var startIndex: Int { 0 }
    var endIndex: Int { count }

    func index(after index: Int) -> Int { index + 1 }

    subscript(position: Int) -> Any {
        switch storage {
        case .swift(let array): return array[position]
        case .foundation(let array): return array.object(at: position)
        }
    }
}

/// Extremely lenient accessors over `JSONSerialization` values. IPTV panels return numbers as
/// strings, `""`/`null` for missing values, booleans as `0/1/"0"/"1"/true`, `[]` instead of `{}`…
/// Values are only used locally inside decoding functions (not `Sendable`).
enum LenientValue {
    /// `trimmingCharacters(in: .whitespacesAndNewlines)` without the copy when the string has
    /// no leading/trailing whitespace — the common case for JSON payloads. Trimming is only
    /// needed at the edges, so checking the first and last scalars decides it in ~ns.
    static func trim(_ s: String) -> String {
        guard let first = s.unicodeScalars.first, let last = s.unicodeScalars.last,
              !CharacterSet.whitespacesAndNewlines.contains(first),
              !CharacterSet.whitespacesAndNewlines.contains(last) else {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    /// True when every scalar is whitespace — same result as
    /// `s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty` without allocating.
    static func isAllWhitespace(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    /// UTF-16 fast path for unparsed `NSString` leaves. The whitespace set is entirely in the
    /// BMP, so surrogate pairs are never whitespace and per-unit membership is equivalent to
    /// scanning the bridged String's scalars.
    static func isAllWhitespace(_ s: NSString) -> Bool {
        var index = 0
        while index < s.length {
            guard let scalar = UnicodeScalar(UInt32(s.character(at: index))),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) else { return false }
            index += 1
        }
        return true
    }

    static func parse(_ data: Data) throws -> Any {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        return try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])
    }

    static func isNull(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String:
            let trimmed = trim(s)
            if trimmed.isEmpty || trimmed == "null" { return nil }
            return trimmed
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "1" : "0" }
            let d = n.doubleValue
            if d.isFinite, d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
            return n.stringValue
        default:
            return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as NSNumber:
            let d = n.doubleValue
            guard d.isFinite, abs(d) < 9e15 else { return nil }
            return Int(d)
        case let s as String:
            let trimmed = trim(s)
            guard !trimmed.isEmpty else { return nil }
            if let i = Int(trimmed) { return i }
            let normalized = trimmed.contains(",") ? trimmed.replacingOccurrences(of: ",", with: ".") : trimmed
            if let d = Double(normalized), d.isFinite, abs(d) < 9e15 { return Int(d) }
            return nil
        default:
            return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            let d = n.doubleValue
            return d.isFinite ? d : nil
        case let s as String:
            var trimmed = trim(s)
            if trimmed.contains(",") { trimmed = trimmed.replacingOccurrences(of: ",", with: ".") }
            guard !trimmed.isEmpty, let d = Double(trimmed), d.isFinite else { return nil }
            return d
        default:
            return nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let n as NSNumber:
            return n.doubleValue != 0
        case let s as String:
            switch trim(s).lowercased() {
            case "1", "true", "yes", "y", "on": return true
            case "0", "false", "no", "n", "off", "-1": return false
            default: return int(s).map { $0 != 0 }
            }
        default:
            return nil
        }
    }

    private static let urlAllowed: CharacterSet = {
        var set = CharacterSet.urlFragmentAllowed
        set.insert(charactersIn: "%#")
        return set
    }()

    /// http(s) URL with a host; spaces percent-encoded; anything else → nil.
    static func url(_ value: Any?) -> URL? {
        guard let raw = string(value) else { return nil }
        let candidate = URL(string: raw) ?? raw.addingPercentEncoding(withAllowedCharacters: urlAllowed).flatMap { URL(string: $0) }
        guard let url = candidate, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty else { return nil }
        return url
    }

    /// Array of URLs, a single URL string, or a comma separated list.
    static func urls(_ value: Any?) -> [URL] {
        if let array = LenientArray(value) { return array.compactMap { url($0) } }
        guard let raw = string(value) else { return [] }
        if let single = url(raw) { return [single] }
        return raw.split(separator: ",").compactMap { url(String($0)) }
    }

    /// Unix timestamp (seconds, or milliseconds when huge) as number or string; or a calendar date.
    /// Bare small numbers ("2023") are dates, not 1970 epochs: only values past ~1973 count as timestamps.
    static func date(_ value: Any?) -> Date? {
        if let seconds = double(value), seconds > 100_000 {
            return Date(timeIntervalSince1970: seconds > 1e11 ? seconds / 1000 : seconds)
        }
        return day(value)
    }

    /// "2019-05-02", "2019-05-02 20:30:00", "2019/05/02", "02/05/2019", "2019" → Date (UTC); or a unix timestamp.
    static func day(_ value: Any?) -> Date? {
        guard let raw = string(value) else { return nil }
        let digits = raw.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard let first = digits.first else { return nil }
        if digits.count == 1 {
            if (1900...2100).contains(first) { return civil(first, 1, 1, 0, 0, 0) }
            if first > 100_000 { return Date(timeIntervalSince1970: TimeInterval(first)) }
            return nil
        }
        guard digits.count >= 3 else { return nil }
        var (y, m, d) = (digits[0], digits[1], digits[2])
        if y < 100, d >= 1900 { (y, d) = (d, y) } // dd/mm/yyyy
        guard (1800...2200).contains(y), (1...12).contains(m), (1...31).contains(d) else { return nil }
        let hh = digits.count > 3 ? digits[3] : 0
        let mm = digits.count > 4 ? digits[4] : 0
        let ss = digits.count > 5 ? digits[5] : 0
        guard hh < 24, mm < 60, ss < 61 else { return nil }
        return civil(y, m, d, hh, mm, ss)
    }

    static func year(_ value: Any?) -> Int? {
        if let i = int(value), (1900...2100).contains(i) { return i }
        guard let raw = string(value) else { return nil }
        // First 4-digit run in range ("2019-05-02", "(2019)").
        var run = 0
        var current = 0
        for ch in raw.unicodeScalars {
            if ch.value >= 0x30, ch.value <= 0x39 {
                // Only 4-digit runs matter; longer runs must not overflow.
                if run < 5 { current = current * 10 + Int(ch.value - 0x30) }
                run += 1
            } else {
                if run == 4, (1900...2100).contains(current) { return current }
                run = 0
                current = 0
            }
        }
        return run == 4 && (1900...2100).contains(current) ? current : nil
    }

    private static func civil(_ y: Int, _ m: Int, _ d: Int, _ hh: Int, _ mm: Int, _ ss: Int) -> Date {
        let days = XMLTVParser.daysFromCivil(year: y, month: m, day: d)
        return Date(timeIntervalSince1970: TimeInterval(days * 86_400 + hh * 3600 + mm * 60 + ss))
    }

    /// Array of strings or a separated string ("Action, Drame / Thriller").
    static func list(_ value: Any?, separators: Set<Character> = [","]) -> [String] {
        var parts: [String] = []
        if let array = LenientArray(value) {
            parts = array.compactMap { string($0) }
        } else if let raw = string(value) {
            parts = raw.split(whereSeparator: { separators.contains($0) }).map { String($0) }
        }
        var seen = Set<String>()
        var result: [String] = []
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// Array elements; dictionaries become their values ordered by (numeric) key; anything else → [].
    static func array(_ value: Any?) -> LenientArray {
        if let array = LenientArray(value) { return array }
        // The mixed numeric/lexicographic comparator is not a strict weak ordering, so the
        // resulting order can depend on the exact key order produced by the legacy bridge.
        // Keyed dictionaries are rare and small in Xtream payloads; keep that exact bridge here.
        if let dict = value as? [String: Any] {
            return .materialized(dict.keys.sorted { lhs, rhs in
                switch (Int(lhs), Int(rhs)) {
                case let (l?, r?): l < r
                default: lhs < rhs
                }
            }.compactMap { dict[$0] })
        }
        return .empty
    }

    /// "01:52:33" / "52:33" / "6753" → seconds.
    static func hms(_ value: Any?) -> Int? {
        guard let raw = string(value) else { return nil }
        let parts = raw.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let numbers = parts.compactMap { $0 }
        // A week is far beyond any real duration; it also keeps the arithmetic from overflowing.
        guard numbers.count <= 3, numbers.allSatisfy({ (0...604_800).contains($0) }) else { return nil }
        let seconds = numbers.reduce(0) { $0 * 60 + $1 }
        return seconds > 0 && seconds <= 604_800 ? seconds : nil
    }

    /// Letters, digits, whitespace and punctuation — the repertoire of readable text in any
    /// script. Mojibake from coincidental base64 scatters into symbols and rare blocks.
    private static let proseCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.formUnion(.whitespacesAndNewlines)
        set.formUnion(.punctuationCharacters)
        return set
    }()

    private static func proseScore(_ s: String) -> Double {
        let count = s.unicodeScalars.count
        guard count > 0 else { return 0 }
        var good = 0
        for scalar in s.unicodeScalars where proseCharacters.contains(scalar) { good += 1 }
        return Double(good) / Double(count)
    }

    /// Lenient base64 (missing padding, URL-safe alphabet, embedded whitespace). Falls back to the raw text.
    /// The decoded text is only preferred when it reads better than the input: plain titles that
    /// happen to be valid base64 must not turn into mojibake.
    static func base64Text(_ value: Any?) -> String? {
        guard let raw = string(value) else { return nil }
        if raw.contains(" ") { return raw }
        var cleaned = raw.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = cleaned.count % 4
        if remainder > 0 { cleaned += String(repeating: "=", count: 4 - remainder) }
        if let data = Data(base64Encoded: cleaned), let text = String(data: data, encoding: .utf8),
           !text.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" }) {
            let score = proseScore(text)
            if score >= 0.85, score >= proseScore(raw) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        return raw
    }
}

/// Typed view over a JSON dictionary with multi-key lookups (`obj.string("releaseDate", "releasedate")`).
/// `JSONSerialization` dictionaries are immutable `NSDictionary`s on Darwin. Keeping that backing
/// store and looking up individual keys avoids re-materializing every key/value pair as a Swift
/// dictionary for each object in a large list. `raw` remains available for the few keyset-oriented
/// paths; it bridges on demand rather than being the storage representation.
struct JSONObject {
    private enum Storage {
        case swift([String: Any])
        case foundation(NSDictionary)
    }

    private let storage: Storage

    var raw: [String: Any] {
        switch storage {
        case .swift(let dict): return dict
        case .foundation(let dict): return (dict as? [String: Any]) ?? [:]
        }
    }

    init?(_ value: Any?) {
        guard let value else { return nil }
        if type(of: value) == [String: Any].self, let dict = value as? [String: Any] {
            storage = .swift(dict)
        } else if let dict = value as? NSDictionary {
            storage = .foundation(dict)
        } else if let dict = value as? [String: Any] {
            storage = .swift(dict)
        } else {
            return nil
        }
    }

    init(raw: [String: Any]) {
        storage = .swift(raw)
    }

    static var empty: JSONObject { JSONObject(raw: [:]) }

    /// Key lookup with dictionary semantics: no `NSNull` or whitespace filtering.
    func storedValue(_ key: String) -> Any? {
        switch storage {
        case .swift(let dict): return dict[key]
        case .foundation(let dict):
            // Swift String equality is canonically equivalent while NSString equality is literal.
            // ASCII keys (every hot Xtream/TMDB key) cannot have a distinct canonical twin, so they
            // use the direct lookup; rare non-ASCII lookups take the exact legacy bridge instead.
            if key.utf8.allSatisfy({ $0 < 0x80 }) { return dict.object(forKey: key as NSString) }
            return (dict as? [String: Any])?[key]
        }
    }

    func value(_ keys: [String]) -> Any? {
        for key in keys {
            if let v = storedValue(key), !(v is NSNull) {
                if let s = v as? NSString, LenientValue.isAllWhitespace(s) { continue }
                return v
            }
        }
        return nil
    }

    func string(_ keys: String...) -> String? { LenientValue.string(value(keys)) }
    func int(_ keys: String...) -> Int? { LenientValue.int(value(keys)) }
    func double(_ keys: String...) -> Double? { LenientValue.double(value(keys)) }
    func bool(_ keys: String...) -> Bool? { LenientValue.bool(value(keys)) }
    func url(_ keys: String...) -> URL? {
        for key in keys { if let u = LenientValue.url(storedValue(key)) { return u } }
        return nil
    }
    func urls(_ keys: String...) -> [URL] {
        for key in keys { let u = LenientValue.urls(storedValue(key)); if !u.isEmpty { return u } }
        return []
    }
    func date(_ keys: String...) -> Date? { LenientValue.date(value(keys)) }
    func day(_ keys: String...) -> Date? {
        for key in keys { if let d = LenientValue.day(storedValue(key)) { return d } }
        return nil
    }
    func year(_ keys: String...) -> Int? {
        for key in keys { if let y = LenientValue.year(storedValue(key)) { return y } }
        return nil
    }
    func list(_ keys: String..., separators: Set<Character> = [","]) -> [String] {
        for key in keys { let l = LenientValue.list(storedValue(key), separators: separators); if !l.isEmpty { return l } }
        return []
    }
    func object(_ key: String) -> JSONObject? { JSONObject(storedValue(key)) }
    func array(_ key: String) -> LenientArray { LenientValue.array(storedValue(key)) }
}
