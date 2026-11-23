import Foundation
import libxml2

/// libxml2 push-parser (SAX2) fast path for `XMLTVParser` — the same engine
/// Foundation's `XMLParser` wraps, without the NSString/NSDictionary bridging
/// layer that dominates parse time on large XMLTV feeds.
///
/// Equivalence strategy: a DOCTYPE internal subset can declare custom entities
/// and attribute defaults that change parsing semantics (Foundation's entity
/// handling is quirky and not reproducible callback-for-callback). Any actual
/// DTD *declaration* (`entityDecl`, `attributeDecl`, `elementDecl`,
/// `notationDecl`, `unparsedEntityDecl`, parameter entities) therefore stops the
/// SAX parse and re-parses through `XMLParser` for bit-exact behavior. The
/// `internalSubset` callback cannot be used as the trigger: it fires for every
/// DOCTYPE, including external-only ones like `<!DOCTYPE tv SYSTEM "xmltv.dtd">`,
/// which real XMLTV feeds use and which carry no declarations.
extension XMLTVParser {
    /// Parses already-decompressed XML. Documents with DTD declarations fall
    /// back to `parseFoundationXML`.
    static func parseXML(_ xml: Data, window: DateInterval?, timeShiftHours: Double) throws -> XMLTVDocument {
        let delegate = XMLTVSAXDelegate(window: window, shift: timeShiftHours * 3600)
        var handler = xmlSAXHandler()
        handler.initialized = XML_SAX2_MAGIC
        let opaque = Unmanaged.passUnretained(delegate).toOpaque()
        handler.startElementNs = { ctx, localname, _, _, _, _, nbAttributes, _, attributes in
            guard let ctx, let localname else { return }
            let delegate = Unmanaged<XMLTVSAXDelegate>.fromOpaque(ctx).takeUnretainedValue()
            delegate.startElement(localname: localname, attributes: attributes, count: Int(nbAttributes))
        }
        handler.endElementNs = { ctx, localname, _, _ in
            guard let ctx, let localname else { return }
            let delegate = Unmanaged<XMLTVSAXDelegate>.fromOpaque(ctx).takeUnretainedValue()
            delegate.endElement(localname: localname)
        }
        handler.characters = { ctx, ch, len in
            guard let ctx, let ch, len > 0 else { return }
            let delegate = Unmanaged<XMLTVSAXDelegate>.fromOpaque(ctx).takeUnretainedValue()
            delegate.characters(ch, len: Int(len))
        }
        handler.cdataBlock = handler.characters
        handler.ignorableWhitespace = handler.characters
        // DTD declarations → custom entities / attribute defaults may apply.
        // Bail out and let the caller re-parse with Foundation's XMLParser.
        handler.entityDecl = { ctx, _, _, _, _, _ in xmlMarkDTDDecl(ctx) }
        handler.attributeDecl = { ctx, _, _, _, _, _, _ in xmlMarkDTDDecl(ctx) }
        handler.elementDecl = { ctx, _, _, _ in xmlMarkDTDDecl(ctx) }
        handler.notationDecl = { ctx, _, _, _ in xmlMarkDTDDecl(ctx) }
        handler.unparsedEntityDecl = { ctx, _, _, _, _ in xmlMarkDTDDecl(ctx) }
        handler.getParameterEntity = { ctx, _ in xmlMarkDTDDecl(ctx); return nil }

        guard let ctxt = xmlCreatePushParserCtxt(&handler, opaque, nil, 0, nil) else {
            throw XMLTVError.invalidData
        }
        defer { xmlFreeParserCtxt(ctxt) }
        // Match `shouldResolveExternalEntities = false`: never touch the network
        // for external DTDs/entities, regardless of process-wide libxml2 globals.
        _ = xmlCtxtUseOptions(ctxt, Int32(XML_PARSE_NONET.rawValue))
        delegate.parserCtxt = ctxt

        var fed = 0
        let total = xml.count
        // Feed in ≤256 MiB slices so `size` always fits Int32 with headroom.
        xml.withUnsafeBytes { raw in
            if let base = raw.bindMemory(to: CChar.self).baseAddress {
                while fed < total, !delegate.dtdDeclsFound {
                    let take = min(total - fed, 256 << 20)
                    _ = xmlParseChunk(ctxt, base + fed, Int32(take), 0)
                    fed += take
                }
            }
        }
        _ = xmlParseChunk(ctxt, nil, 0, 1)

        if delegate.dtdDeclsFound {
            return try parseFoundationXML(xml, window: window, timeShiftHours: timeShiftHours)
        }

        let wellFormed = ctxt.pointee.wellFormed != 0
        if !wellFormed && delegate.channels.isEmpty && delegate.programs.isEmpty {
            throw XMLTVError.invalidData
        }
        return XMLTVDocument(channels: delegate.channels, programs: delegate.finishPrograms())
    }
}

