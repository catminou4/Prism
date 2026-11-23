import AVFoundation
import AppKit
import Foundation
import Observation
import Testing

@testable import PrismPlayer

/// Temporary audit probes (player performance review). Not part of the suite's contract.
@Suite(.serialized, .disabled(if: ProcessInfo.processInfo.environment["ZZAUDIT"] == nil))
struct ZZAuditPlayerPerfTests {
    let defaults: UserDefaults
    let suiteName: String
    let preferences: PlayerPreferences

    init() throws {
        suiteName = "prism.player.audit-tests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        preferences = PlayerPreferences(defaults: defaults)
    }

    func makeController(
        _ item: PlaybackItem, factory: MockFactory
    ) -> PlayerController {
        PlayerController(
            item: item, preferences: preferences, engineFactory: factory.make,
            loadTimeout: .seconds(30), reconnectPolicy: .standard,
            uptime: { ProcessInfo.processInfo.systemUptime })
    }

    /// Counts `withObservationTracking` onChange fires per property while `body` runs once
    /// to (re)arm tracking. Mirrors what SwiftUI does for a view reading that property.
    private final class PropCounter: @unchecked Sendable {
        var counts: [String: Int] = [:]
        private var trackers: [String: () -> Void] = [:]

        func track<Controller: AnyObject & Sendable>(_ name: String, _ controller: Controller, _ read: @escaping @MainActor (Controller) -> Void) {
            arm(name, controller, read)
        }

        private func arm<Controller: AnyObject & Sendable>(_ name: String, _ controller: Controller, _ read: @escaping @MainActor (Controller) -> Void) {
            withObservationTracking {
                MainActor.assumeIsolated { read(controller) }
            } onChange: { [weak self, weak controller] in
                MainActor.assumeIsolated {
                    guard let self, let controller else { return }
                    self.counts[name, default: 0] += 1
                    self.arm(name, controller, read)
                }
            }
        }

        func reset() { counts.removeAll() }
        func report() -> [String: Int] { counts.filter { $0.value > 0 } }
    }

