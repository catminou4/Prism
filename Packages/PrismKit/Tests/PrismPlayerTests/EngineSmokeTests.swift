import AppKit
import Foundation
import Testing

@testable import PrismPlayer

/// Real engines against a missing local file: no network, no audio. Exercises the KVO /
/// libvlc delegate → main-actor bridges and teardown.
@Suite(.serialized) struct EngineSmokeTests {
    static func collectEvents(
        _ engine: any PlaybackEngine, url: URL, timeout: Duration, until done: @escaping ([EngineEvent]) -> Bool
    ) async -> [EngineEvent] {
        var events: [EngineEvent] = []
        engine.eventHandler = { events.append($0) }
        engine.isMuted = true
        engine.volume = 0
        engine.load(url: url, headers: ["User-Agent": "PrismTests"], startPosition: nil, isLive: false)
        engine.play()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline, !done(events) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        engine.stop()
        return events
    }

    static let missingFile = URL(fileURLWithPath: "/tmp/prism-player-tests-\(UUID().uuidString).mp4")

    @Test func avFoundationReportsFailure() async {
        let engine = AVFoundationEngine(configuration: EngineConfiguration())
        #expect(engine.videoView.layer != nil)
        let events = await Self.collectEvents(engine, url: Self.missingFile, timeout: .seconds(5)) { events in
            events.contains { if case .failed = $0 { true } else { false } }
        }
        #expect(events.contains { if case .failed = $0 { true } else { false } })
        #expect(engine.techInfo.engineName == "AVFoundation")
    }

    @Test func vlcReportsFailureOrEnd() async {
        let engine = VLCEngine(configuration: EngineConfiguration(networkCachingMilliseconds: 300))
        let url = Self.missingFile.deletingPathExtension().appendingPathExtension("ts")
        let events = await Self.collectEvents(engine, url: url, timeout: .seconds(8)) { events in
            events.contains {
                switch $0 {
                case .failed, .ended: true
                default: false
                }
            }
        }
        #expect(
            events.contains {
                switch $0 {
                case .failed, .ended: true
                default: false
                }
            })
        #expect(engine.techInfo.engineName == "VLC")
        #expect(engine.audioTracks.isEmpty)
        // Geometry strings are copied by libvlc: setting them repeatedly must be safe.
        engine.videoGravity = .fill
        engine.aspectRatio = .ratio4x3
        engine.videoGravity = .stretch
        engine.videoGravity = .fit
    }
}