/// SAX2 delegate mirroring `XMLTVParserDelegate` semantics exactly, but fed raw
/// UTF-8 bytes instead of bridged Strings.
private final class XMLTVSAXDelegate {
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

    var channelID = ""
    var displayNames: [String] = []
    var channelIcon: URL?

    /// Set when the document declares DTD entities/attlists/etc. — triggers fallback.
    var dtdDeclsFound = false
    /// Back-reference used only to halt parsing early on the DTD fallback.
    var parserCtxt: xmlParserCtxtPtr?

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

    // MARK: - SAX callbacks

    /// `attributes` is the flat SAX2 array: groups of 5 (localname, prefix, URI,
    /// value, valueEnd). Values are counted strings (`valueEnd - value`), names
    /// are NUL-terminated. Foundation reports *element* names as local names
    /// (`shouldProcessNamespaces = true`) but attribute keys as *qualified* names
    /// (`prefix:local`), so a namespaced attribute never matches a bare name —
    /// same rule here.
    func startElement(localname: UnsafePointer<UInt8>, attributes: UnsafePointer<UnsafePointer<UInt8>?>?, count: Int) {
        switch context {
        case .none:
            if xmlNameIs(localname, "programme") {
                beginProgramme(attributes: attributes, count: count)
            } else if xmlNameIs(localname, "channel") {
                context = .channel
                channelID = xmlAttributeString(attributes, count: count, named: "id").map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                displayNames = []
                channelIcon = nil
            }
        case .channel:
            if xmlNameIs(localname, "display-name") {
                begin(.displayName, attributes: attributes, count: count)
            } else if xmlNameIs(localname, "icon"), channelIcon == nil {
                channelIcon = xmlAttribute(attributes, count: count, named: "src").flatMap { Self.url(xmlString($0)) }
            }
        case .programme:
            guard !skip else { return }
            if xmlNameIs(localname, "title") {
                begin(.title, attributes: attributes, count: count)
            } else if xmlNameIs(localname, "sub-title") {
                begin(.subtitle, attributes: attributes, count: count)
            } else if xmlNameIs(localname, "desc") {
                begin(.desc, attributes: attributes, count: count)
            } else if xmlNameIs(localname, "category") {
                begin(.category, attributes: attributes, count: count)
            } else if xmlNameIs(localname, "episode-num") {
                begin(.episode, attributes: attributes, count: count)
            } else if xmlNameIs(localname, "icon"), programmeIcon == nil {
                programmeIcon = xmlAttribute(attributes, count: count, named: "src").flatMap { Self.url(xmlString($0)) }
            } else if xmlNameIs(localname, "new") {
                isNew = true
            } else if xmlNameIs(localname, "rating") {
                inRating = true
            } else if xmlNameIs(localname, "value"), inRating, rating == nil {
                begin(.ratingValue, attributes: attributes, count: count)
            }
        }
    }

    func endElement(localname: UnsafePointer<UInt8>) {
        switch context {
        case .none:
            return
        case .channel:
            if xmlNameIs(localname, "channel") {
                if !channelID.isEmpty {
                    channels.append(XMLTVChannel(id: channelID, displayNames: displayNames, iconURL: channelIcon))
                }
                context = .none
            } else if xmlNameIs(localname, "display-name"), capture == .displayName {
                let value = finishCapture()
                if !value.isEmpty, !displayNames.contains(value) { displayNames.append(value) }
            }
        case .programme:
            if xmlNameIs(localname, "programme") {
                endProgramme()
                context = .none
                return
            }
            guard !skip else { return }
            if xmlNameIs(localname, "title"), capture == .title {
                append(&titles)
            } else if xmlNameIs(localname, "sub-title"), capture == .subtitle {
                append(&subtitles)
            } else if xmlNameIs(localname, "desc"), capture == .desc {
                append(&descriptions)
            } else if xmlNameIs(localname, "category"), capture == .category {
                append(&categories)
            } else if xmlNameIs(localname, "episode-num"), capture == .episode {
                let currentSystem = system?.lowercased()
                let value = finishCapture()
                guard !value.isEmpty else { return }
                if currentSystem == "xmltv_ns" { episodeNS = value } else if currentSystem == "onscreen" || currentSystem == nil { episodeOnScreen = episodeOnScreen ?? value }
            } else if xmlNameIs(localname, "value"), capture == .ratingValue {
                let value = finishCapture()
                if !value.isEmpty { rating = value }
            } else if xmlNameIs(localname, "rating") {
                inRating = false
            }
        }
    }

