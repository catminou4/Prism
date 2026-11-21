import Foundation

/// Which decoding engine plays an item.
nonisolated public enum PlaybackEngineKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Pick automatically from the URL/container (AVFoundation for HLS/MP4, VLC otherwise),
    /// falling back to the other engine on failure.
    case auto
    case avFoundation
    case vlc

    /// Human readable engine name (French UI).
    public var displayName: String {
        switch self {
        case .auto: "Automatique"
        case .avFoundation: "AVFoundation"
        case .vlc: "VLC"
        }
    }
}

/// Everything the player needs to play one stream. Independent from PrismCore on purpose.
nonisolated public struct PlaybackItem: Identifiable, Hashable, Sendable, Codable {
    /// Usually `ContentID.rawValue`.
    public var id: String
    public var url: URL
    /// Tried in order when `url` fails (other variants/sources of the same content).
    public var fallbackURLs: [URL]
    public var title: String
    /// Secondary line, e.g. "S1, É1 · Pilote" or the current programme of a channel.
    public var subtitle: String?
    public var artworkURL: URL?
    public var isLive: Bool
    /// Resume position in seconds (VOD only).
    public var startPosition: TimeInterval?
    /// Extra HTTP headers (User-Agent, Referer…).
    public var httpHeaders: [String: String]
    public var preferredEngine: PlaybackEngineKind
    /// Container hint (`m3u8`, `ts`, `mkv`, `mp4`…) when the URL has no extension.
    public var containerHint: String?
    /// Live only: the stream exposes a seekable DVR window (±10 s skipping allowed).
    /// AVFoundation also detects a DVR window automatically from the HLS playlist.
    public var supportsTimeshift: Bool

    public init(
        id: String, url: URL, fallbackURLs: [URL] = [], title: String, subtitle: String? = nil,
        artworkURL: URL? = nil, isLive: Bool = false, startPosition: TimeInterval? = nil,
        httpHeaders: [String: String] = [:], preferredEngine: PlaybackEngineKind = .auto,
        containerHint: String? = nil, supportsTimeshift: Bool = false
    ) {
        self.id = id
        self.url = url
        self.fallbackURLs = fallbackURLs
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.isLive = isLive
        self.startPosition = startPosition
        self.httpHeaders = httpHeaders
        self.preferredEngine = preferredEngine
        self.containerHint = containerHint
        self.supportsTimeshift = supportsTimeshift
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, fallbackURLs, title, subtitle, artworkURL, isLive, startPosition
        case httpHeaders, preferredEngine, containerHint, supportsTimeshift
    }

    /// Tolerant decoding: every field added after the first version is optional in the payload.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        fallbackURLs = try c.decodeIfPresent([URL].self, forKey: .fallbackURLs) ?? []
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        artworkURL = try c.decodeIfPresent(URL.self, forKey: .artworkURL)
        isLive = try c.decodeIfPresent(Bool.self, forKey: .isLive) ?? false
        startPosition = try c.decodeIfPresent(TimeInterval.self, forKey: .startPosition)
        httpHeaders = try c.decodeIfPresent([String: String].self, forKey: .httpHeaders) ?? [:]
        preferredEngine = try c.decodeIfPresent(PlaybackEngineKind.self, forKey: .preferredEngine) ?? .auto
        containerHint = try c.decodeIfPresent(String.self, forKey: .containerHint)
        supportsTimeshift = try c.decodeIfPresent(Bool.self, forKey: .supportsTimeshift) ?? false
    }
}
