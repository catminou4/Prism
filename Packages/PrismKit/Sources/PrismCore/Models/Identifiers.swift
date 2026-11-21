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

    private var parts: [Substring] { rawValue.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false) }
    public var sourceID: SourceID { SourceID(String(parts.first ?? "")) }
    public var kind: MediaKind? { parts.count > 1 ? MediaKind(rawValue: String(parts[1])) : nil }
    public var nativeID: String { parts.count > 2 ? String(parts[2]) : "" }
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
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public var description: String { rawValue }
}
