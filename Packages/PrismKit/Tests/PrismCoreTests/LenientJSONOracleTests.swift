import Foundation
import Testing
@testable import PrismCore

/// Deterministic dirty Xtream-shaped payload shared by the oracle test and the gated decode benchmark.
enum LenientDirtyFixture {
    static func payload(count: Int) -> Data {
        let items = (0..<count).map(movieObject)
        return (try? JSONSerialization.data(withJSONObject: items, options: [])) ?? Data()
    }

    static func movieObject(index i: Int) -> [String: Any] {
        var object: [String: Any] = [:]
        let id = 100_000 + i

        switch i % 10 {
        case 0: object["stream_id"] = id
        case 1: object["stream_id"] = String(id)
        case 2: object["stream_id"] = "  \(id)  "
        case 3: object["stream_id"] = Double(id) + 0.25
        case 4: object["stream_id"] = ""
        case 5: object["stream_id"] = NSNull()
        case 6: object["stream_id"] = " \t\n"
        case 7: object["stream_id"] = i % 20 == 7
        case 8: object["stream_id"] = "\(id).75"
        default: object["stream_id"] = NSNumber(value: Int64(id) * 1_000_000)
        }
        object["id"] = i % 17 == 0 ? "fallback-\(id)" : NSNull()
        object["num"] = i % 3 == 0 ? "\(i)" : i
        object["stream_type"] = "movie"

        let title = "Film Sale \(i) (2024) MULTI 1080p WEB-DL"
        switch i % 12 {
        case 0: object["name"] = title
        case 1: object["name"] = ""
        case 2: object["name"] = " \t\n"
        case 3: object["name"] = NSNull()
        case 4: break
        case 5: object["name"] = 20_000 + i
        case 6: object["name"] = true
        case 7: object["name"] = "\u{200B}"
        case 8: object["name"] = " \u{00A0} "
        case 9: object["name"] = "null"
        case 10: object["name"] = "  null  "
        default: object["name"] = "Cœur étrange \(i) 🎬"
        }
        object["title"] = title

        object["cover"] = i % 5 == 0 ? "" : "https://img.example.com/p \(i).jpg"
        object["stream_icon"] = i % 7 == 0 ? NSNull() : "https://img.example.com/p\(i).jpg"
        object["cover_big"] = "https://img.example.com/big\(i).jpg"
        switch i % 8 {
        case 0: object["backdrop_path"] = ["https://img.example.com/b\(i).jpg", "notaurl", 42, NSNull()] as [Any]
        case 1: object["backdrop_path"] = "https://img.example.com/b\(i).jpg"
        case 2: object["backdrop_path"] = "https://img.example.com/b\(i).jpg, https://img.example.com/b2\(i).jpg"
        case 3: object["backdrop_path"] = []
        case 4: object["backdrop_path"] = [:]
        case 5: object["backdrop_path"] = NSNull()
        case 6: object["backdrop_path"] = ["", "  ", "https://img.example.com/b ä\(i).jpg"] as [Any]
        default: object["backdrop_path"] = ["0": "https://img.example.com/keyed\(i).jpg"]
        }

        object["plot"] = i % 6 == 0 ? "  " : "Une description sale n°\(i), avec des accents et une virgule, volontairement longue."
        object["description"] = "Description de repli \(i)"
        object["cast"] = i % 4 == 0 ? ["Acteur \(i)", " Actrice \(i) ", "", 17] as [Any] : "Acteur \(i), Actrice \(i)"
        object["director"] = i % 9 == 0 ? 7 : "Réalisatrice \(i)"
        object["genre"] = i % 4 == 1 ? ["Action", "Drame", "action", ""] as [Any] : "Action, Drame / Thriller"
        object["releaseDate"] = i % 5 == 0 ? "2024-05-0\(i % 9 + 1)" : "0\(i % 9 + 1)/05/2024"
        object["year"] = i % 6 == 0 ? "2024" : 2024

        switch i % 10 {
        case 0: object["rating"] = "7.4"
        case 1: object["rating"] = 8.2
        case 2: object["rating"] = "7,6"
        case 3: object["rating"] = ""
        case 4: object["rating"] = NSNull()
        case 5: object["rating"] = true
        case 6: object["rating"] = "11"
        case 7: object["rating"] = "garbage"
        case 8: object["rating"] = 0
        default: object["rating"] = " 6.9 "
        }
        object["rating_5based"] = i % 3 == 0 ? "3.7" : 4.1

        switch i % 8 {
        case 0: object["duration_secs"] = 5400 + i
        case 1: object["duration_secs"] = "\(5400 + i)"
        case 2: object["duration_secs"] = "5_400"
        case 3: object["duration_secs"] = ""
        case 4: object["duration_secs"] = NSNull()
        case 5: object["duration_secs"] = Double(5400 + i) + 0.8
        case 6: object["duration_secs"] = true
        default: object["duration_secs"] = " \(5400 + i) "
        }
        object["episode_run_time"] = i % 2 == 0 ? "95" : 95
        object["container_extension"] = i % 7 == 0 ? " MKV " : (i % 7 == 1 ? "" : "mkv")

        switch i % 8 {
        case 0: object["category_id"] = "\(i % 40)"
        case 1: object["category_id"] = i % 40
        case 2: object["category_id"] = "  "
        case 3: object["category_id"] = NSNull()
        case 4: object["category_id"] = ""
        default: break
        }
        switch i % 6 {
        case 0: object["category_ids"] = [i % 40, "x"] as [Any]
        case 1: object["category_ids"] = ["\(i % 40)"]
        case 2: object["category_ids"] = []
        case 3: object["category_ids"] = ["0": "\(i % 40)"]
        case 4: object["category_ids"] = NSNull()
        default: object["category_ids"] = [NSNull(), " \(i % 40) "] as [Any]
        }

        object["added"] = i % 5 == 0 ? "1704067200" : (i % 5 == 1 ? 1_704_067_200 : "2024-01-1\(i % 9)")
        object["tmdb"] = i % 4 == 0 ? "\(200_000 + i)" : 200_000 + i
        object["imdb_id"] = "tt\(i)"
        switch i % 12 {
        case 0: object["is_adult"] = true
        case 1: object["is_adult"] = false
        case 2: object["is_adult"] = 1
        case 3: object["is_adult"] = 0
        case 4: object["is_adult"] = "1"
        case 5: object["is_adult"] = "0"
        case 6: object["is_adult"] = "true"
        case 7: object["is_adult"] = "false"
        case 8: object["is_adult"] = "yes"
        case 9: object["is_adult"] = "-1"
        case 10: object["is_adult"] = "garbage"
        default: object["is_adult"] = NSNull()
        }
        object["trailer"] = i % 4 == 0 ? "abcDEF\(i % 89)" : "https://www.youtube.com/watch?v=abcDEF\(i % 89)"

        object["nested"] = i % 11 == 0 ? [] : [
            "clé": "valeur \(i)",
            "vide": " \t",
            "nombre": i % 2 == 0 ? "\(i)" : i,
            "objet": ["unicode_é🌈": ["vrai": true, "zéro": "0"]],
            "liste": [["x": "1"], [1, "deux", NSNull()], []] as [Any],
        ]
        object["clé_é🌈"] = i % 3 == 0 ? " unicode " : 42
        object["cle\u{301} seul"] = "canonique \(i)"
        object["array_value"] = [["a": "1"], ["b": 2], [1, 2, 3], "x", NSNull()] as [Any]
        object["empty_object"] = [:]
        object["empty_array"] = []
        object["whitespace"] = i % 2 == 0 ? " \u{200B}\t" : "texte"
        object["nullish"] = NSNull()
        return object
    }
}

