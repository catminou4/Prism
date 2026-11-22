import Foundation

public struct M3UEntry: Sendable, Hashable {
    /// Text after the attribute list of `#EXTINF` (first top-level comma, so names may contain commas).
    public var name: String
    public var url: URL
    /// `-1` for live.
    public var duration: Int
    /// Lowercased keys: tvg-id, tvg-name, tvg-logo, tvg-chno, channel-number, group-title, catchup,
    /// catchup-days, catchup-source, timeshift, tvg-rec, tvg-shift…
    public var attributes: [String: String]
    /// `group-title`, else `#EXTGRP`.
    public var group: String?
    /// From `#EXTVLCOPT:http-user-agent / http-referrer / http-origin`, `#EXTHTTP:{json}`,
    /// `#KODIPROP` inputstream headers and Kodi-style `url|User-Agent=…&Referer=…` suffixes.
    public var headers: [String: String]

    public init(name: String, url: URL, duration: Int = -1, attributes: [String: String] = [:], group: String? = nil, headers: [String: String] = [:]) {
        self.name = name
        self.url = url
        self.duration = duration
        self.attributes = attributes
        self.group = group
        self.headers = headers
    }
}

public struct M3UPlaylist: Sendable {
    /// From `#EXTM3U url-tvg` / `x-tvg-url` / `tvg-url` (comma separated allowed).
    public var epgURLs: [URL]
    public var headerAttributes: [String: String]
    public var entries: [M3UEntry]

    public init(epgURLs: [URL] = [], headerAttributes: [String: String] = [:], entries: [M3UEntry] = []) {
        self.epgURLs = epgURLs
        self.headerAttributes = headerAttributes
        self.entries = entries
    }
}

/// Byte-level M3U / M3U8 (extended) playlist parser. Never throws: malformed lines are skipped.
/// Synchronous and pure — call it from a background task for large playlists.
public enum M3UParser {
    public static func parse(_ data: Data) -> M3UPlaylist {
        data.withUnsafeBytes { raw in
            parse(bytes: raw.bindMemory(to: UInt8.self))
        }
    }

    public static func parse(_ text: String) -> M3UPlaylist {
        var copy = text
        return copy.withUTF8 { parse(bytes: $0) }
    }

    // MARK: - Core

    static func parse(bytes buffer: UnsafeBufferPointer<UInt8>) -> M3UPlaylist {
        guard let b = buffer.baseAddress, buffer.count > 0 else { return M3UPlaylist() }
        var state = ParserState()
        let n = buffer.count
        var cursor = 0
        if n >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { cursor = 3 }
        state.entries.reserveCapacity(min(max(n / 220, 16), 400_000))

        while cursor < n {
            let lineEnd: Int
            if let newline = memchr(b + cursor, 0x0A, n - cursor) {
                lineEnd = UnsafePointer<UInt8>(newline.assumingMemoryBound(to: UInt8.self)) - b
            } else {
                lineEnd = n
            }
            // Lone CRs (classic Mac) or CRLF: split the segment on every CR.
            var segment = cursor
            while segment <= lineEnd {
                var segmentEnd = lineEnd
                if segment < lineEnd, let cr = memchr(b + segment, 0x0D, lineEnd - segment) {
                    segmentEnd = UnsafePointer<UInt8>(cr.assumingMemoryBound(to: UInt8.self)) - b
                }
                var start = segment
                var end = segmentEnd
                while start < end, b[start] == 0x20 || b[start] == 0x09 { start += 1 }
                while end > start, b[end - 1] == 0x20 || b[end - 1] == 0x09 { end -= 1 }
                if start < end {
                    if b[start] == 0x23 { // '#'
                        state.directive(b, start, end)
                    } else {
                        state.urlLine(b, start, end)
                    }
                }
                segment = segmentEnd + 1
            }
            cursor = lineEnd + 1
        }
        return M3UPlaylist(epgURLs: state.epgURLs, headerAttributes: state.header, entries: state.entries)
    }
}

// MARK: - State machine

private struct PendingInfo {
    var duration: Int
    var attributes: [String: String]
    var name: String
}

private struct ParserState {
    var entries: [M3UEntry] = []
    var header: [String: String] = [:]
    var epgURLs: [URL] = []
    var pending: PendingInfo?
    var pendingGroup: String?
    var pendingHeaders: [String: String] = [:]
    var keyScratch: [UInt8] = []

    init() {
        keyScratch.reserveCapacity(32)
    }

    mutating func directive(_ b: UnsafePointer<UInt8>, _ start: Int, _ end: Int) {
        if M3UBytes.hasPrefix(b, start, end, M3UBytes.extinf) {
            extinf(b, start + 8, end)
        } else {
            otherDirective(b, start, end)
        }
    }

