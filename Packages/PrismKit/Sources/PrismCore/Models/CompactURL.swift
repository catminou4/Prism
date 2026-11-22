import Foundation

/// An optional URL kept as its text.
///
/// A Foundation `URL` holds its parsed components in a heap object of several hundred bytes; the
/// same address as a `String` costs a few dozen. Catalogues carry hundreds of thousands of artwork
/// and stream addresses, read only for the few items on screen, so they are stored as text and
/// parsed on access. The wrapped property keeps its `URL?` type, and the JSON is unchanged (a
/// string, omitted when `nil`), so existing caches decode as before.
///
/// `$property` reads the text without parsing (`title.$posterURL != nil` in hot loops).
@propertyWrapper
public struct CompactURL: Hashable, Sendable, Codable {
    public var text: String?

    public init(wrappedValue: URL?) { text = wrappedValue?.absoluteString }
    public init(text: String?) { self.text = text }

    public var wrappedValue: URL? {
        get { text.flatMap { URL(string: $0) } }
        set { text = newValue?.absoluteString }
    }

    public var projectedValue: String? {
        get { text }
        set { text = newValue }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        text = container.decodeNil() ? nil : try container.decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let text { try container.encode(text) } else { try container.encodeNil() }
    }
}

/// A required URL kept as its text (see `CompactURL`).
@propertyWrapper
public struct CompactRequiredURL: Hashable, Sendable, Codable {
    public var text: String

    public init(wrappedValue: URL) { text = wrappedValue.absoluteString }
    public init(text: String) { self.text = text }

    /// The text always comes from a valid URL (or from a cache written from one); a placeholder
    /// that no player opens keeps the type non-optional if the file was tampered with.
    public var wrappedValue: URL {
        get { URL(string: text) ?? Self.unusable }
        set { text = newValue.absoluteString }
    }

    public var projectedValue: String {
        get { text }
        set { text = newValue }
    }

    private static let unusable = URL(fileURLWithPath: "/dev/null")

    public init(from decoder: any Decoder) throws {
        text = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

// Synthesized `Codable` calls these for wrapped properties: a missing key decodes as `nil` and a
// `nil` value is omitted, exactly like a plain `URL?` property.
extension KeyedDecodingContainer {
    public func decode(_ type: CompactURL.Type, forKey key: Key) throws -> CompactURL {
        CompactURL(text: try decodeIfPresent(String.self, forKey: key))
    }
}

extension KeyedEncodingContainer {
    public mutating func encode(_ value: CompactURL, forKey key: Key) throws {
        if let text = value.text { try encode(text, forKey: key) }
    }
}