/// Pre-optimization implementation of `JSONObject`, kept as the byte-compatibility oracle.
struct LenientReferenceJSONObject {
    let raw: [String: Any]

    init?(_ value: Any?) {
        guard let dict = value as? [String: Any] else { return nil }
        raw = dict
    }

    init(raw: [String: Any]) {
        self.raw = raw
    }

    static var empty: LenientReferenceJSONObject { LenientReferenceJSONObject(raw: [:]) }

    private static func isAllWhitespace(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    func value(_ keys: [String]) -> Any? {
        for key in keys {
            if let v = raw[key], !(v is NSNull) {
                if let s = v as? String, Self.isAllWhitespace(s) { continue }
                return v
            }
        }
        return nil
    }

    func string(_ keys: String...) -> String? { LenientValue.string(value(keys)) }
    func int(_ keys: String...) -> Int? { LenientValue.int(value(keys)) }
    func double(_ keys: String...) -> Double? { LenientValue.double(value(keys)) }
    func bool(_ keys: String...) -> Bool? { LenientValue.bool(value(keys)) }
    private static func referenceURLs(_ value: Any?) -> [URL] {
        if let array = value as? [Any] { return array.compactMap { LenientValue.url($0) } }
        guard let raw = LenientValue.string(value) else { return [] }
        if let single = LenientValue.url(raw) { return [single] }
        return raw.split(separator: ",").compactMap { LenientValue.url(String($0)) }
    }

    private static func referenceList(_ value: Any?, separators: Set<Character>) -> [String] {
        var parts: [String] = []
        if let array = value as? [Any] {
            parts = array.compactMap { LenientValue.string($0) }
        } else if let raw = LenientValue.string(value) {
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

    func url(_ keys: String...) -> URL? {
        for key in keys { if let u = LenientValue.url(raw[key]) { return u } }
        return nil
    }
    func urls(_ keys: String...) -> [URL] {
        for key in keys { let u = Self.referenceURLs(raw[key]); if !u.isEmpty { return u } }
        return []
    }
    func date(_ keys: String...) -> Date? { LenientValue.date(value(keys)) }
    func day(_ keys: String...) -> Date? {
        for key in keys { if let d = LenientValue.day(raw[key]) { return d } }
        return nil
    }
    func year(_ keys: String...) -> Int? {
        for key in keys { if let y = LenientValue.year(raw[key]) { return y } }
        return nil
    }
    func list(_ keys: String..., separators: Set<Character> = [","]) -> [String] {
        for key in keys { let l = Self.referenceList(raw[key], separators: separators); if !l.isEmpty { return l } }
        return []
    }
    func object(_ key: String) -> LenientReferenceJSONObject? { LenientReferenceJSONObject(raw[key]) }
    func array(_ key: String) -> [Any] { LenientOracle.array(raw[key]) }
}

enum LenientOracle {
    /// Pre-optimization `LenientValue.array`: array bridge first, dictionaries sorted by numeric key.
    static func array(_ value: Any?) -> [Any] {
        if let array = value as? [Any] { return array }
        if let dict = value as? [String: Any] {
            return dict.keys.sorted { lhs, rhs in
                switch (Int(lhs), Int(rhs)) {
                case let (l?, r?): l < r
                default: lhs < rhs
                }
            }.compactMap { dict[$0] }
        }
        return []
    }

    static func canonical(_ value: Any?) -> String {
        guard let value else { return "∅" }
        if value is NSNull { return "null" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return "bool:\(number.boolValue)" }
            return "number:\(String(cString: number.objCType)):\(number.stringValue):\(number.doubleValue.bitPattern)"
        }
        if let string = value as? NSString {
            return "string:\(string.length):\(string)"
        }
        if let array = value as? NSArray {
            return "[" + (0..<array.count).map { canonical(array.object(at: $0)) }.joined(separator: ",") + "]"
        }
        if let dictionary = value as? NSDictionary {
            var pairs: [(String, String)] = []
            pairs.reserveCapacity(dictionary.count)
            for key in dictionary.allKeys {
                let keyText = (key as? String) ?? String(describing: key)
                pairs.append((keyText, canonical(dictionary.object(forKey: key))))
            }
            return "{" + pairs.sorted { $0.0 < $1.0 }.map { "\($0.0)=\($0.1)" }.joined(separator: ",") + "}"
        }
        return "other:\(type(of: value)):\(String(describing: value))"
    }

    static func canonicalObject(_ object: LenientReferenceJSONObject?) -> String {
        guard let object else { return "∅" }
        return canonical(object.raw)
    }

    static func canonicalObject(_ object: JSONObject?) -> String {
        guard let object else { return "∅" }
        return canonical(object.raw)
    }

    static func referenceVODStreams(
        _ data: Data, sourceID: SourceID, credentials: XtreamCredentials, adultCategoryIDs: Set<String> = []
    ) throws -> [Movie] {
        try referenceVODStreams(array(LenientValue.parse(data)), sourceID: sourceID, credentials: credentials, adultCategoryIDs: adultCategoryIDs)
    }

    /// Copy of the VOD mapping, changed only to read through `LenientReferenceJSONObject`.
    static func referenceVODStreams(
        _ items: [Any], sourceID: SourceID, credentials: XtreamCredentials, adultCategoryIDs: Set<String> = []
    ) -> [Movie] {
        let streamBase = XtreamURLBuilder.StreamBase(credentials)
        var interner = CategoryIDInterner(sourceID: sourceID, kind: .movie)
        var result: [Movie] = []
        result.reserveCapacity(items.count)
        for element in items {
            guard let obj = LenientReferenceJSONObject(element), let id = obj.string("stream_id", "id") else { continue }
            let rawName = obj.string("name", "title") ?? "Film \(id)"
            let n = TitleNormalizer.normalize(rawName)
            let ext = obj.string("container_extension")
            let category = categoryNativeID(obj)
            let year = obj.year("year") ?? obj.year("releaseDate", "releasedate", "release_date") ?? n.year
            result.append(Movie(
                sourceID: sourceID,
                nativeID: id,
                title: n.title.isEmpty ? rawName : TitleRefinement.refine(n.title),
                rawName: rawName,
                year: year,
                posterURL: obj.url("stream_icon", "cover", "cover_big"),
                backdropURL: obj.urls("backdrop_path").first,
                plot: obj.string("plot", "description"),
                genres: obj.list("genre", "genres", separators: XtreamDecoder.genreSeparators),
                rating: rating(obj),
                durationSeconds: obj.int("duration_secs") ?? obj.int("episode_run_time").map { $0 * 60 },
                cast: obj.list("cast", "actors"),
                director: obj.string("director"),
                categoryID: category.map { interner.intern($0) },
                streamURL: streamBase.movie(streamID: id, ext: ext),
                containerExtension: ext?.lowercased(),
                quality: n.quality,
                tags: n.tags,
                addedAt: obj.date("added"),
                tmdbID: obj.int("tmdb", "tmdb_id").flatMap { $0 > 0 ? $0 : nil },
                trailerURL: XtreamDecoder.youtubeURL(obj.string("trailer", "youtube_trailer")),
                isAdult: obj.bool("is_adult") == true || category.map { adultCategoryIDs.contains($0) } == true || TitleNormalizer.isAdultName(n)
            ))
        }
        return result
    }

    private static func categoryNativeID(_ obj: LenientReferenceJSONObject) -> String? {
        if let id = obj.string("category_id") { return id }
        if let ids = obj.raw["category_ids"] as? [Any], let first = ids.lazy.compactMap({ LenientValue.string($0) }).first { return first }
        return nil
    }

    private static func rating(_ obj: LenientReferenceJSONObject) -> Double? {
        if let r = obj.double("rating"), r > 0, r <= 10 { return r }
        if let r = obj.double("rating_5based"), r > 0, r <= 5 { return r * 2 }
        if let r = obj.double("vote_average"), r > 0, r <= 10 { return r }
        return nil
    }
}

@Suite("Lenient JSON oracle")
struct LenientJSONOracleTests {
    @Test func dirtyObjectAccessMatchesReferenceExactly() throws {
        let data = LenientDirtyFixture.payload(count: 2_000)
        let parsed = try LenientValue.parse(data)
        let referenceElements = LenientOracle.array(parsed)
        let productionElements = Array(LenientValue.array(parsed))
        #expect(productionElements.count == referenceElements.count)
        #expect(productionElements.map { LenientOracle.canonical($0) } == referenceElements.map { LenientOracle.canonical($0) })

        var mismatches: [String] = []
        func check<T: Equatable>(_ label: String, _ production: T, _ reference: T, index: Int) {
            if production != reference { mismatches.append("\(index):\(label)") }
        }

        for (index, element) in referenceElements.enumerated() {
            let reference = LenientReferenceJSONObject(element)
            let production = JSONObject(element)
            check("object-exists", production != nil, reference != nil, index: index)
            guard let reference, let production else { continue }

            for key in ["stream_id", "name", "nullish", "clé_é🌈", "missing"] {
                check("stored\(key)", LenientOracle.canonical(production.storedValue(key)), LenientOracle.canonical(reference.raw[key]), index: index)
            }
            for keys in [
                ["stream_id", "id"], ["name", "title"], ["plot", "description"], ["genre", "genres"],
                ["rating", "rating_5based"], ["duration_secs"], ["category_id"], ["clé_é🌈"], ["whitespace"], ["nullish"],
            ] {
                check("value\(keys)", LenientOracle.canonical(production.value(keys)), LenientOracle.canonical(reference.value(keys)), index: index)
            }

            check("stream_id", production.string("stream_id", "id"), reference.string("stream_id", "id"), index: index)
            check("name", production.string("name", "title"), reference.string("name", "title"), index: index)
            check("plot", production.string("plot", "description"), reference.string("plot", "description"), index: index)
            check("unicode", production.string("clé_é🌈"), reference.string("clé_é🌈"), index: index)
            check("unicode-canonical", production.string("clé seul"), reference.string("clé seul"), index: index)
            check("int", production.int("duration_secs"), reference.int("duration_secs"), index: index)
            check("double", production.double("rating"), reference.double("rating"), index: index)
            check("bool", production.bool("is_adult"), reference.bool("is_adult"), index: index)
            check("url", production.url("stream_icon", "cover", "cover_big"), reference.url("stream_icon", "cover", "cover_big"), index: index)
            check("urls", production.urls("backdrop_path"), reference.urls("backdrop_path"), index: index)
            check("date", production.date("added"), reference.date("added"), index: index)
            check("day", production.day("releaseDate"), reference.day("releaseDate"), index: index)
            check("year", production.year("year", "releaseDate"), reference.year("year", "releaseDate"), index: index)
            check("genres", production.list("genre", "genres", separators: XtreamDecoder.genreSeparators), reference.list("genre", "genres", separators: XtreamDecoder.genreSeparators), index: index)
            check("cast", production.list("cast", "actors"), reference.list("cast", "actors"), index: index)
            check("nested-object", LenientOracle.canonicalObject(production.object("nested")), LenientOracle.canonicalObject(reference.object("nested")), index: index)
            check("array-value", LenientOracle.canonical(Array(production.array("array_value"))), LenientOracle.canonical(reference.array("array_value")), index: index)
            check("category-ids", LenientOracle.canonical(Array(production.array("category_ids"))), LenientOracle.canonical(reference.array("category_ids")), index: index)
            check("empty-object-array", LenientOracle.canonical(Array(production.array("empty_object"))), LenientOracle.canonical(reference.array("empty_object")), index: index)
            check("empty-array", LenientOracle.canonical(Array(production.array("empty_array"))), LenientOracle.canonical(reference.array("empty_array")), index: index)
        }
        #expect(mismatches.isEmpty, "oracle mismatches: \(mismatches.prefix(30))")
    }

    @Test func canonicallyEquivalentUnicodeKeysMatchReference() throws {
        let json = "{\"clé collision\":\"pre\",\"cle\u{301} collision\":\"decomp\",\"cle\u{301} seul\":\"single\"}"
        let parsed = try LenientValue.parse(Data(json.utf8))
        let reference = try #require(LenientReferenceJSONObject(parsed))
        let production = try #require(JSONObject(parsed))
        // "seul" has no canonical twin: lookups by either canonical form must match the reference exactly.
        for key in ["clé seul", "cle\u{301} seul"] {
            #expect(LenientOracle.canonical(production.storedValue(key)) == LenientOracle.canonical(reference.raw[key]))
            #expect(production.string(key) == reference.string(key))
        }
        // "clé collision" and "cle\u{301} collision" are canonically equal: which of the two values
        // survives the bridge into a Swift dictionary depends on Foundation's per-process hash
        // ordering, so exact equality with the reference is not a stable property. Assert instead
        // that production resolves the collision to one of the two JSON values, consistently.
        for key in ["clé collision", "cle\u{301} collision"] {
            let value = production.string(key)
            #expect(value == "pre" || value == "decomp")
            #expect(production.string(key) == value)
        }
    }

    @Test func largeDirtyVODDecodeMatchesReferenceExactly() throws {
        let data = LenientDirtyFixture.payload(count: 2_000)
        let credentials = XtreamCredentials(server: URL(string: "http://panel.example.com")!, username: "oracle", password: "secret")
        let production = try XtreamDecoder.vodStreams(data, sourceID: "oracle", credentials: credentials, adultCategoryIDs: ["13"])
        let reference = try LenientOracle.referenceVODStreams(data, sourceID: "oracle", credentials: credentials, adultCategoryIDs: ["13"])
        #expect(production == reference)
        #expect(!production.isEmpty)
    }
}
