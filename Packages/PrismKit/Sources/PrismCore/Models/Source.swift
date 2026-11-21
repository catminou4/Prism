import Foundation

public enum SourceKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Xtream Codes API (`player_api.php`).
    case xtream
    /// Remote M3U / M3U8 playlist URL.
    case m3uURL
    /// Local M3U file (security-scoped bookmark).
    case m3uFile
}

/// Accent used for the source avatar in the sidebar and source pickers.
public enum SourceTint: Int, Codable, Sendable, Hashable, CaseIterable {
    case blue, purple, pink, red, orange, yellow, green, teal
}

/// A user-configured IPTV source. Passwords are never stored here; see `CredentialStore`.
public struct Source: Identifiable, Codable, Sendable, Hashable {
    public var id: SourceID
    public var name: String
    public var kind: SourceKind
    /// Xtream: server base URL (`http://host:port`). M3U URL: the playlist URL.
    public var serverURL: URL?
    /// Xtream username.
    public var username: String?
    /// Security-scoped bookmark of a local M3U file.
    public var fileBookmark: Data?
    /// Optional XMLTV URL. For Xtream, defaults to `<server>/xmltv.php?username=…&password=…`.
    public var epgURL: URL?
    /// Optional custom HTTP User-Agent used for API, EPG and stream requests.
    public var userAgent: String?
    /// Hours added to every EPG programme time (provider clock drift).
    public var epgTimeShiftHours: Double
    /// Prefer HLS (`.m3u8`) output for Xtream live streams when the account allows it.
    public var preferHLSForLive: Bool
    public var tint: SourceTint
    public var isEnabled: Bool
    public var createdAt: Date
    public var lastRefreshedAt: Date?

    public init(
        id: SourceID = .generate(),
        name: String,
        kind: SourceKind,
        serverURL: URL? = nil,
        username: String? = nil,
        fileBookmark: Data? = nil,
        epgURL: URL? = nil,
        userAgent: String? = nil,
        epgTimeShiftHours: Double = 0,
        preferHLSForLive: Bool = true,
        tint: SourceTint = .blue,
        isEnabled: Bool = true,
        createdAt: Date = .now,
        lastRefreshedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.serverURL = serverURL
        self.username = username
        self.fileBookmark = fileBookmark
        self.epgURL = epgURL
        self.userAgent = userAgent
        self.epgTimeShiftHours = epgTimeShiftHours
        self.preferHLSForLive = preferHLSForLive
        self.tint = tint
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.lastRefreshedAt = lastRefreshedAt
    }
}

/// Xtream account details returned by `player_api.php` authentication.
public struct XtreamAccount: Codable, Sendable, Hashable {
    public var username: String
    public var status: String
    public var isActive: Bool
    public var isTrial: Bool
    public var expiresAt: Date?
    public var createdAt: Date?
    public var maxConnections: Int?
    public var activeConnections: Int?
    /// e.g. ["m3u8", "ts", "rtmp"].
    public var allowedOutputFormats: [String]
    public var serverTimeZone: String?
    public var serverURL: URL?

    public init(
        username: String, status: String, isActive: Bool, isTrial: Bool = false,
        expiresAt: Date? = nil, createdAt: Date? = nil, maxConnections: Int? = nil,
        activeConnections: Int? = nil, allowedOutputFormats: [String] = [],
        serverTimeZone: String? = nil, serverURL: URL? = nil
    ) {
        self.username = username
        self.status = status
        self.isActive = isActive
        self.isTrial = isTrial
        self.expiresAt = expiresAt
        self.createdAt = createdAt
        self.maxConnections = maxConnections
        self.activeConnections = activeConnections
        self.allowedOutputFormats = allowedOutputFormats
        self.serverTimeZone = serverTimeZone
        self.serverURL = serverURL
    }
}
