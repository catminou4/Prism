import Foundation

/// Which decoding engine plays an item.
public enum PlaybackEngineKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Pick automatically from the URL/container (AVFoundation for HLS/MP4, VLC otherwise),
    /// falling back to the other engine on failure.
    case auto
    case avFoundation
    case vlc
}

/// Everything the player needs to play one stream. Independent from PrismCore on purpose.
public struct PlaybackItem: Identifiable, Hashable, Sendable, Codable {
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

    public init(
        id: String, url: URL, fallbackURLs: [URL] = [], title: String, subtitle: String? = nil,
        artworkURL: URL? = nil, isLive: Bool = false, startPosition: TimeInterval? = nil,
        httpHeaders: [String: String] = [:], preferredEngine: PlaybackEngineKind = .auto,
        containerHint: String? = nil
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
    }
}
