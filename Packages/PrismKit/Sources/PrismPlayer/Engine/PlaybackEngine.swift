import AVFoundation
import AppKit
import Foundation

/// A decoding engine (AVFoundation or libvlc) driving one stream into an `NSView`.
///
/// Engines are main-actor objects; they report everything through `eventHandler`.
/// One engine instance plays one attempt: the controller creates a fresh engine for each
/// fallback/reconnect/zap so the previous one can keep its last frame on screen meanwhile.
public protocol PlaybackEngine: AnyObject {
    var kind: PlaybackEngineKind { get }
    /// Layer-backed, black view rendering the picture.
    var videoView: NSView { get }
    /// Called on the main actor for every engine event.
    var eventHandler: ((EngineEvent) -> Void)? { get set }

    func load(url: URL, headers: [String: String], startPosition: TimeInterval?, isLive: Bool)
    func play()
    func pause()
    func seek(to seconds: TimeInterval) async
    func stop()

    var rate: Float { get set }
    /// 0…1.
    var volume: Float { get set }
    var isMuted: Bool { get set }

    var audioTracks: [MediaTrack] { get }
    var subtitleTracks: [MediaTrack] { get }
    var selectedAudioID: MediaTrack.ID? { get }
    var selectedSubtitleID: MediaTrack.ID? { get }
    func select(audio id: MediaTrack.ID?)
    func select(subtitle id: MediaTrack.ID?)
    var subtitleStyle: SubtitleStyle { get set }

    var videoGravity: VideoGravity { get set }
    var aspectRatio: VideoAspectRatio { get set }
    var supportsAspectRatioOverride: Bool { get }

    /// Seekable window for live streams with DVR (seconds, engine timeline), nil otherwise.
    var seekableRange: ClosedRange<TimeInterval>? { get }
    var techInfo: StreamTechSnapshot { get }

    var supportsPictureInPicture: Bool { get }
    var isPictureInPictureActive: Bool { get }
    func togglePictureInPicture()

    /// AVPlayer used for AirPlay routing (nil for VLC).
    var routingPlayer: AVPlayer? { get }
}

/// Creates engines; injectable for tests.
public typealias PlaybackEngineFactory = (PlaybackEngineKind, EngineConfiguration) -> any PlaybackEngine

enum DefaultEngineFactory {
    static func make(_ kind: PlaybackEngineKind, _ configuration: EngineConfiguration) -> any PlaybackEngine {
        switch kind {
        case .vlc: VLCEngine(configuration: configuration)
        case .avFoundation, .auto: AVFoundationEngine(configuration: configuration)
        }
    }
}

/// Runs `body` on the main actor: synchronously when already on the main thread, otherwise
/// asynchronously. Used to bridge KVO / Objective-C delegate callbacks safely.
nonisolated func onMainActor(_ body: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
    }
}

/// Layer-backed black view used as the drawing surface of the engines.
class BlackVideoSurfaceView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// Mouse events go to the SwiftUI overlay.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
