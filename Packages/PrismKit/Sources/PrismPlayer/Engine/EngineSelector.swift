import Foundation

/// One (url, engine) pair tried by the player. `engine` is never `.auto`.
nonisolated public struct PlaybackAttempt: Hashable, Sendable, CustomStringConvertible {
    public var url: URL
    public var engine: PlaybackEngineKind

    public init(url: URL, engine: PlaybackEngineKind) {
        self.url = url
        self.engine = engine
    }

    public var description: String { "\(engine.rawValue) → \(url.absoluteString)" }
}

/// Pure engine resolution: AVFoundation for what it plays natively (HLS, MP4…), VLC for
/// everything IPTV-specific (MPEG-TS, MKV, RTMP/RTSP/UDP, extension-less Xtream live URLs).
nonisolated public enum EngineSelector {
    /// Containers AVFoundation plays natively.
    static let avFoundationContainers: Set<String> = [
        "m3u8", "hls", "mp4", "m4v", "mov", "mp3", "m4a", "aac", "caf", "wav", "aif", "aiff",
    ]
    /// Containers that need libvlc.
    static let vlcContainers: Set<String> = [
        "ts", "m2ts", "mts", "mkv", "avi", "flv", "wmv", "asf", "webm", "mpd", "mpg", "mpeg",
        "vob", "ogv", "ogg", "3gp", "divx", "xvid", "rm", "rmvb", "f4v", "dash",
    ]
    /// Transport schemes only VLC understands.
    static let vlcSchemes: Set<String> = [
        "rtmp", "rtmps", "rtmpe", "rtmpt", "rtsp", "rtsps", "udp", "rtp", "mms", "mmsh", "mmst",
        "srt", "igmp",
    ]
    /// Query parameters used by IPTV panels to choose the container (`output=ts`, `extension=m3u8`).
    static let containerQueryKeys: Set<String> = ["extension", "output", "container", "format", "ext"]

    /// Engine for an item: explicit preference first, else automatic resolution.
    public static func engine(for item: PlaybackItem) -> PlaybackEngineKind {
        if item.preferredEngine != .auto { return item.preferredEngine }
        return engine(for: item.url, containerHint: item.containerHint)
    }

    /// Automatic resolution for one URL (never returns `.auto`).
    public static func engine(for url: URL, containerHint: String? = nil) -> PlaybackEngineKind {
        let scheme = url.scheme?.lowercased() ?? ""
        if vlcSchemes.contains(scheme) { return .vlc }
        if !scheme.isEmpty, !["http", "https", "file"].contains(scheme) { return .vlc }

        if let container = normalizedContainer(containerHint) {
            if avFoundationContainers.contains(container) { return .avFoundation }
            if vlcContainers.contains(container) { return .vlc }
        }

        let ext = url.pathExtension.lowercased()
        if avFoundationContainers.contains(ext) { return .avFoundation }
        if vlcContainers.contains(ext) { return .vlc }

        if let queryContainer = queryContainer(of: url) {
            if avFoundationContainers.contains(queryContainer) { return .avFoundation }
            if vlcContainers.contains(queryContainer) { return .vlc }
        }

        if ext.isEmpty, looksLikeXtreamStream(url) { return .vlc }
        return .avFoundation
    }

    /// Ordered, de-duplicated list of attempts: primary URL with the chosen engine, primary
    /// URL with the other engine, then each fallback URL with its own automatic engine.
    /// - Parameter defaultEngine: user override (Réglages) applied when the item is `.auto`.
    public static func attemptPlan(
        for item: PlaybackItem, defaultEngine: PlaybackEngineKind = .auto
    ) -> [PlaybackAttempt] {
        let primary: PlaybackEngineKind =
            if item.preferredEngine != .auto {
                item.preferredEngine
            } else if defaultEngine != .auto {
                defaultEngine
            } else {
                engine(for: item.url, containerHint: item.containerHint)
            }
        var plan: [PlaybackAttempt] = []
        var seen: Set<PlaybackAttempt> = []
        func append(_ attempt: PlaybackAttempt) {
            if seen.insert(attempt).inserted { plan.append(attempt) }
        }
        append(PlaybackAttempt(url: item.url, engine: primary))
        append(PlaybackAttempt(url: item.url, engine: primary.alternate))
        for url in item.fallbackURLs {
            append(PlaybackAttempt(url: url, engine: engine(for: url)))
        }
        return plan
    }

    // MARK: - Helpers

    /// "application/x-mpegURL" → "m3u8", ".TS" → "ts", "video/x-matroska" → "mkv"…
    static func normalizedContainer(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !value.isEmpty
        else { return nil }
        if value.hasPrefix(".") { value.removeFirst() }
        switch value {
        case "application/x-mpegurl", "application/vnd.apple.mpegurl", "audio/mpegurl",
            "audio/x-mpegurl", "mpegurl", "hls":
            return "m3u8"
        case "video/mp2t", "mpegts", "mpeg-ts", "mp2t": return "ts"
        case "video/mp4", "mpeg4": return "mp4"
        case "video/quicktime": return "mov"
        case "video/x-matroska", "matroska": return "mkv"
        case "video/x-msvideo": return "avi"
        case "video/x-flv": return "flv"
        case "video/webm": return "webm"
        case "application/dash+xml": return "mpd"
        case "audio/mpeg": return "mp3"
        case "audio/aac", "audio/aacp": return "aac"
        default:
            return value
        }
    }

    static func queryContainer(of url: URL) -> String? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        for item in items where containerQueryKeys.contains(item.name.lowercased()) {
            if let value = normalizedContainer(item.value) { return value }
        }
        return nil
    }

    /// `/live/user/pass/123`, `/user/pass/123`, `/movie/u/p/456` without extension.
    static func looksLikeXtreamStream(_ url: URL) -> Bool {
        let components = url.pathComponents.filter { $0 != "/" }
        guard let last = components.last, !last.isEmpty,
            last.allSatisfy(\.isNumber)
        else { return false }
        // `[live|movie|series/]user/pass/id` — at least user, password and numeric id.
        return components.count >= 3
    }
}

nonisolated extension PlaybackEngineKind {
    /// The other concrete engine (`.auto` maps to VLC as the "other" of AVFoundation).
    public var alternate: PlaybackEngineKind {
        switch self {
        case .avFoundation, .auto: .vlc
        case .vlc: .avFoundation
        }
    }
}