    mutating func extinf(_ b: UnsafePointer<UInt8>, _ start: Int, _ end: Int) {
        var attributes: [String: String] = [:]
        var duration = -1
        var nameStart = end
        parseInfo(b, start, end, into: &attributes, duration: &duration, nameStart: &nameStart)
        var name = M3UBytes.trimmedString(b, nameStart, end)
        if name.isEmpty, let tvgName = attributes["tvg-name"], !tvgName.isEmpty { name = tvgName }
        pending = PendingInfo(duration: duration, attributes: attributes, name: name)
    }

    mutating func otherDirective(_ b: UnsafePointer<UInt8>, _ start: Int, _ end: Int) {
        if M3UBytes.hasPrefix(b, start, end, M3UBytes.extm3u) {
            var attributes: [String: String] = [:]
            _ = parseAttributes(b, start + M3UBytes.extm3u.count, end, into: &attributes, stopAtComma: false)
            for (key, value) in attributes { header[key] = value }
            for key in ["url-tvg", "x-tvg-url", "tvg-url"] {
                guard let value = attributes[key] else { continue }
                for part in value.split(separator: ",") {
                    let trimmed = part.trimmingCharacters(in: .whitespaces)
                    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
                          ["http", "https", "file"].contains(scheme), !epgURLs.contains(url) else { continue }
                    epgURLs.append(url)
                }
            }
        } else if M3UBytes.hasPrefix(b, start, end, M3UBytes.extgrp) {
            let value = M3UBytes.trimmedString(b, start + M3UBytes.extgrp.count, end)
            pendingGroup = value.isEmpty ? nil : value
        } else if M3UBytes.hasPrefix(b, start, end, M3UBytes.extvlcopt) {
            let option = M3UBytes.string(b, start + M3UBytes.extvlcopt.count, end)
            guard let eq = option.firstIndex(of: "=") else { return }
            let key = option[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = option[option.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return }
            switch key {
            case "http-user-agent": pendingHeaders["User-Agent"] = value
            case "http-referrer", "http-referer": pendingHeaders["Referer"] = value
            case "http-origin": pendingHeaders["Origin"] = value
            case "http-cookie": pendingHeaders["Cookie"] = value
            default: break
            }
        } else if M3UBytes.hasPrefix(b, start, end, M3UBytes.exthttp) {
            let json = Data(bytes: b + start + M3UBytes.exthttp.count, count: end - start - M3UBytes.exthttp.count)
            guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return }
            for (key, value) in object {
                let string: String
                if let s = value as? String { string = s } else if let n = value as? NSNumber { string = n.stringValue } else { continue }
                guard !string.isEmpty else { continue }
                pendingHeaders[M3UHeaders.canonicalName(key)] = string
            }
        } else if M3UBytes.hasPrefix(b, start, end, M3UBytes.kodiprop) {
            let property = M3UBytes.string(b, start + M3UBytes.kodiprop.count, end)
            guard let eq = property.firstIndex(of: "=") else { return }
            let key = property[..<eq].lowercased()
            guard key.hasSuffix("stream_headers") || key.hasSuffix("manifest_headers") || key.hasSuffix("common_headers") else { return }
            M3UHeaders.parsePipeHeaders(String(property[property.index(after: eq)...]), into: &pendingHeaders)
        }
    }

    mutating func urlLine(_ b: UnsafePointer<UInt8>, _ start: Int, _ end: Int) {
        var urlEnd = end
        var pipe = -1
        if let found = memchr(b + start, 0x7C, end - start) {
            pipe = UnsafePointer<UInt8>(found.assumingMemoryBound(to: UInt8.self)) - b
        }
        if pipe >= 0 {
            urlEnd = pipe
            while urlEnd > start, b[urlEnd - 1] == 0x20 { urlEnd -= 1 }
        }
        guard M3UBytes.hasAllowedScheme(b, start, urlEnd) else {
            return
        }
        let urlString = M3UBytes.string(b, start, urlEnd)
        guard let url = M3UBytes.makeURL(urlString) else { return }

        var headers = pendingHeaders
        if pipe >= 0, pipe + 1 < end {
            M3UHeaders.parsePipeHeaders(M3UBytes.string(b, pipe + 1, end), into: &headers)
        }

        let entry: M3UEntry
        if let info = pending {
            var group = info.attributes["group-title"]
            if group?.isEmpty ?? true { group = pendingGroup }
            let attributes = info.attributes
            if attributes.count > 4 {
                for key in M3UBytes.userAgentKeys where headers["User-Agent"] == nil {
                    if let ua = attributes[key], !ua.isEmpty { headers["User-Agent"] = ua }
                }
                for key in M3UBytes.refererKeys where headers["Referer"] == nil {
                    if let ref = attributes[key], !ref.isEmpty { headers["Referer"] = ref }
                }
            }
            let name = info.name.isEmpty ? M3UBytes.fallbackName(url) : info.name
            entry = M3UEntry(name: name, url: url, duration: info.duration, attributes: attributes, group: group, headers: headers)
        } else {
            entry = M3UEntry(name: M3UBytes.fallbackName(url), url: url, duration: -1, attributes: [:], group: pendingGroup, headers: headers)
        }
        entries.append(entry)
        pending = nil
        if !pendingHeaders.isEmpty { pendingHeaders = [:] }
    }

