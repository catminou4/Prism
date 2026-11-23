import AppKit
import Foundation
import Observation
import SwiftUI

/// A short-lived, muted playback session that never writes progress or player preferences.
@Observable
public final class HeroPreviewPlayer {
    public private(set) var isReady = false
    public private(set) var isMuted = true
    let surface = BlackVideoSurfaceView(frame: .zero)
    private let item: PlaybackItem
    private let factory: PlaybackEngineFactory
    private let timeout: Duration
    private let duration: Duration
    private var engine: (any PlaybackEngine)?
    private var timer: Task<Void, Never>?
    private var attempt = 0
    private var engineGeneration = 0
    private var isStopped = true
    private var initialTime: TimeInterval?
    public var onFinished: (() -> Void)?

    public convenience init(item: PlaybackItem) {
        self.init(item: item, factory: DefaultEngineFactory.make, timeout: .seconds(8), duration: .seconds(15))
    }

    init(item: PlaybackItem, factory: @escaping PlaybackEngineFactory, timeout: Duration, duration: Duration) {
        self.item = item
        self.factory = factory
        self.timeout = timeout
        self.duration = duration
    }

    isolated deinit {
        timer?.cancel()
        engine?.stop()
    }

    public func start() {
        guard isStopped else { return }
        isStopped = false
        attempt = 0
        startAttempt()
    }

    public func stop() {
        isStopped = true
        engineGeneration += 1
        timer?.cancel()
        initialTime = nil
        timer = nil
        engine?.eventHandler = nil
        engine?.stop()
        engine?.videoView.removeFromSuperview()
        engine = nil
        isReady = false
    }

    public func toggleMute() {
        isMuted.toggle()
        engine?.isMuted = isMuted
        engine?.volume = isMuted ? 0 : 1
    }

    private func startAttempt() {
        guard !isStopped else { return }
        timer?.cancel()
        initialTime = nil
        engine?.eventHandler = nil
        engine?.stop()
        engine?.videoView.removeFromSuperview()
        let preferred = EngineSelector.engine(for: item)
        let kind: PlaybackEngineKind = attempt == 0 ? preferred : (preferred == .vlc ? .avFoundation : .vlc)
        let next = factory(kind, EngineConfiguration())
        next.volume = isMuted ? 0 : 1
        next.isMuted = isMuted
        next.videoGravity = .fill
        engineGeneration += 1
        let generation = engineGeneration
        next.eventHandler = { [weak self] event in
            guard let self, self.engineGeneration == generation else { return }
            self.handle(event)
        }
        next.videoView.frame = surface.bounds
        next.videoView.autoresizingMask = [.width, .height]
        surface.addSubview(next.videoView)
        engine = next
        schedule(timeout) { [weak self] in self?.failedAttempt() }
        next.load(url: item.url, headers: item.httpHeaders, startPosition: item.startPosition, isLive: false)
        guard !isStopped, engineGeneration == generation else { return }
        next.play()
    }

    private func handle(_ event: EngineEvent) {
        guard !isStopped else { return }
        switch event {
        case .firstFrame:
            showFirstFrame()
        case .time(let current, _):
            // A hidden AVPlayerLayer may not report a frame until made visible.
            if !isReady {
                if let initialTime, current - initialTime >= 1 { showFirstFrame() }
                else if initialTime == nil { initialTime = current }
            }
        case .tracksChanged:
            engine?.select(subtitle: nil)
        case .failed:
            failedAttempt()
        case .ended:
            finish()
        default:
            break
        }
    }

    private func showFirstFrame() {
        guard !isReady else { return }
        isReady = true
        schedule(duration) { [weak self] in self?.finish() }
    }

    private func failedAttempt() {
        guard !isStopped else { return }
        if !isReady && attempt == 0 {
            attempt = 1
            startAttempt()
        } else {
            finish()
        }
    }

    private func finish() {
        guard !isStopped else { return }
        stop()
        onFinished?()
    }

    private func schedule(_ delay: Duration, action: @escaping @MainActor () -> Void) {
        timer?.cancel()
        timer = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }
}

/// Displays the video only after the first frame, leaving the artwork visible while it loads.
public struct HeroPreviewPlayerView: View {
    public let player: HeroPreviewPlayer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(player: HeroPreviewPlayer) { self.player = player }

    public var body: some View {
        HeroPreviewSurface(player: player)
            .opacity(player.isReady ? 1 : 0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: player.isReady)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct HeroPreviewSurface: NSViewRepresentable {
    let player: HeroPreviewPlayer

    func makeNSView(context: Context) -> NSView {
        let host = PreviewHost()
        attach(player.surface, to: host)
        return host
    }

    func updateNSView(_ host: NSView, context: Context) { attach(player.surface, to: host) }

    static func dismantleNSView(_ host: NSView, coordinator: ()) {
        host.subviews.forEach { $0.removeFromSuperview() }
    }

    private func attach(_ surface: NSView, to host: NSView) {
        guard surface.superview !== host else { return }
        surface.removeFromSuperview()
        surface.frame = host.bounds
        surface.autoresizingMask = [.width, .height]
        host.addSubview(surface)
    }
}

private final class PreviewHost: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
