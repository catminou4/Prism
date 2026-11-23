import Foundation

public struct XMLTVChannel: Sendable, Hashable {
    public var id: String
    public var displayNames: [String]
    public var iconURL: URL?

    public init(id: String, displayNames: [String] = [], iconURL: URL? = nil) {
        self.id = id
        self.displayNames = displayNames
        self.iconURL = iconURL
    }
}

public struct XMLTVDocument: Sendable {
    public var channels: [XMLTVChannel]
    public var programs: [EPGProgram]

    public init(channels: [XMLTVChannel] = [], programs: [EPGProgram] = []) {
        self.channels = channels
        self.programs = programs
    }
}

public enum XMLTVError: Error, LocalizedError, Equatable {
    case invalidData, decompressionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidData: "Le guide TV (XMLTV) est illisible."
        case .decompressionFailed: "Impossible de décompresser le guide TV."
        }
    }
}

/// Streaming (SAX) XMLTV parser. Synchronous: call it from a background task.
public enum XMLTVParser {
    /// Gzip and zlib input are decompressed transparently.
    /// Programmes ending before `window.start` or starting after `window.end` are dropped (memory).
    /// `timeShiftHours` is added to every time.
    public static func parse(_ data: Data, window: DateInterval? = nil, timeShiftHours: Double = 0) throws -> XMLTVDocument {
        let xml = Gzip.isCompressed(data) ? try Gzip.decompress(data) : data
        guard !xml.isEmpty else { throw XMLTVError.invalidData }

        let delegate = XMLTVParserDelegate(window: window, shift: timeShiftHours * 3600)
        let parser = XMLParser(data: xml)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = delegate
        let ok = parser.parse()
        if !ok && delegate.channels.isEmpty && delegate.programs.isEmpty {
            throw XMLTVError.invalidData
        }
        return XMLTVDocument(channels: delegate.channels, programs: delegate.finishPrograms())
    }

    /// `yyyyMMddHHmmss ±hhmm` with optional seconds / minutes / offset (`20250101120000 +0100`,
    /// `202501011200`, `20250101120000`, `20250101120000 Z`, `+01:00`). No offset = UTC.
    public static func parseTime(_ string: String) -> Date? {
        var copy = string
        return copy.withUTF8 { parseTime(bytes: $0) }
    }

    static func parseTime(bytes b: UnsafeBufferPointer<UInt8>) -> Date? {
        let n = b.count
        var i = 0
        while i < n, b[i] == 0x20 { i += 1 }
        // Up to 14 digits: yyyyMMdd[HH[mm[ss]]].
        var fields = (0, 0, 0, 0, 0, 0) // year, month, day, hour, minute, second
        var digits = 0
        while i < n, digits < 14, b[i] >= 0x30, b[i] <= 0x39 {
            let d = Int(b[i] - 0x30)
            switch digits {
            case 0..<4: fields.0 = fields.0 * 10 + d
            case 4..<6: fields.1 = fields.1 * 10 + d
            case 6..<8: fields.2 = fields.2 * 10 + d
            case 8..<10: fields.3 = fields.3 * 10 + d
            case 10..<12: fields.4 = fields.4 * 10 + d
            default: fields.5 = fields.5 * 10 + d
            }
            digits += 1
            i += 1
        }
        guard digits >= 8 else { return nil }
        if digits == 9 || digits == 11 || digits == 13 { return nil }
        // Skip fractional seconds / extra digits.
        while i < n, (b[i] >= 0x30 && b[i] <= 0x39) || b[i] == 0x2E { i += 1 }
        let (year, month, day, hour, minute, second) = fields
        guard (1...12).contains(month), (1...31).contains(day), hour < 25, minute < 60, second < 61 else { return nil }

        while i < n, b[i] == 0x20 || b[i] == 0x09 { i += 1 }
        var offset = 0
        if i < n, b[i] == 0x2B || b[i] == 0x2D {
            let sign = b[i] == 0x2D ? -1 : 1
            i += 1
            var value = 0
            var count = 0
            while i < n, count < 4 {
                if b[i] >= 0x30 && b[i] <= 0x39 {
                    value = value * 10 + Int(b[i] - 0x30)
                    count += 1
                } else if b[i] != 0x3A {
                    break
                }
                i += 1
            }
            if count >= 2 {
                let hours = count >= 4 ? value / 100 : (count == 2 ? value : value / 10)
                let minutes = count >= 4 ? value % 100 : 0
                offset = sign * (hours * 3600 + minutes * 60)
            }
        }
        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// `xmltv_ns` "1.4.0/1" → "S2 E5"; "0.0." → "S1 E1"; ". 4 ." → "E5".
    public static func episodeLabel(xmltvNS: String) -> String? {
        let parts = xmltvNS.split(separator: ".", omittingEmptySubsequences: false)
        func number(_ index: Int) -> Int? {
            guard index < parts.count else { return nil }
            let head = parts[index].split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            return Int(head.trimmingCharacters(in: .whitespaces))
        }
        let season = number(0).map { $0 + 1 }
        let episode = number(1).map { $0 + 1 }
        switch (season, episode) {
        case let (s?, e?): return "S\(s) E\(e)"
        case let (s?, nil): return "S\(s)"
        case let (nil, e?): return "E\(e)"
        default: return nil
        }
    }
}

// MARK: - Delegate

private final class XMLTVParserDelegate: NSObject, XMLParserDelegate {
    enum Context { case none, channel, programme }
    enum Capture { case none, displayName, title, subtitle, desc, category, episode, ratingValue }