    /// Parses `-1 tvg-id="…" group-title="…",Name` → duration + index of the name.
    mutating func parseInfo(_ b: UnsafePointer<UInt8>, _ start: Int, _ end: Int, into attributes: inout [String: String], duration: inout Int, nameStart: inout Int) {
        var p = start
        while p < end, b[p] == 0x20 || b[p] == 0x09 { p += 1 }
        var negative = false
        if p < end, b[p] == 0x2D { negative = true; p += 1 } else if p < end, b[p] == 0x2B { p += 1 }
        var value = 0
        var digits = 0
        while p < end, b[p] >= 0x30, b[p] <= 0x39 {
            if digits < 12 { value = value * 10 + Int(b[p] - 0x30) }
            digits += 1
            p += 1
        }
        if p < end, b[p] == 0x2E { // fractional part
            p += 1
            while p < end, b[p] >= 0x30, b[p] <= 0x39 { p += 1 }
        }
        duration = digits == 0 ? -1 : (negative ? -value : value)
        nameStart = parseAttributes(b, p, end, into: &attributes, stopAtComma: true)
    }

    /// Returns the index just after the first top-level comma (or `end`).
    mutating func parseAttributes(_ b: UnsafePointer<UInt8>, _ start: Int, _ end: Int, into attributes: inout [String: String], stopAtComma: Bool) -> Int {
        var p = start
        while p < end {
            let c = b[p]
            if c == 0x20 || c == 0x09 { p += 1; continue }
            if c == 0x2C { // ','
                if stopAtComma { return p + 1 }
                p += 1
                continue
            }
            // key
            let keyStart = p
            while p < end, b[p] != 0x3D, b[p] != 0x20, b[p] != 0x09, b[p] != 0x2C { p += 1 }
            let keyEnd = p
            guard p < end, b[p] == 0x3D, keyEnd > keyStart else {
                // Bare token: ignore it. A stray '=' where a key should start must still be
                // consumed, otherwise the scan never advances.
                if p == keyStart { p += 1 }
                continue
            }
            p += 1 // '='
            var valueStart = p
            var valueEnd = p
            if p < end, b[p] == 0x22 || b[p] == 0x27 {
                let quote = b[p]
                p += 1
                valueStart = p
                var close = -1
                if p < end, let found = memchr(b + p, Int32(quote), end - p) {
                    close = UnsafePointer<UInt8>(found.assumingMemoryBound(to: UInt8.self)) - b
                }
                if close >= 0 {
                    valueEnd = close
                    p = close + 1
                } else {
                    // Unterminated quote: value stops at the next comma.
                    var k2 = end
                    if p < end, let comma = memchr(b + p, 0x2C, end - p) {
                        k2 = UnsafePointer<UInt8>(comma.assumingMemoryBound(to: UInt8.self)) - b
                    }
                    valueEnd = k2
                    p = k2
                }
            } else {
                while p < end, b[p] != 0x20, b[p] != 0x09, !(stopAtComma && b[p] == 0x2C) { p += 1 }
                valueEnd = p
            }
            var hasUpper = false
            var k = keyStart
            while k < keyEnd {
                if b[k] >= 0x41 && b[k] <= 0x5A { hasUpper = true; break }
                k += 1
            }
            let key: String
            if hasUpper {
                keyScratch.removeAll(keepingCapacity: true)
                var k = keyStart
                while k < keyEnd {
                    let byte = b[k]
                    keyScratch.append(byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte)
                    k += 1
                }
                key = String(decoding: keyScratch, as: UTF8.self)
            } else {
                key = String(decoding: UnsafeBufferPointer(start: b + keyStart, count: keyEnd - keyStart), as: UTF8.self)
            }
            let value = M3UBytes.trimmedString(b, valueStart, valueEnd)
            attributes[key] = value
        }
        return end
    }
}

// MARK: - Byte helpers

enum M3UBytes {
    static let extinf = Array("#EXTINF:".utf8)
    static let extm3u = Array("#EXTM3U".utf8)
    static let extgrp = Array("#EXTGRP:".utf8)
    static let extvlcopt = Array("#EXTVLCOPT:".utf8)
    static let exthttp = Array("#EXTHTTP:".utf8)
    static let kodiprop = Array("#KODIPROP:".utf8)