    func characters(_ ch: UnsafePointer<UInt8>, len: Int) {
        // Decode per callback exactly like Foundation's `foundCharacters` —
        // `String(decoding:)` repairs split multi-byte sequences identically.
        guard capture != .none, len > 0 else { return }
        text += String(decoding: UnsafeBufferPointer(start: ch, count: len), as: UTF8.self)
    }

    // MARK: - Helpers (same semantics as XMLTVParserDelegate)

    private func begin(_ kind: Capture, attributes: UnsafePointer<UnsafePointer<UInt8>?>?, count: Int) {
        capture = kind
        text = ""
        lang = xmlAttribute(attributes, count: count, named: "lang").map { xmlString($0) }
        system = xmlAttribute(attributes, count: count, named: "system").map { xmlString($0) }
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

    private func beginProgramme(attributes: UnsafePointer<UnsafePointer<UInt8>?>?, count: Int) {
        context = .programme
        programmeChannel = xmlAttributeString(attributes, count: count, named: "channel").map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        start = xmlAttribute(attributes, count: count, named: "start").flatMap { XMLTVParser.parseTime(bytes: $0) }.map { $0.addingTimeInterval(shift) }
        stop = xmlAttribute(attributes, count: count, named: "stop").flatMap { XMLTVParser.parseTime(bytes: $0) }.map { $0.addingTimeInterval(shift) }
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
        text = ""
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

    /// `lang` starting with "fr" in any letter case — same as
    /// `lowercased().hasPrefix("fr")` without allocating a folded copy.
    static func isFrench(_ lang: String?) -> Bool {
        guard let lang else { return false }
        let bytes = lang.utf8
        guard bytes.count >= 2 else { return false }
        let a = bytes[bytes.startIndex]
        let b = bytes[bytes.index(after: bytes.startIndex)]
        return (a == 0x66 || a == 0x46) && (b == 0x72 || b == 0x52)
    }

    static func url(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// Fills missing `stop` times with the next programme start of the same
    /// channel, then applies the window.
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

// MARK: - C interop helpers

@inline(__always)
private func xmlNameIs(_ name: UnsafePointer<UInt8>, _ expected: StaticString) -> Bool {
    expected.withUTF8Buffer { buffer in
        guard let base = buffer.baseAddress, buffer.count > 0 else { return false }
        return name.withMemoryRebound(to: CChar.self, capacity: buffer.count) { nameC in
            strncmp(nameC, UnsafePointer<CChar>(OpaquePointer(base)), buffer.count) == 0
                && nameC[buffer.count] == 0
        }
    }
}

/// Finds attribute `named` in the SAX2 attribute array. Matches on the *qualified*
/// name like Foundation's attributes dictionary: `prefix:local` never equals a
/// bare name, so prefixed attributes are skipped (prefix must be absent).
/// Returns the value as a counted UTF-8 buffer (`valueEnd - value`).
private func xmlAttribute(_ attributes: UnsafePointer<UnsafePointer<UInt8>?>?, count: Int, named name: StaticString) -> UnsafeBufferPointer<UInt8>? {
    guard let attributes else { return nil }
    return name.withUTF8Buffer { buffer in
        guard let base = buffer.baseAddress else { return nil }
        let needle = UnsafeRawPointer(base).assumingMemoryBound(to: CChar.self)
        for index in 0..<count {
            let local = attributes[index * 5]
            let prefix = attributes[index * 5 + 1]
            let value = attributes[index * 5 + 3]
            let valueEnd = attributes[index * 5 + 4]
            guard let local, prefix == nil, let value, let valueEnd, valueEnd >= value else { continue }
            let localC = UnsafeRawPointer(local).assumingMemoryBound(to: CChar.self)
            if strncmp(localC, needle, buffer.count) == 0, localC[buffer.count] == 0 {
                return UnsafeBufferPointer(start: value, count: valueEnd - value)
            }
        }
        return nil
    }
}

private func xmlAttributeString(_ attributes: UnsafePointer<UnsafePointer<UInt8>?>?, count: Int, named name: StaticString) -> String? {
    xmlAttribute(attributes, count: count, named: name).map { String(decoding: $0, as: UTF8.self) }
}

private func xmlString(_ buffer: UnsafeBufferPointer<UInt8>) -> String {
    String(decoding: buffer, as: UTF8.self)
}

/// Marks the document as having DTD declarations and stops the SAX parse early;
/// `parseXML` then re-parses with Foundation's XMLParser.
private func xmlMarkDTDDecl(_ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    let delegate = Unmanaged<XMLTVSAXDelegate>.fromOpaque(ctx).takeUnretainedValue()
    delegate.dtdDeclsFound = true
    if let ctxt = delegate.parserCtxt { xmlStopParser(ctxt) }
}