    let window: DateInterval?
    let shift: TimeInterval

    var channels: [XMLTVChannel] = []
    var programs: [EPGProgram] = []
    var missingStop: [Int] = []

    var context = Context.none
    var capture = Capture.none
    var text = ""
    var lang: String?
    var system: String?

    // Channel state
    var channelID = ""
    var displayNames: [String] = []
    var channelIcon: URL?

    // Programme state
    var programmeChannel = ""
    var start: Date?
    var stop: Date?
    var skip = false
    var titles: [(String?, String)] = []
    var subtitles: [(String?, String)] = []
    var descriptions: [(String?, String)] = []
    var categories: [(String?, String)] = []
    var programmeIcon: URL?
    var episodeNS: String?
    var episodeOnScreen: String?
    var isNew = false
    var inRating = false
    var rating: String?

    init(window: DateInterval?, shift: TimeInterval) {
        self.window = window
        self.shift = shift
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch context {
        case .none:
            if elementName == "programme" {
                beginProgramme(attributes)
            } else if elementName == "channel" {
                context = .channel
                channelID = attributes["id"]?.trimmingCharacters(in: .whitespaces) ?? ""
                displayNames = []
                channelIcon = nil
            }
        case .channel:
            switch elementName {
            case "display-name": begin(.displayName, attributes)
            case "icon": if channelIcon == nil { channelIcon = Self.url(attributes["src"]) }
            default: break
            }
        case .programme:
            guard !skip else { return }
            switch elementName {
            case "title": begin(.title, attributes)
            case "sub-title": begin(.subtitle, attributes)
            case "desc": begin(.desc, attributes)
            case "category": begin(.category, attributes)
            case "episode-num": begin(.episode, attributes)
            case "icon": if programmeIcon == nil { programmeIcon = Self.url(attributes["src"]) }
            case "new": isNew = true
            case "rating": inRating = true
            case "value": if inRating && rating == nil { begin(.ratingValue, attributes) }
            default: break
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capture != .none { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if capture != .none { text += String(decoding: CDATABlock, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch context {
        case .none:
            return
        case .channel:
            if elementName == "channel" {
                if !channelID.isEmpty {
                    channels.append(XMLTVChannel(id: channelID, displayNames: displayNames, iconURL: channelIcon))
                }
                context = .none
            } else if elementName == "display-name", capture == .displayName {
                let value = finishCapture()
                if !value.isEmpty, !displayNames.contains(value) { displayNames.append(value) }
            }
        case .programme:
            if elementName == "programme" {
                endProgramme()
                context = .none
                return
            }
            guard !skip else { return }
            switch elementName {
            case "title" where capture == .title: append(&titles)
            case "sub-title" where capture == .subtitle: append(&subtitles)
            case "desc" where capture == .desc: append(&descriptions)
            case "category" where capture == .category: append(&categories)
            case "episode-num" where capture == .episode:
                let currentSystem = system?.lowercased()
                let value = finishCapture()
                guard !value.isEmpty else { return }
                if currentSystem == "xmltv_ns" { episodeNS = value } else if currentSystem == "onscreen" || currentSystem == nil { episodeOnScreen = episodeOnScreen ?? value }
            case "value" where capture == .ratingValue:
                let value = finishCapture()
                if !value.isEmpty { rating = value }
            case "rating":
                inRating = false
            default:
                break
            }
        }
    }

    // MARK: Helpers

    private func begin(_ kind: Capture, _ attributes: [String: String]) {
        capture = kind
        text = ""
        lang = attributes["lang"]
        system = attributes["system"]
    }

    private func finishCapture() -> String {
        capture = .none
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        return value
    }

    private func append(_ list: inout [(String?, String)]) {
        let currentLang = lang
        let value = finishCapture()
        if !value.isEmpty { list.append((currentLang, value)) }
    }

    private func beginProgramme(_ attributes: [String: String]) {
        context = .programme
        programmeChannel = attributes["channel"]?.trimmingCharacters(in: .whitespaces) ?? ""
        start = attributes["start"].flatMap(XMLTVParser.parseTime).map { $0.addingTimeInterval(shift) }
        stop = attributes["stop"].flatMap(XMLTVParser.parseTime).map { $0.addingTimeInterval(shift) }
        skip = programmeChannel.isEmpty || start == nil
        if !skip, let window, let start {
            if start > window.end { skip = true }
            if let stop, stop < window.start { skip = true }
        }
        titles.removeAll(keepingCapacity: true)
        subtitles.removeAll(keepingCapacity: true)
        descriptions.removeAll(keepingCapacity: true)
        categories.removeAll(keepingCapacity: true)
        programmeIcon = nil
        episodeNS = nil
        episodeOnScreen = nil
        isNew = false
        inRating = false
        rating = nil
        capture = .none
    }

    private func endProgramme() {
        capture = .none
        guard !skip, let start else { return }
        let label = episodeNS.flatMap(XMLTVParser.episodeLabel(xmltvNS:)) ?? episodeOnScreen
        let program = EPGProgram(
            channelID: programmeChannel,
            start: start,
            end: stop ?? start,
            title: Self.preferred(titles) ?? "",
            subtitle: Self.preferred(subtitles),
            summary: Self.preferred(descriptions),
            category: Self.preferred(categories),
            categoryLabels: categories.count > 1 ? categories.map(\.1) : nil,
            iconURL: programmeIcon,
            episodeLabel: label,
            rating: rating,
            isNew: isNew
        )
        if stop == nil { missingStop.append(programs.count) }
        programs.append(program)
    }

    /// Prefers French, then the first value.
    static func preferred(_ values: [(String?, String)]) -> String? {
        if let fr = values.first(where: { isFrench($0.0) }) { return fr.1 }
        return values.first?.1
    }

    /// `lang` starting with "fr" in any letter case — same as `lowercased().hasPrefix("fr")`
    /// without allocating a folded copy (called per programme × 4 fields).
    static func isFrench(_ lang: String?) -> Bool {
        guard let lang else { return false }
        let bytes = lang.utf8
        guard bytes.count >= 2 else { return false }
        let a = bytes[bytes.startIndex]
        let b = bytes[bytes.index(after: bytes.startIndex)]
        return (a == 0x66 || a == 0x46) && (b == 0x72 || b == 0x52)
    }

    static func url(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// Fills missing `stop` times with the next programme start of the same channel, then applies the window.
    func finishPrograms() -> [EPGProgram] {
        if !missingStop.isEmpty {
            var byChannel: [String: [Int]] = [:]
            for (index, program) in programs.enumerated() { byChannel[program.channelID, default: []].append(index) }
            let needsStop = Set(missingStop)
            for indices in byChannel.values {
                let sorted = indices.sorted { programs[$0].start < programs[$1].start }
                var previousStart: Date?
                var nextStart: Date?
                for index in sorted.reversed() {
                    let start = programs[index].start
                    if start != previousStart {
                        nextStart = previousStart
                        previousStart = start
                    }
                    if needsStop.contains(index) {
                        programs[index].end = nextStart ?? start.addingTimeInterval(3600)
                    }
                }
            }
        }
        guard let window else { return programs }
        return programs.filter { $0.end >= window.start && $0.start <= window.end }
    }
}