    static let allowedSchemes: Set<UInt64> = Set(
        ["http", "https", "rtmp", "rtmps", "rtmpt", "rtsp", "rtsps", "udp", "rtp", "mms", "mmsh", "file", "srt"].map { name in
            var packed: UInt64 = 0
            for (k, byte) in name.utf8.enumerated() { packed |= UInt64(byte) << UInt64(k * 8) }
            return packed
        }
    )

    /// Case-insensitive ASCII prefix check (`prefix` is uppercase).
    @inline(__always)
    static func hasPrefix(_ b: UnsafePointer<UInt8>, _ start: Int, _ end: Int, _ prefix: [UInt8]) -> Bool {
        let count = prefix.count
        guard end - start >= count else { return false }
        return prefix.withUnsafeBufferPointer { pp in
            guard let q = pp.baseAddress else { return false }
            var k = 0
            while k < count {
                var c = b[start + k]
                if c >= 0x61 && c <= 0x7A { c -= 32 }
                if c != q[k] { return false }
                k += 1
            }
            return true
        }
    }

    static func hasAllowedScheme(_ b: UnsafePointer<UInt8>, _ start: Int, _ end: Int) -> Bool {
        var k = start
        var packed: UInt64 = 0
        while k < end, k - start < 8 {
            let c = b[k]
            if c == 0x3A { break } // ':'
            let lower = c >= 0x41 && c <= 0x5A ? c | 0x20 : c
            guard (lower >= 0x61 && lower <= 0x7A) || (lower >= 0x30 && lower <= 0x39 && k > start) || lower == 0x2B else { return false }
            packed |= UInt64(lower) << UInt64((k - start) * 8)
            k += 1
        }
        guard k < end, k > start, b[k] == 0x3A else { return false }
        return allowedSchemes.contains(packed)
    }

    static let userAgentKeys = ["user-agent", "http-user-agent"]
    static let refererKeys = ["http-referrer", "referrer", "http-referer", "referer"]

    static func trimmedString(_ b: UnsafePointer<UInt8>, _ start: Int, _ end: Int) -> String {
        var s = start
        var e = end
        while s < e, b[s] == 0x20 || b[s] == 0x09 { s += 1 }
        while e > s, b[e - 1] == 0x20 || b[e - 1] == 0x09 { e -= 1 }
        return string(b, s, e)
    }

    /// UTF-8 when valid, ISO-Latin-1 otherwise (per line, so mixed files survive).
    static func string(_ b: UnsafePointer<UInt8>, _ start: Int, _ end: Int) -> String {
        guard end > start else { return "" }
        let slice = UnsafeBufferPointer(start: b + start, count: end - start)
        if let string = String(validating: slice, as: UTF8.self) { return string }
        var scalars = String.UnicodeScalarView()
        for byte in slice { scalars.append(Unicode.Scalar(byte)) }
        return String(scalars)
    }

    private static let urlAllowed: CharacterSet = {
        var set = CharacterSet.urlFragmentAllowed
        set.insert(charactersIn: "%#")
        return set
    }()

    static func makeURL(_ string: String) -> URL? {
        if let url = URL(string: string), url.scheme != nil {
            return url
        }
        guard let encoded = string.addingPercentEncoding(withAllowedCharacters: urlAllowed) else { return nil }
        return URL(string: encoded)
    }

    static func fallbackName(_ url: URL) -> String {
        let last = url.deletingPathExtension().lastPathComponent
        if !last.isEmpty, last != "/" { return last.removingPercentEncoding ?? last }
        return url.host() ?? url.absoluteString
    }
}

enum M3UHeaders {
    static func canonicalName(_ name: String) -> String {
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "user-agent", "useragent", "http-user-agent": "User-Agent"
        case "referer", "referrer", "http-referrer", "http-referer": "Referer"
        case "origin", "http-origin": "Origin"
        case "cookie", "http-cookie": "Cookie"
        case "authorization": "Authorization"
        default: name.trimmingCharacters(in: .whitespaces)
        }
    }

    /// `User-Agent=Foo%20Bar&Referer=http://x/` → headers (values percent-decoded when possible).
    static func parsePipeHeaders(_ text: String, into headers: inout [String: String]) {
        for pair in text.split(separator: "&") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let rawName = String(pair[..<eq])
            guard !rawName.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let rawValue = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            let value = rawValue.removingPercentEncoding ?? rawValue
            guard !value.isEmpty else { continue }
            headers[canonicalName(rawName.removingPercentEncoding ?? rawName)] = value
        }
    }
}
