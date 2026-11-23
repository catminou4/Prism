import Foundation

/// Stable identifier of a user-configured source (Xtream account, M3U playlist…).
public struct SourceID: Hashable, Codable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func generate() -> SourceID { SourceID(UUID().uuidString.lowercased()) }
    public var description: String { rawValue }
}

/// Kind of playable or browsable content.
public enum MediaKind: String, Codable, Sendable, Hashable, CaseIterable {
    case live, movie, series, episode
}

/// Globally unique identifier of a single piece of content inside one source.
/// Format: `<sourceID>:<kind>:<nativeID>`.
public struct ContentID: Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(source: SourceID, kind: MediaKind, nativeID: String) {
        rawValue = "\(source.rawValue):\(kind.rawValue):\(nativeID)"
    }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// `:` is ASCII: scanning the UTF-8 view finds the same component boundaries as
    /// `split(separator: ":", maxSplits: 2)` without allocating the substring array per access.
    public var sourceID: SourceID {
        let bytes = rawValue.utf8
        guard let colon = bytes.firstIndex(of: UInt8(ascii: ":")) else { return SourceID(rawValue) }
        return SourceID(String(decoding: bytes[..<colon], as: UTF8.self))
    }
    public var kind: MediaKind? {
        let bytes = rawValue.utf8
        guard let first = bytes.firstIndex(of: UInt8(ascii: ":")) else { return nil }
        let start = bytes.index(after: first)
        let end = bytes[start...].firstIndex(of: UInt8(ascii: ":")) ?? bytes.endIndex
        return MediaKind(rawValue: String(decoding: bytes[start..<end], as: UTF8.self))
    }
    public var nativeID: String {
        let bytes = rawValue.utf8
        guard let first = bytes.firstIndex(of: UInt8(ascii: ":")) else { return "" }
        let middle = bytes.index(after: first)
        guard let second = bytes[middle...].firstIndex(of: UInt8(ascii: ":")) else { return "" }
        return String(decoding: bytes[bytes.index(after: second)...], as: UTF8.self)
    }
    public var description: String { rawValue }
    public static func < (lhs: ContentID, rhs: ContentID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Identifier of a *title* grouped across sources/variants (e.g. "movie:avatar:2009").
public struct TitleID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(kind: MediaKind, normalizedTitle: String, year: Int?) {
        rawValue = "\(kind.rawValue):\(normalizedTitle):\(year.map(String.init) ?? "")"
    }
    public init(kind: MediaKind, tmdbID: Int) {
        rawValue = "\(kind.rawValue):#tmdb:\(tmdbID)"
    }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public var description: String { rawValue }
}
