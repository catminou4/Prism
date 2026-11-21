import AVFoundation
import AppKit
import Foundation
import Testing

@testable import PrismPlayer

/// Scriptable engine: records calls, events are emitted by the test.
final class MockEngine: PlaybackEngine {
    let kind: PlaybackEngineKind
    let videoView: NSView = NSView(frame: .zero)
    var eventHandler: ((EngineEvent) -> Void)?
    private(set) var loadedURL: URL?
    private(set) var loadedStart: TimeInterval?
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var isStopped = false
    private(set) var seeks: [TimeInterval] = []
    var rate: Float = 1
    var volume: Float = 1
    var isMuted = false
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    private(set) var selectedAudioID: MediaTrack.ID?
    private(set) var selectedSubtitleID: MediaTrack.ID?
    var subtitleStyle: SubtitleStyle = .system
    var videoGravity: VideoGravity = .fit
    var aspectRatio: VideoAspectRatio = .automatic
    var supportsAspectRatioOverride: Bool { kind == .vlc }
    var seekableRange: ClosedRange<TimeInterval>?
    var techInfo: StreamTechSnapshot { StreamTechSnapshot(engineName: kind.displayName) }
    var supportsPictureInPicture: Bool { kind == .avFoundation }
    var isPictureInPictureActive: Bool { false }
    var routingPlayer: AVPlayer? { nil }

    init(kind: PlaybackEngineKind) { self.kind = kind }

    func load(url: URL, headers: [String: String], startPosition: TimeInterval?, isLive: Bool) {
        loadedURL = url
        loadedStart = startPosition
    }
    func play() { playCount += 1 }
    func pause() { pauseCount += 1 }
    func seek(to seconds: TimeInterval) async { seeks.append(seconds) }
    func stop() {
        isStopped = true
        eventHandler = nil
    }
    func select(audio id: MediaTrack.ID?) { selectedAudioID = id }
    func select(subtitle id: MediaTrack.ID?) { selectedSubtitleID = id }
    func togglePictureInPicture() {}

    func emit(_ event: EngineEvent) { eventHandler?(event) }

    /// ready + playing + first frame.
    func start(duration: TimeInterval? = 600) {
        emit(.ready(duration: duration))
        emit(.state(.playing))
        emit(.firstFrame)
    }
}

final class MockFactory {
    private(set) var engines: [MockEngine] = []
    var onCreate: ((MockEngine) -> Void)?

    func make(_ kind: PlaybackEngineKind, _ configuration: EngineConfiguration) -> any PlaybackEngine {
        let engine = MockEngine(kind: kind)
        engines.append(engine)
        onCreate?(engine)
        return engine
    }

    var last: MockEngine? { engines.last }
}

@Suite(.serialized) struct PlayerControllerTests {
    let defaults: UserDefaults
    let suiteName: String
    let preferences: PlayerPreferences

    init() throws {
        suiteName = "prism.player.controller-tests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        preferences = PlayerPreferences(defaults: defaults)
    }

    func makeController(
        _ item: PlaybackItem, factory: MockFactory, timeout: Duration = .seconds(30),
        policy: ReconnectPolicy = ReconnectPolicy(delays: [0.01, 0.02], maxAttempts: 3, stallThreshold: 0.05)
    ) -> PlayerController {
        PlayerController(
            item: item, preferences: preferences, engineFactory: factory.make, loadTimeout: timeout,
            reconnectPolicy: policy, uptime: { ProcessInfo.processInfo.systemUptime })
    }

    static let vod = PlaybackItem(
        id: "vod", url: URL(string: "http://h/movie/u/p/1.mkv")!,
        fallbackURLs: [URL(string: "http://backup/1.mp4")!], title: "Film")
    static let live = PlaybackItem(
        id: "live", url: URL(string: "http://h/live/u/p/9.ts")!, title: "Chaîne", isLive: true)

