import CoreGraphics
import Foundation

/// An audio or subtitle track exposed by an engine.
nonisolated public struct MediaTrack: Identifiable, Hashable, Sendable {
    /// Engine-specific stable identifier (AVFoundation option index, VLC track index…).
    public var id: String
    /// Localized display name, e.g. "Français", "English (SDH)".
    public var name: String
    /// Normalized language code when known (`fr`, `en`…).
    public var language: String?
    /// Forced subtitles (only foreign dialogue) — never auto-selected as "full" subtitles.
    public var isForced: Bool
    /// SDH / closed captions / audio description.
    public var isAccessibility: Bool

    public init(
        id: String, name: String, language: String? = nil, isForced: Bool = false,
        isAccessibility: Bool = false
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.isForced = isForced
        self.isAccessibility = isAccessibility
    }
}

/// How the picture fits the view.
nonisolated public enum VideoGravity: String, CaseIterable, Sendable, Hashable, Codable {
    /// Letterbox / pillarbox (aspect fit).
    case fit
    /// Crop to fill (aspect fill).
    case fill
    /// Stretch to the view (ignores the aspect ratio).
    case stretch

    /// French menu label.
    public var label: String {
        switch self {
        case .fit: "Ajuster"
        case .fill: "Remplir"
        case .stretch: "Étirer"
        }
    }

    public var next: VideoGravity {
        switch self {
        case .fit: .fill
        case .fill: .stretch
        case .stretch: .fit
        }
    }
}

/// Forced display aspect ratio (VLC only — IPTV streams often carry wrong SAR flags).
nonisolated public enum VideoAspectRatio: String, CaseIterable, Sendable, Hashable, Codable {
    case automatic
    case ratio16x9
    case ratio4x3
    case ratio16x10
    case ratio21x9
    case ratio235x1
    case ratio185x1

    public var label: String {
        switch self {
        case .automatic: "Automatique"
        case .ratio16x9: "16:9"
        case .ratio4x3: "4:3"
        case .ratio16x10: "16:10"
        case .ratio21x9: "21:9"
        case .ratio235x1: "2,35:1"
        case .ratio185x1: "1,85:1"
        }
    }

    /// Value understood by libvlc (`--aspect-ratio`), nil = source aspect ratio.
    public var vlcValue: String? {
        switch self {
        case .automatic: nil
        case .ratio16x9: "16:9"
        case .ratio4x3: "4:3"
        case .ratio16x10: "16:10"
        case .ratio21x9: "21:9"
        case .ratio235x1: "235:100"
        case .ratio185x1: "185:100"
        }
    }
}

/// Subtitle rendering style (applied through `AVTextStyleRule` on AVFoundation).
nonisolated public enum SubtitleStyle: String, CaseIterable, Sendable, Hashable, Codable {
    /// System caption appearance (Réglages Système › Accessibilité › Sous-titres).
    case system
    case large
    case background
    case yellow

    public var label: String {
        switch self {
        case .system: "Par défaut"
        case .large: "Grand texte"
        case .background: "Fond opaque"
        case .yellow: "Jaune"
        }
    }
}

/// Playback state reported by an engine.
nonisolated public enum EnginePlaybackState: Sendable, Hashable {
    case playing
    case paused
    case buffering
}

/// Events emitted by an engine on the main actor.
nonisolated public enum EngineEvent: Sendable, Equatable {
    /// The media is ready; `duration` is nil for live/unknown.
    case ready(duration: TimeInterval?)
    /// Periodic time update (≈ 4 Hz).
    case time(current: TimeInterval, buffered: TimeInterval)
    case state(EnginePlaybackState)
    /// The first video frame was rendered (or the audio-only stream started).
    case firstFrame
    case ended
    case failed(String)
    case tracksChanged
    case videoSize(CGSize)
    case pictureInPicture(active: Bool)
}

/// Technical information about the current stream (the `I` overlay).
nonisolated public struct StreamTechSnapshot: Sendable, Equatable {
    public var engineName: String
    public var videoCodec: String?
    public var audioCodec: String?
    public var resolution: CGSize?
    public var framesPerSecond: Double?
    /// Bits per second announced by the stream (HLS variant `BANDWIDTH`, VLC demux bitrate).
    public var indicatedBitrate: Double?
    /// Bits per second actually measured on the network.
    public var observedBitrate: Double?
    public var droppedFrames: Int?
    public var url: URL?

    public init(
        engineName: String = "—", videoCodec: String? = nil, audioCodec: String? = nil,
        resolution: CGSize? = nil, framesPerSecond: Double? = nil, indicatedBitrate: Double? = nil,
        observedBitrate: Double? = nil, droppedFrames: Int? = nil, url: URL? = nil
    ) {
        self.engineName = engineName
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.resolution = resolution
        self.framesPerSecond = framesPerSecond
        self.indicatedBitrate = indicatedBitrate
        self.observedBitrate = observedBitrate
        self.droppedFrames = droppedFrames
        self.url = url
    }

    public static let empty = StreamTechSnapshot()

    /// Label/value rows for display, French labels, "—" when unknown.
    public var rows: [(label: String, value: String)] {
        var rows: [(String, String)] = [("Moteur", engineName)]
        rows.append(("Vidéo", videoCodec ?? "—"))
        rows.append(("Audio", audioCodec ?? "—"))
        rows.append(("Résolution", resolution.map(PlayerFormat.resolution) ?? "—"))
        rows.append(("Images/s", framesPerSecond.map(PlayerFormat.frameRate) ?? "—"))
        rows.append(("Débit annoncé", indicatedBitrate.map(PlayerFormat.bitrate) ?? "—"))
        rows.append(("Débit mesuré", observedBitrate.map(PlayerFormat.bitrate) ?? "—"))
        rows.append(("Images perdues", droppedFrames.map(String.init) ?? "—"))
        rows.append(("Serveur", url?.host() ?? "—"))
        return rows
    }
}

/// Static configuration handed to engines when they are created.
nonisolated public struct EngineConfiguration: Sendable, Hashable {
    /// libvlc `network-caching` for VOD (ms). Live streams add one second.
    public var networkCachingMilliseconds: Int
    public var subtitleStyle: SubtitleStyle

    public init(networkCachingMilliseconds: Int = 1500, subtitleStyle: SubtitleStyle = .system) {
        self.networkCachingMilliseconds = networkCachingMilliseconds
        self.subtitleStyle = subtitleStyle
    }
}

/// Programme currently airing on a live channel (for the scrubber and the top title).
nonisolated public struct LiveProgramme: Hashable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date

    public init(title: String, start: Date, end: Date) {
        self.title = title
        self.start = start
        self.end = end
    }

    /// 0…1 progress of the programme at `date`.
    public func progress(at date: Date = .now) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / total))
    }
}