    /// Wall-time of one synchronous `.time` event through the controller (4 Hz stream).
    @Test func timeEventCostVOD() {
        let factory = MockFactory()
        let controller = makeController(Self.vod, factory: factory)
        controller.start()
        let engine = factory.last!
        engine.start(duration: 3600)

        // Warm up.
        for i in 0..<10 { engine.emit(.time(current: Double(i) * 0.25, buffered: 120)) }

        let n = 400
        let t0 = ContinuousClock.now
        for i in 0..<n {
            engine.emit(.time(current: 10 + Double(i) * 0.25, buffered: 120 + Double(i) * 0.25))
        }
        let elapsed = ContinuousClock.now - t0
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("ZZAUDIT timeEventCostVOD: \(n) events in \(seconds)s → \(seconds / Double(n) * 1_000_000) µs/event")
        controller.stop()
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Which @Observable properties actually get written per `.time` event (VOD).
    @Test func observableFanOutVOD() {
        let factory = MockFactory()
        let controller = makeController(Self.vod, factory: factory)
        controller.start()
        let engine = factory.last!
        engine.start(duration: 3600)

        let counter = PropCounter()
        counter.track("currentTime", controller) { $0.currentTime }
        counter.track("bufferedTime", controller) { $0.bufferedTime }
        counter.track("duration", controller) { $0.duration }
        counter.track("timeshiftWindow", controller) { $0.timeshiftWindow }
        counter.track("phase", controller) { $0.phase }
        counter.track("controlsVisible", controller) { $0.controlsVisible }
        counter.track("isSwitchingStream", controller) { $0.isSwitchingStream }
        counter.track("statusMessage", controller) { $0.statusMessage }
        counter.track("techInfo", controller) { $0.techInfo }
        counter.track("videoSize", controller) { $0.videoSize }
        counter.track("feedback", controller) { $0.feedback }
        counter.track("liveProgramme", controller) { $0.liveProgramme }
        counter.track("audioTracks", controller) { $0.audioTracks }
        counter.track("subtitleTracks", controller) { $0.subtitleTracks }
        counter.track("upNextVisible", controller) { $0.upNextVisible }
        counter.track("selectedAudioID", controller) { $0.selectedAudioID }
        counter.track("selectedSubtitleID", controller) { $0.selectedSubtitleID }
        counter.track("rate", controller) { $0.rate }
        counter.track("volume", controller) { $0.volume }
        counter.track("isMuted", controller) { $0.isMuted }
        counter.track("playRequested", controller) { $0.playRequested }
        counter.track("isPictureInPictureActive", controller) { $0.isPictureInPictureActive }
        counter.track("isPictureInPictureSupported", controller) { $0.isPictureInPictureSupported }
        counter.track("supportsAspectRatioOverride", controller) { $0.supportsAspectRatioOverride }
        counter.track("engineKind", controller) { $0.engineKind }
        counter.track("currentAttempt", controller) { $0.currentAttempt }
        counter.track("videoGravity", controller) { $0.videoGravity }
        counter.track("aspectRatio", controller) { $0.aspectRatio }
        counter.track("item", controller) { $0.item }

        counter.reset()
        let n = 100
        for i in 0..<n {
            // VLC-like: buffered == current (advances every tick).
            engine.emit(.time(current: 100 + Double(i) * 0.25, buffered: 100 + Double(i) * 0.25))
        }
        print("ZZAUDIT observableFanOutVOD (buffered==current): \(counter.report())")

        counter.reset()
        for i in 0..<n {
            // AVF-like: buffered jumps occasionally.
            engine.emit(.time(current: 200 + Double(i) * 0.25, buffered: 400))
        }
        print("ZZAUDIT observableFanOutVOD (buffered steady): \(counter.report())")
        controller.stop()
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Live DVR: how often does `timeshiftWindow` (read by PlayerView.body via `canSeek`)
    /// get written as the engine's seekable range slides forward?
    @Test func liveTimeshiftWindowChurn() {
        let factory = MockFactory()
        let controller = makeController(Self.live, factory: factory)
        controller.start()
        let engine = factory.last!
        engine.start(duration: nil)

        let counter = PropCounter()
        counter.track("timeshiftWindow", controller) { $0.timeshiftWindow }
        counter.track("currentTime", controller) { $0.currentTime }
        counter.track("bufferedTime", controller) { $0.bufferedTime }

        // Simulate HLS EVENT playlist: window slides ~every 4 s (16 ticks at 4 Hz).
        counter.reset()
        var windowStart: TimeInterval = 0
        for i in 0..<400 {
            if i % 16 == 0 { windowStart += 4 }
            engine.seekableRange = windowStart...(windowStart + 300)
            engine.emit(.time(current: Double(i) * 0.25, buffered: Double(i) * 0.25))
        }
        print("ZZAUDIT liveTimeshiftWindowChurn (window slides 4s): \(counter.report())")

        // VLC live: length grows ~continuously.
        counter.reset()
        for i in 0..<400 {
            engine.seekableRange = 0...(300 + Double(i) * 0.25)
            engine.emit(.time(current: Double(i) * 0.25, buffered: Double(i) * 0.25))
        }
        print("ZZAUDIT liveTimeshiftWindowChurn (window end grows): \(counter.report())")
        controller.stop()
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Real AVFoundationEngine on a generated file: actual `.time` event cadence while
    /// playing vs paused (does the 4 Hz periodic observer keep firing when paused?).
    @Test func avfTimeEventCadence() async throws {
        let url = try await AVFoundationIntegrationTests.makeMovie(seconds: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = AVFoundationEngine(configuration: EngineConfiguration())
        var events: [EngineEvent] = []
        engine.eventHandler = { events.append($0) }
        engine.isMuted = true
        engine.volume = 0
        engine.load(url: url, headers: [:], startPosition: nil, isLive: false)
        engine.play()
        // Wait for first frame-ish (ready + some time events).
        try await Task.sleep(for: .seconds(1.5))
        let playingCount = events.filter { if case .time = $0 { true } else { false } }.count
        print("ZZAUDIT avfTimeEventCadence: \(playingCount) .time events in ~1.5s playing")

        engine.pause()
        let pausedStart = events.count
        try await Task.sleep(for: .seconds(2))
        let pausedCount = events[pausedStart...].filter { if case .time = $0 { true } else { false } }.count
        print("ZZAUDIT avfTimeEventCadence: \(pausedCount) .time events in 2s PAUSED")
        engine.stop()
    }

    /// VLC emits `.ready` twice (duration arrives late): the second one must not
    /// republish identical track arrays / selection ids.
    @Test func duplicateReadyDoesNotRepublishTracks() {
        let factory = MockFactory()
        let controller = makeController(Self.vod, factory: factory)
        controller.start()
        let engine = factory.last!
        engine.audioTracks = [MediaTrack(id: "1", name: "French", language: "fr")]
        engine.subtitleTracks = [MediaTrack(id: "2", name: "English", language: "en")]

        let counter = PropCounter()
        counter.track("audioTracks", controller) { $0.audioTracks }
        counter.track("subtitleTracks", controller) { $0.subtitleTracks }
        counter.track("selectedAudioID", controller) { $0.selectedAudioID }
        counter.track("selectedSubtitleID", controller) { $0.selectedSubtitleID }

        engine.emit(.ready(duration: 600))
        counter.reset()
        engine.emit(.ready(duration: 600))  // late-duration duplicate
        let report = counter.report()
        print("ZZAUDIT duplicateReadyDoesNotRepublishTracks: \(report)")
        #expect(report.isEmpty)
        controller.stop()
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Scrubbing: engine time events must not write currentTime.
    @Test func scrubFreeze() {
        let factory = MockFactory()
        let controller = makeController(Self.vod, factory: factory)
        controller.start()
        let engine = factory.last!
        engine.start(duration: 3600)
        controller.setScrubbing(true)
        engine.emit(.time(current: 50, buffered: 200))
        #expect(controller.currentTime != 50)
        controller.setScrubbing(false)
        engine.emit(.time(current: 50.25, buffered: 200))
        #expect(controller.currentTime == 50.25)
        controller.stop()
        defaults.removePersistentDomain(forName: suiteName)
    }

    static let vod = PlaybackItem(
        id: "vod", url: URL(string: "http://h/movie/u/p/1.mkv")!,
        fallbackURLs: [URL(string: "http://backup/1.mp4")!], title: "Film")
    static let live = PlaybackItem(
        id: "live", url: URL(string: "http://h/live/u/p/9.ts")!, title: "Chaîne", isLive: true)
}