    @Test func startsWithFirstAttemptAndPlays() {
        let factory = MockFactory()
        let controller = makeController(Self.vod, factory: factory)
        controller.start()
        #expect(controller.phase == .loading)
        #expect(factory.engines.count == 1)
        #expect(factory.last?.kind == .vlc)
        #expect(factory.last?.loadedURL == Self.vod.url)
        #expect(factory.last?.playCount == 1)
        factory.last?.start(duration: 600)
        #expect(controller.phase == .playing)
        #expect(controller.duration == 600)
        #expect(controller.engineKind == .vlc)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func fallsBackThroughThePlanThenFails() {
        let factory = MockFactory()
        let controller = makeController(Self.vod, factory: factory)
        var failure: String?
        controller.onFailed = { failure = $0 }
        controller.start()
        factory.last?.emit(.failed("vlc primary"))
        #expect(factory.engines.count == 2)
        #expect(factory.last?.kind == .avFoundation)
        #expect(factory.last?.loadedURL == Self.vod.url)
        #expect(factory.engines[0].isStopped)
        factory.last?.emit(.failed("av primary"))
        #expect(factory.engines.count == 3)
        #expect(factory.last?.loadedURL == Self.vod.fallbackURLs[0])
        #expect(factory.last?.kind == .avFoundation)
        #expect(failure == nil)
        factory.last?.emit(.failed("Le serveur a refusé la connexion."))
        #expect(controller.phase == .failed("Le serveur a refusé la connexion."))
        #expect(failure == "Le serveur a refusé la connexion.")
        #expect(factory.engines.allSatisfy { $0.isStopped })
        #expect(controller.controlsVisible)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func loadTimeoutMovesToNextAttempt() async throws {
        let factory = MockFactory()
        let controller = makeController(Self.vod, factory: factory, timeout: .milliseconds(100))
        controller.start()
        try await Task.sleep(for: .milliseconds(150))
        #expect(factory.engines.count == 2)
        #expect(factory.engines[1].kind == .avFoundation)
        // Rendering cancels the timeout.
        factory.last?.start()
        let count = factory.engines.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(factory.engines.count == count)
        #expect(controller.phase == .playing)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func retryRestartsThePlan() {
        let factory = MockFactory()
        let controller = makeController(Self.live, factory: factory)
        controller.start()
        factory.last?.emit(.failed("a"))
        factory.last?.emit(.failed("b"))
        #expect(controller.phase == .failed("b"))
        controller.retry()
        #expect(controller.phase == .loading)
        #expect(factory.last?.kind == .vlc)
        #expect(factory.last?.loadedURL == Self.live.url)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func liveReconnectsOnUnexpectedEndWithBackoffThenGivesUp() async throws {
        let factory = MockFactory()
        let controller = makeController(Self.live, factory: factory)
        controller.start()
        factory.last?.start(duration: nil)
        #expect(controller.duration == nil)
        factory.last?.emit(.ended)
        #expect(controller.statusMessage == "Reconnexion…")
        try await Task.sleep(for: .milliseconds(60))
        #expect(factory.engines.count == 2)
        #expect(factory.last?.loadedURL == Self.live.url)
        // The rendered engine keeps its frame until the new one renders.
        #expect(!factory.engines[0].isStopped)
        #expect(controller.isSwitchingStream)
        factory.last?.emit(.failed("x"))
        try await Task.sleep(for: .milliseconds(80))
        #expect(factory.engines.count == 3)
        factory.last?.emit(.failed("y"))
        try await Task.sleep(for: .milliseconds(80))
        #expect(factory.engines.count == 4)
        factory.last?.emit(.failed("z"))
        #expect(controller.phase == .failed("z"))
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func liveStallTriggersReconnect() async throws {
        let factory = MockFactory()
        let controller = makeController(Self.live, factory: factory)
        controller.start()
        let first = try #require(factory.last)
        first.start(duration: nil)
        first.emit(.state(.buffering))
        #expect(controller.phase == .buffering)
        let clock = ContinuousClock()
        var deadline = clock.now + .seconds(3)
        while factory.engines.count < 2, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(factory.engines.count == 2)
        try #require(factory.last).start(duration: nil)
        #expect(controller.phase == .playing)
        #expect(!controller.isSwitchingStream)
        deadline = clock.now + .seconds(3)
        while !first.isStopped, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(first.isStopped)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func zappingKeepsLastFrameUntilNewStreamRenders() async throws {
        let factory = MockFactory()
        let controller = makeController(Self.live, factory: factory)
        controller.start()
        factory.last?.start(duration: nil)
        let next = PlaybackItem(id: "live2", url: URL(string: "http://h/live/u/p/10.m3u8")!, title: "Chaîne 2", isLive: true)
        controller.replace(with: next, programme: LiveProgramme(title: "JT", start: .now, end: .now.addingTimeInterval(60)))
        #expect(controller.item.id == "live2")
        #expect(controller.secondaryTitle == "JT")
        #expect(controller.isSwitchingStream)
        #expect(factory.engines.count == 2)
        #expect(factory.engines[0].pauseCount == 1)
        #expect(factory.engines[0].isMuted)
        #expect(!factory.engines[0].isStopped)
        #expect(factory.last?.kind == .avFoundation)
        factory.last?.start(duration: nil)
        #expect(!controller.isSwitchingStream)
        try await Task.sleep(for: .milliseconds(300))
        #expect(factory.engines[0].isStopped)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func autoSelectsTracksFromPreferences() {
        preferences.preferredAudioLanguage = "fr"
        preferences.subtitlesEnabled = true
        preferences.preferredSubtitleLanguage = "en"
        let factory = MockFactory()
        factory.onCreate = { engine in
            engine.audioTracks = [
                MediaTrack(id: "1", name: "English", language: "en"),
                MediaTrack(id: "2", name: "Français", language: "fr"),
            ]
            engine.subtitleTracks = [
                MediaTrack(id: "4", name: "Français", language: "fr"),
                MediaTrack(id: "5", name: "English", language: "en"),
            ]
        }
        let controller = makeController(Self.vod, factory: factory)
        controller.start()
        factory.last?.start()
        #expect(factory.last?.selectedAudioID == "2")
        #expect(factory.last?.selectedSubtitleID == "5")
        #expect(controller.selectedAudioID == "2")
        #expect(controller.selectedSubtitleID == "5")

        // User choice is remembered.
        controller.select(subtitle: "4")
        #expect(preferences.preferredSubtitleLanguage == "fr")
        controller.select(subtitle: nil)
        #expect(preferences.subtitlesEnabled == false)
        controller.cycleSubtitles()
        #expect(controller.selectedSubtitleID == "4")
        controller.cycleSubtitles()
        #expect(controller.selectedSubtitleID == "5")
        controller.cycleSubtitles()
        #expect(controller.selectedSubtitleID == nil)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func seekingSkippingAndProgress() {
        let factory = MockFactory()
        let controller = makeController(Self.vod, factory: factory)
        var reports: [(TimeInterval, TimeInterval)] = []
        controller.onProgress = { reports.append(($0, $1)) }
        controller.start()
        factory.last?.start(duration: 100)
        factory.last?.emit(.time(current: 5, buffered: 20))
        #expect(controller.currentTime == 5)
        #expect(controller.bufferedTime == 20)
        #expect(reports.count == 1)
        factory.last?.emit(.time(current: 6, buffered: 20))
        #expect(reports.count == 1)  // throttled

        controller.skip(by: -10)
        #expect(controller.currentTime == 0)
        if case .skip(-10)? = controller.feedback?.kind {} else { Issue.record("missing skip feedback") }
        controller.seek(to: 500)
        #expect(controller.currentTime == 99.5)
        #expect(reports.count == 3)
        controller.pause()
        #expect(controller.phase == .paused)
        #expect(controller.isPlaying == false)
        #expect(reports.count == 4)

        factory.last?.emit(.ended)
        #expect(controller.phase == .ended)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func liveWithoutTimeshiftCannotSkip() {
        let factory = MockFactory()
        let controller = makeController(Self.live, factory: factory)
        controller.start()
        factory.last?.start(duration: nil)
        #expect(!controller.canSeek)
        controller.skip(by: 10)
        #expect(controller.feedback == nil)
        // A DVR window enables ±10 s.
        factory.last?.seekableRange = 0...3_600
        factory.last?.emit(.time(current: 3_590, buffered: 3_590))
        #expect(controller.canSeek)
        controller.skip(by: -10)
        #expect(controller.currentTime == 3_580)
        #expect(controller.isBehindLiveEdge == false)
        controller.seek(to: 100)
        #expect(controller.isBehindLiveEdge)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func volumeMuteAndRatePersistAndApply() {
        let factory = MockFactory()
        let controller = makeController(Self.vod, factory: factory)
        controller.start()
        controller.setVolume(0.3, showHUD: true)
        #expect(factory.last?.volume == 0.3)
        #expect(abs(preferences.volume - 0.3) < 0.0001)
        if case .volume? = controller.feedback?.kind {} else { Issue.record("missing volume HUD") }
        controller.toggleMute()
        #expect(factory.last?.isMuted == true)
        controller.setVolume(0.5)
        #expect(controller.isMuted == false)
        controller.setVolume(3)
        #expect(controller.volume == 1)
        controller.setRate(1.5)
        #expect(factory.last?.rate == 1.5)
        controller.cycleVideoGravity()
        #expect(factory.last?.videoGravity == .fill)
        // A new attempt inherits the settings.
        factory.last?.emit(.failed("boom"))
        #expect(factory.last?.rate == 1.5)
        #expect(factory.last?.volume == 1)
        #expect(factory.last?.videoGravity == .fill)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func controlsStayVisibleWhilePausedAndStopReleasesEngines() {
        let factory = MockFactory()
        let controller = makeController(Self.vod, factory: factory)
        controller.start()
        factory.last?.start()
        controller.pause()
        #expect(controller.controlsVisible)
        controller.stop()
        #expect(controller.phase == .idle)
        #expect(factory.last?.isStopped == true)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
