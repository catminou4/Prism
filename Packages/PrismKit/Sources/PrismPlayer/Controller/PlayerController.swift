import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import Observation

/// Transient on-screen feedback (skip bubble, volume HUD, mode change).
nonisolated public struct PlayerFeedback: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// ±seconds skipped.
        case skip(Int)
        case volume(Float, muted: Bool)
        case message(String, symbol: String)
    }

    public var id: Int
    public var kind: Kind
}

/// Owns the playback session: engine selection & fallback, live reconnect, tracks, controls
/// auto-hide and progress reporting. Drive it from `PlayerView`.
@Observable
public final class PlayerController {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case playing
        case paused
        case buffering
        case ended
        case failed(String)
    }

    // MARK: - Public state

    public private(set) var item: PlaybackItem
    public private(set) var phase: Phase = .idle
    public private(set) var currentTime: TimeInterval = 0
    /// nil for live streams and while unknown.
    public private(set) var duration: TimeInterval?
    public private(set) var bufferedTime: TimeInterval = 0
    public var isLive: Bool { item.isLive }
    public private(set) var rate: Float = 1
    /// 0…1.
    public private(set) var volume: Float
    public private(set) var isMuted = false
    public private(set) var audioTracks: [MediaTrack] = []
    public private(set) var subtitleTracks: [MediaTrack] = []
    public private(set) var selectedAudioID: MediaTrack.ID?
    public private(set) var selectedSubtitleID: MediaTrack.ID?
    /// Engine of the current attempt (`.auto` before the first attempt).
    public private(set) var engineKind: PlaybackEngineKind = .auto
    public private(set) var currentAttempt: PlaybackAttempt?
    public private(set) var videoGravity: VideoGravity = .fit
    public private(set) var aspectRatio: VideoAspectRatio = .automatic
    public private(set) var techInfo: StreamTechSnapshot = .empty
    public private(set) var controlsVisible = true
    public private(set) var isPictureInPictureActive = false
    public private(set) var isPictureInPictureSupported = false
    public private(set) var supportsAspectRatioOverride = false
    public private(set) var videoSize: CGSize?
    /// Zapping / fallback / reconnect in progress: the last frame stays on screen with a spinner.
    public private(set) var isSwitchingStream = false
    /// "Reconnexion…", "Nouvelle tentative…" while recovering.
    public private(set) var statusMessage: String?
    public private(set) var feedback: PlayerFeedback?
    /// Live DVR window (engine timeline) when the stream is seekable enough for ±10 s.
    public private(set) var timeshiftWindow: ClosedRange<TimeInterval>?
    /// User intent: true when playback should run (drives the play/pause symbol).
    public private(set) var playRequested = false
    public private(set) var subtitleStyle: SubtitleStyle
    /// Programme airing on the live channel (progress in the scrubber, top title).
    public var liveProgramme: LiveProgramme?

    public let preferences: PlayerPreferences
    /// AVPlayer of the current engine, for the AirPlay route picker (nil with VLC).
    private(set) var routingPlayer: AVPlayer?

    /// (position, duration) — VOD only, every 5 s while playing and on pause/seek/stop/end.
    @ObservationIgnored public var onProgress: ((TimeInterval, TimeInterval) -> Void)?
    @ObservationIgnored public var onEnded: (() -> Void)?
    /// Called once every attempt of the plan failed.
    @ObservationIgnored public var onFailed: ((String) -> Void)?

    // MARK: - Derived

    public var isPlaying: Bool { playRequested }
    public var isLoading: Bool { phase == .loading || phase == .buffering || isSwitchingStream }

    /// Seeking is possible for VOD with a known duration and live streams with a DVR window.
    public var canSeek: Bool {
        item.isLive ? timeshiftWindow != nil : (duration ?? 0) > 0
    }

    public var remainingTime: TimeInterval? {
        guard !item.isLive, let duration else { return nil }
        return max(0, duration - currentTime)
    }

    /// 0…1 position used by the scrubber (programme progress for live without DVR).
    public func playbackFraction(at date: Date = .now) -> Double {
        if item.isLive {
            if let window = timeshiftWindow {
                let span = window.upperBound - window.lowerBound
                return span > 0 ? min(1, max(0, (currentTime - window.lowerBound) / span)) : 1
            }
            return liveProgramme?.progress(at: date) ?? 1
        }
        guard let duration, duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    public var bufferedFraction: Double {
        guard !item.isLive, let duration, duration > 0 else { return 0 }
        return min(1, max(0, bufferedTime / duration))
    }

    /// Text shown top-centre: programme title for live, else the item subtitle.
    public var secondaryTitle: String? {
        if let title = liveProgramme?.title, !title.isEmpty { return title }
        return item.subtitle
    }

    /// Whether the live timeshift is behind the live edge (HLS players sit ~3 target durations
    /// behind the end of the window, hence the margin).
    public var isBehindLiveEdge: Bool {
        guard item.isLive, let window = timeshiftWindow else { return false }
        return window.upperBound - currentTime > 45
    }

    // MARK: - Internals

    @ObservationIgnored let videoContainer = PlayerVideoContainerView()
    @ObservationIgnored private(set) var engine: (any PlaybackEngine)?
    @ObservationIgnored private var retiringEngines: [any PlaybackEngine] = []
    @ObservationIgnored private var engineGeneration = 0
    @ObservationIgnored private(set) var plan: [PlaybackAttempt] = []
    @ObservationIgnored private(set) var planIndex = 0
    @ObservationIgnored private var attemptReady = false
    @ObservationIgnored private var attemptRendered = false
    @ObservationIgnored private var lastErrorMessage: String?
    @ObservationIgnored private var isReconnecting = false
    @ObservationIgnored private(set) var reconnectCount = 0
    @ObservationIgnored private var playingSince: TimeInterval?
    @ObservationIgnored private var lastObservedTime: TimeInterval = -1
    @ObservationIgnored private var firstObservedTime: TimeInterval?
    @ObservationIgnored private var lastProgressAt: TimeInterval = 0
    @ObservationIgnored private var didAutoSelectAudio = false
    @ObservationIgnored private var didAutoSelectSubtitles = false
    @ObservationIgnored private var autoHide: ControlsAutoHide
    @ObservationIgnored private var progressThrottle = ProgressThrottle()
    @ObservationIgnored private var feedbackCounter = 0
    @ObservationIgnored private var volumeNeedsSave = false

    @ObservationIgnored private var loadTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var stallTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var feedbackTask: Task<Void, Never>?
    @ObservationIgnored private var seekTask: Task<Void, Never>?

    @ObservationIgnored private let engineFactory: PlaybackEngineFactory
    @ObservationIgnored private let uptime: () -> TimeInterval
    @ObservationIgnored let loadTimeout: Duration
    @ObservationIgnored let reconnectPolicy: ReconnectPolicy
    /// Stall threshold for VOD before the current attempt is reopened at the same position.
    @ObservationIgnored let vodStallThreshold: TimeInterval = 20

    // MARK: - Init

    public convenience init(item: PlaybackItem, preferences: PlayerPreferences = .standard) {
        self.init(
            item: item, preferences: preferences, engineFactory: DefaultEngineFactory.make,
            loadTimeout: .seconds(10), reconnectPolicy: .standard,
            uptime: { ProcessInfo.processInfo.systemUptime })
    }

    /// Designated initializer (engine factory and clocks injectable for tests).
    init(
        item: PlaybackItem, preferences: PlayerPreferences, engineFactory: @escaping PlaybackEngineFactory,
        loadTimeout: Duration, reconnectPolicy: ReconnectPolicy, uptime: @escaping () -> TimeInterval
    ) {
        self.item = item
        self.preferences = preferences
        self.engineFactory = engineFactory
        self.loadTimeout = loadTimeout
        self.reconnectPolicy = reconnectPolicy
        self.uptime = uptime
        self.volume = preferences.volume
        self.subtitleStyle = preferences.subtitleStyle
        self.autoHide = ControlsAutoHide(delay: 3, now: uptime())
        self.currentTime = item.startPosition ?? 0
    }

    isolated deinit {
        cancelTasks()
        hideTask?.cancel()
        feedbackTask?.cancel()
        engine?.stop()
        retiringEngines.forEach { $0.stop() }
    }

    // MARK: - Session

    /// Starts loading the item (idempotent while a session is active).
    public func start() {
        switch phase {
        case .idle, .failed:
            let resume = (!item.isLive && currentTime > 1) ? currentTime : item.startPosition
            begin(startPosition: resume)
        default:
            break
        }
    }

    /// Restarts the attempt plan from the first attempt (error card "Réessayer").
    public func retry() {
        let resume = (!item.isLive && currentTime > 1) ? currentTime : item.startPosition
        begin(startPosition: resume)
    }

    /// Channel zapping / next episode: keeps the last frame until the new stream renders.
    public func replace(with newItem: PlaybackItem, programme: LiveProgramme? = nil) {
        reportProgress()
        item = newItem
        liveProgramme = programme
        duration = nil
        currentTime = newItem.startPosition ?? 0
        bufferedTime = 0
        timeshiftWindow = nil
        audioTracks = []
        subtitleTracks = []
        selectedAudioID = nil
        selectedSubtitleID = nil
        techInfo = .empty
        videoSize = nil
        if newItem.isLive { setRateValue(1) }
        begin(startPosition: newItem.startPosition)
    }

    /// Stops playback and releases the engines (window closed).
    public func stop() {
        reportProgress()
        saveVolume()
        cancelTasks()
        playRequested = false
        tearDownEngines()
        isSwitchingStream = false
        statusMessage = nil
        // Clear stream-derived state so a later start() doesn't show the previous
        // item's duration/tracks/tech info while the new one loads.
        // (`currentTime` is kept: it is the resume position for `start()`.)
        duration = nil
        bufferedTime = 0
        timeshiftWindow = nil
        audioTracks = []
        subtitleTracks = []
        selectedAudioID = nil
        selectedSubtitleID = nil
        techInfo = .empty
        setPhase(.idle)
    }

    private func begin(startPosition: TimeInterval?) {
        cancelTasks()
        plan = EngineSelector.attemptPlan(for: item, defaultEngine: preferences.defaultEngine)
        planIndex = 0
        reconnectCount = 0
        isReconnecting = false
        lastErrorMessage = nil
        didAutoSelectAudio = false
        didAutoSelectSubtitles = false
        progressThrottle.reset()
        playRequested = true
        statusMessage = nil
        isSwitchingStream = !retiringEngines.isEmpty || (engine != nil && attemptRendered)
        setPhase(.loading)
        beginAttempt(at: 0, startPosition: startPosition)
    }

    // MARK: - Attempts

    private func beginAttempt(at index: Int, startPosition: TimeInterval?) {
        guard plan.indices.contains(index) else {
            fail(lastErrorMessage ?? "Ce flux ne peut pas être lu.")
            return
        }
        loadTimeoutTask?.cancel()
        stopStallWatch()
        cancelPendingSeek()
        let attempt = plan[index]
        let previous = engine
        let previousRendered = attemptRendered

        let newEngine = engineFactory(attempt.engine, preferences.engineConfiguration)
        newEngine.volume = volume
        newEngine.isMuted = isMuted
        newEngine.rate = item.isLive ? 1 : rate
        newEngine.videoGravity = videoGravity
        newEngine.aspectRatio = aspectRatio
        newEngine.subtitleStyle = subtitleStyle
        engineGeneration += 1
        let generation = engineGeneration
        newEngine.eventHandler = { [weak self] event in
            self?.handle(event, generation: generation)
        }

        if let previous {
            previous.eventHandler = nil
            if previousRendered {
                // Keep its last frame on top until the new engine renders.
                previous.pause()
                previous.isMuted = true
                retiringEngines.append(previous)
                isSwitchingStream = true
            } else {
                videoContainer.remove(previous.videoView, animated: false)
                previous.stop()
            }
        }
        videoContainer.insertAtBottom(newEngine.videoView)

        engine = newEngine
        currentAttempt = attempt
        engineKind = attempt.engine
        attemptReady = false
        attemptRendered = false
        playingSince = nil
        lastObservedTime = -1
        firstObservedTime = nil
        lastProgressAt = uptime()
        isPictureInPictureActive = false
        isPictureInPictureSupported = newEngine.supportsPictureInPicture
        routingPlayer = newEngine.routingPlayer
        supportsAspectRatioOverride = newEngine.supportsAspectRatioOverride

        restartLoadTimeout()
        newEngine.load(
            url: attempt.url, headers: item.httpHeaders, startPosition: startPosition, isLive: item.isLive)
        // An engine can fail synchronously in load(), after which it has already been replaced.
        if generation == engineGeneration, playRequested { newEngine.play() }
    }

    private func advanceAttempt(startPosition: TimeInterval?) {
        let next = planIndex + 1
        guard next < plan.count else {
            fail(lastErrorMessage ?? "Ce flux ne peut pas être lu.")
            return
        }
        planIndex = next
        statusMessage = "Nouvelle tentative…"
        setPhase(.loading)
        beginAttempt(at: next, startPosition: startPosition)
    }

    /// (Re)arms the attempt load timeout for the current engine generation.
    private func restartLoadTimeout() {
        loadTimeoutTask?.cancel()
        let generation = engineGeneration
        let timeout = loadTimeout
        loadTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.handleLoadTimeout(generation: generation)
        }
    }

    private func handleLoadTimeout(generation: Int) {
        // A paused attempt is not failing: don't burn through the plan while the
        // user is away. Playback events (.ready/.failed/stall) still drive it.
        guard generation == engineGeneration, !attemptRendered, playRequested else { return }
        handleFailure("Le flux ne répond pas (délai dépassé).")
    }

    private func handleFailure(_ message: String) {
        lastErrorMessage = message
        loadTimeoutTask?.cancel()
        stopStallWatch()
        if isReconnecting {
            scheduleReconnect()
        } else if attemptRendered {
            if item.isLive {
                scheduleReconnect()
            } else {
                // Mid-playback VOD failure: next attempt resumes at the same position.
                advanceAttempt(startPosition: currentTime)
            }
        } else {
            advanceAttempt(startPosition: item.isLive ? nil : (currentTime > 1 ? currentTime : item.startPosition))
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        guard let delay = reconnectPolicy.delay(forAttempt: reconnectCount) else {
            fail(lastErrorMessage ?? "La diffusion a été interrompue.")
            return
        }
        reconnectCount += 1
        isReconnecting = true
        statusMessage = "Reconnexion…"
        if phase != .loading { setPhase(.buffering) }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            // First retries stay on the same URL (transient stalls recover fast),
            // then hop to the next fallback: a stream dead mid-playback would
            // otherwise retest the same URL until the policy gives up.
            var index = self.planIndex
            if self.reconnectCount >= 2, self.plan.count > 1, let current = self.currentAttempt {
                for offset in 1..<self.plan.count {
                    let candidate = (self.planIndex + offset) % self.plan.count
                    if self.plan[candidate].url != current.url {
                        index = candidate
                        break
                    }
                }
            }
            self.planIndex = index
            let position: TimeInterval? = self.item.isLive ? nil : self.currentTime
            self.beginAttempt(at: index, startPosition: position)
        }
    }

    private func fail(_ message: String) {
        cancelTasks()
        tearDownEngines()
        playRequested = false
        isSwitchingStream = false
        statusMessage = nil
        setPhase(.failed(message))
        showControls()
        onFailed?(message)
    }

    // MARK: - Engine events

    private func handle(_ event: EngineEvent, generation: Int) {
        guard generation == engineGeneration, engine != nil else { return }
        switch event {
        case .ready(let engineDuration):
            attemptReady = true
            if !item.isLive, let engineDuration, engineDuration > 0 { duration = engineDuration }
            if !playRequested { loadTimeoutTask?.cancel() }
            refreshTracks()
        case .time(let current, let buffered):
            handleTime(current: current, buffered: buffered)
        case .state(let state):
            handleState(state)
        case .firstFrame:
            handleFirstFrame()
        case .ended:
            handleEnded()
        case .failed(let message):
            handleFailure(message)
        case .tracksChanged:
            refreshTracks()
        case .videoSize(let size):
            if videoSize != size { videoSize = size }
        case .pictureInPicture(let active):
            if isPictureInPictureActive != active { isPictureInPictureActive = active }
        }
    }

    private func handleTime(current: TimeInterval, buffered: TimeInterval) {
        let now = uptime()
        if !autoHide.isScrubbing, seekTask == nil, currentTime != current { currentTime = current }
        if bufferedTime != buffered { bufferedTime = buffered }
        if abs(current - lastObservedTime) > 0.01 {
            lastObservedTime = current
            lastProgressAt = now
        }
        // Clock running for a second counts as "rendering" (offscreen/occluded layers never
        // become ready for display).
        if !attemptRendered, attemptReady {
            if let first = firstObservedTime {
                if current - first >= 1 { handleFirstFrame() }
            } else {
                firstObservedTime = current
            }
        }
        if item.isLive, let engine {
            // A DVR window of at least a minute (or any window when the source advertises timeshift).
            let minimumWindow: TimeInterval = item.supportsTimeshift ? 10 : 60
            let window = engine.seekableRange.flatMap {
                $0.upperBound - $0.lowerBound >= minimumWindow ? $0 : nil
            }
            if window != timeshiftWindow { timeshiftWindow = window }
        }
        if phase == .playing, let since = playingSince, now - since >= reconnectPolicy.stableAfter,
            reconnectCount > 0
        {
            reconnectCount = 0
        }
        if phase == .playing, !item.isLive, !autoHide.isScrubbing, seekTask == nil,
           let duration, progressThrottle.shouldReport(at: now) {
            onProgress?(currentTime, duration)
        }
    }

    private func handleState(_ state: EnginePlaybackState) {
        // AVPlayer reports "paused" right after reaching the end: keep `.ended`.
        if phase == .ended, state != .playing { return }
        switch state {
        case .playing:
            guard playRequested else { return }
            if playingSince == nil { playingSince = uptime() }
            stopStallWatch()
            // The stream recovered during a reconnect backoff: cancel the pending
            // teardown instead of bouncing a healthy player.
            reconnectTask?.cancel()
            reconnectTask = nil
            isReconnecting = false
            if !isSwitchingStream { statusMessage = nil }
            setPhase(.playing)
        case .paused, .buffering:
            playingSince = nil
            guard playRequested else {
                stopStallWatch()
                setPhase(.paused)
                return
            }
            setPhase(attemptRendered ? .buffering : .loading)
            watchForStall()
        }
    }

    private func handleFirstFrame() {
        attemptRendered = true
        loadTimeoutTask?.cancel()
        isReconnecting = false
        retireOldEngines()
        isSwitchingStream = false
        statusMessage = nil
        if !playRequested { engine?.pause() }
        refreshTechInfo()
    }

    private func handleEnded() {
        if item.isLive {
            lastErrorMessage = "La diffusion s’est arrêtée."
            scheduleReconnect()
            return
        }
        guard phase != .ended else { return }  // duplicate .ended must not re-fire onEnded
        if let duration { currentTime = duration }
        playRequested = false
        reportProgress()
        setPhase(.ended)
        showControls()
        onEnded?()
    }

    private func watchForStall() {
        guard attemptRendered, playRequested, stallTask == nil else { return }
        let threshold = item.isLive ? reconnectPolicy.stallThreshold : vodStallThreshold
        let beganWaitingAt = uptime()
        stallTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self.map({ controller in
                    max(beganWaitingAt, controller.lastProgressAt) + threshold - controller.uptime()
                }) else { return }
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }
                guard let self else { return }
                self.stallTask = nil
                guard self.playRequested, self.phase == .buffering || self.phase == .loading else {
                    return
                }
                self.lastErrorMessage = "Le flux ne répond plus."
                self.scheduleReconnect()
                return
            }
        }
    }

    private func stopStallWatch() {
        stallTask?.cancel()
        stallTask = nil
    }

    private func retireOldEngines() {
        guard !retiringEngines.isEmpty else { return }
        let old = retiringEngines
        retiringEngines = []
        for engine in old {
            // Stop only once faded out, otherwise the last frame disappears instantly.
            videoContainer.remove(engine.videoView, animated: true) { engine.stop() }
        }
    }

    private func tearDownEngines() {
        engineGeneration += 1
        if let engine {
            videoContainer.remove(engine.videoView, animated: false)
            engine.stop()
        }
        engine = nil
        for old in retiringEngines {
            videoContainer.remove(old.videoView, animated: false)
            old.stop()
        }
        retiringEngines = []
        attemptReady = false
        attemptRendered = false
        isPictureInPictureActive = false
        routingPlayer = nil
        videoSize = nil
    }

    private func cancelTasks() {
        loadTimeoutTask?.cancel()
        reconnectTask?.cancel()
        reconnectTask = nil
        stopStallWatch()
        cancelPendingSeek()
    }

    private func cancelPendingSeek() {
        seekTask?.cancel()
        seekTask = nil
    }

    // MARK: - Tracks

    private func refreshTracks() {
        guard let engine else { return }
        audioTracks = engine.audioTracks
        subtitleTracks = engine.subtitleTracks
        applyAutoSelectionIfNeeded()
        selectedAudioID = engine.selectedAudioID
        selectedSubtitleID = engine.selectedSubtitleID
    }

    private func applyAutoSelectionIfNeeded() {
        guard let engine else { return }
        if !didAutoSelectAudio, !audioTracks.isEmpty {
            didAutoSelectAudio = true
            if let id = TrackAutoSelector.audioSelection(
                in: audioTracks, preferredLanguage: preferences.preferredAudioLanguage),
                id != engine.selectedAudioID
            {
                engine.select(audio: id)
            }
        }
        if !didAutoSelectSubtitles, !subtitleTracks.isEmpty {
            didAutoSelectSubtitles = true
            if let decision = TrackAutoSelector.subtitleSelection(
                in: subtitleTracks, enabled: preferences.subtitlesEnabled,
                preferredLanguage: preferences.preferredSubtitleLanguage),
                decision != engine.selectedSubtitleID
            {
                engine.select(subtitle: decision)
            }
        }
    }

    // MARK: - Transport

    public func play() {
        switch phase {
        case .idle:
            start()
            return
        case .failed:
            retry()
            return
        case .ended:
            playRequested = true
            // Rewind before resuming: playing while a seek is in flight races the
            // engine. beginSeek resumes playback on completion while playRequested
            // holds; fall back to playing directly when seeking isn't possible.
            if !beginSeek(target: 0) {
                engine?.play()
                if attemptRendered { setPhase(.playing) }
            }
            return
        default:
            playRequested = true
            // Resuming a paused attempt that never rendered needs its load timeout
            // back: it may have been consumed while the user was away.
            if !attemptRendered { restartLoadTimeout() }
        }
        engine?.play()
        if attemptRendered, phase == .paused || phase == .ended { setPhase(.playing) }
    }

    public func pause() {
        playRequested = false
        stopStallWatch()
        engine?.pause()
        if phase == .playing || phase == .buffering || phase == .loading { setPhase(.paused) }
        reportProgress()
    }

    public func togglePlayPause() {
        playRequested ? pause() : play()
        noteUserActivity()
    }

    public func seek(to seconds: TimeInterval) {
        _ = beginSeek(target: clampedSeekTarget(seconds))
    }

    /// Starts an engine seek tracked by `seekTask` (which keeps `currentTime` and
    /// progress reports frozen until the engine lands). Returns false when seeking
    /// isn't possible right now. On completion, playback resumes if `playRequested`
    /// still holds — this replays from the start after `.ended` without racing the
    /// seek, and stays a no-op for seeks issued while paused.
    @discardableResult
    private func beginSeek(target: TimeInterval) -> Bool {
        guard canSeek, let engine else { return false }
        currentTime = target
        if phase == .ended { setPhase(.paused) }
        reportProgress()
        seekTask?.cancel()
        seekTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await engine.seek(to: target)
            guard !Task.isCancelled, let self else { return }
            self.seekTask = nil
            if self.playRequested { self.engine?.play() }
        }
        return true
    }

    /// ±10 s skip with on-screen feedback (no-op for live without DVR).
    public func skip(by seconds: TimeInterval) {
        guard canSeek else { return }
        seek(to: currentTime + seconds)
        showFeedback(.skip(Int(seconds.rounded())))
        noteUserActivity()
    }

    /// Jumps back to the live edge (DVR streams).
    public func seekToLiveEdge() {
        guard let window = timeshiftWindow else { return }
        seek(to: window.upperBound)
    }

    func clampedSeekTarget(_ seconds: TimeInterval) -> TimeInterval {
        if item.isLive, let window = timeshiftWindow {
            return min(window.upperBound, max(window.lowerBound, seconds))
        }
        let upper = max(0, (duration ?? 0) - 0.5)
        return min(upper, max(0, seconds))
    }

    // MARK: - Audio

    public func setVolume(_ value: Float, showHUD: Bool = false) {
        setVolume(value, showHUD: showHUD, save: true)
    }

    func setVolume(_ value: Float, showHUD: Bool = false, save: Bool) {
        let clamped = min(1, max(0, value))
        if volume != clamped {
            volume = clamped
            engine?.volume = clamped
            volumeNeedsSave = true
        }
        if save { saveVolume() }
        if clamped > 0, isMuted {
            isMuted = false
            engine?.isMuted = false
        }
        if showHUD { showFeedback(.volume(clamped, muted: isMuted)) }
    }

    func saveVolume() {
        guard volumeNeedsSave else { return }
        preferences.volume = volume
        volumeNeedsSave = false
    }

    public func toggleMute() {
        isMuted.toggle()
        engine?.isMuted = isMuted
        showFeedback(.volume(volume, muted: isMuted))
    }

    public func setRate(_ value: Float) {
        guard !item.isLive else { return }
        setRateValue(min(2, max(0.5, value)))
    }

    private func setRateValue(_ value: Float) {
        rate = value
        engine?.rate = value
    }

    // MARK: - Tracks (user)

    public func select(audio id: MediaTrack.ID?) {
        guard let engine, let id else { return }
        engine.select(audio: id)
        selectedAudioID = id
        if let language = audioTracks.first(where: { $0.id == id })?.language {
            preferences.preferredAudioLanguage = language
        }
    }

    public func select(subtitle id: MediaTrack.ID?) {
        guard let engine else { return }
        engine.select(subtitle: id)
        selectedSubtitleID = id
        if let id {
            preferences.subtitlesEnabled = true
            if let language = subtitleTracks.first(where: { $0.id == id })?.language {
                preferences.preferredSubtitleLanguage = language
            }
        } else {
            preferences.subtitlesEnabled = false
        }
    }

    /// Off → track 1 → track 2 … → off (`S` key).
    public func cycleSubtitles() {
        let options: [MediaTrack.ID?] = [nil] + subtitleTracks.map(\.id)
        let index = options.firstIndex(where: { $0 == selectedSubtitleID }) ?? 0
        let next = options[(index + 1) % options.count]
        select(subtitle: next)
        let name = next.flatMap { id in subtitleTracks.first { $0.id == id }?.name }
        showFeedback(.message(name.map { "Sous-titres : \($0)" } ?? "Sous-titres désactivés", symbol: "captions.bubble"))
    }

    public func setSubtitleStyle(_ style: SubtitleStyle) {
        subtitleStyle = style
        preferences.subtitleStyle = style
        engine?.subtitleStyle = style
    }

    // MARK: - Picture

    public func cycleVideoGravity() {
        setVideoGravity(videoGravity.next)
        showFeedback(.message(videoGravity.label, symbol: "rectangle.arrowtriangle.2.outward"))
    }

    public func setVideoGravity(_ gravity: VideoGravity) {
        videoGravity = gravity
        engine?.videoGravity = gravity
    }

    public func setAspectRatio(_ ratio: VideoAspectRatio) {
        aspectRatio = ratio
        engine?.aspectRatio = ratio
    }

    public func togglePictureInPicture() {
        engine?.togglePictureInPicture()
    }

    /// Pulls fresh technical info from the engine (the info overlay refreshes every second).
    public func refreshTechInfo() {
        guard let engine else { return }
        let info = engine.techInfo
        if info != techInfo { techInfo = info }
    }

    // MARK: - Controls auto-hide

    /// Mouse move, key press, click: reveals the controls and restarts the 3 s countdown.
    public func noteUserActivity() {
        autoHide.registerActivity(at: uptime())
        applyControlsVisibility()
    }

    func pointerMoved() {
        // The pending timer reads the latest deadline when it wakes. High-rate
        // pointer events only need to publish changes when restoring the controls.
        let wasVisible = autoHide.isVisible
        autoHide.registerActivity(at: uptime())
        if !wasVisible { applyControlsVisibility() }
    }

    /// Pointer left the window: hide right away while playing.
    public func pointerExited() {
        autoHide.hideNow()
        applyControlsVisibility()
    }

    public func setMenuOpen(_ open: Bool) {
        autoHide.setMenuOpen(open, at: uptime())
        applyControlsVisibility()
    }

    public func setPanelOpen(_ open: Bool) {
        autoHide.setPanelOpen(open, at: uptime())
        applyControlsVisibility()
    }

    public func setHoveringControls(_ hovering: Bool) {
        autoHide.setHoveringControls(hovering, at: uptime())
        applyControlsVisibility()
    }

    /// While the user drags the scrubber: time updates from the engine are ignored.
    public func setScrubbing(_ scrubbing: Bool) {
        autoHide.setScrubbing(scrubbing, at: uptime())
        applyControlsVisibility()
    }

    var isScrubbing: Bool { autoHide.isScrubbing }

    private func showControls() {
        autoHide.registerActivity(at: uptime())
        applyControlsVisibility()
    }

    private func applyControlsVisibility() {
        if controlsVisible != autoHide.isVisible { controlsVisible = autoHide.isVisible }
        scheduleHideIfNeeded()
    }

    private func scheduleHideIfNeeded() {
        guard autoHide.hideDeadline != nil else {
            hideTask?.cancel()
            hideTask = nil
            return
        }
        guard hideTask == nil else { return }
        hideTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let deadline = self.autoHide.hideDeadline else { break }
                let wait = deadline - self.uptime()
                if wait <= 0 {
                    self.autoHide.tick(at: self.uptime())
                    break
                }
                try? await Task.sleep(for: .seconds(wait))
            }
            guard let self, !Task.isCancelled else { return }
            self.hideTask = nil
            if self.controlsVisible != self.autoHide.isVisible {
                self.controlsVisible = self.autoHide.isVisible
            }
        }
    }

    private func setPhase(_ newPhase: Phase) {
        if phase != newPhase { phase = newPhase }
        let playing = playRequested && (newPhase == .playing || newPhase == .buffering)
        autoHide.setPlaying(playing, at: uptime())
        applyControlsVisibility()
    }

    // MARK: - Feedback & progress

    func showFeedback(_ kind: PlayerFeedback.Kind) {
        feedbackCounter += 1
        feedback = PlayerFeedback(id: feedbackCounter, kind: kind)
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.feedback = nil
        }
    }

    /// Immediate progress report for pause/seek/stop/end/replace — bypasses the
    /// 20 s `ProgressThrottle` and re-arms it so the next periodic tick waits a full interval.
    private func reportProgress() {
        guard !item.isLive, let duration, duration > 0, attemptReady || currentTime > 0 else { return }
        progressThrottle.recordForced(at: uptime())
        onProgress?(currentTime, duration)
    }
}

/// Black container hosting the engines' views. Owned by the controller so engine views survive
/// SwiftUI updates; new engines are inserted *below* the previous one, which keeps its last frame
/// on top until the new stream renders.
final class PlayerVideoContainerView: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func insertAtBottom(_ view: NSView) {
        guard view.superview !== self else { return }
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        view.alphaValue = 1
        addSubview(view, positioned: .below, relativeTo: nil)
    }

    func remove(_ view: NSView, animated: Bool, completion: (() -> Void)? = nil) {
        guard view.superview === self else {
            completion?()
            return
        }
        guard animated else {
            view.removeFromSuperview()
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            view.animator().alphaValue = 0
        }
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            view.removeFromSuperview()
            completion?()
        }
    }
}

// MARK: - Previews & snapshots

extension PlayerController {
    /// Static controller for SwiftUI previews and offscreen snapshots: no engine is created and
    /// nothing is persisted. Pair with `.environment(\.playerSnapshotRendering, true)` offscreen.
    public static func preview(
        item: PlaybackItem,
        phase: Phase = .playing,
        currentTime: TimeInterval = 27,
        duration: TimeInterval? = 156,
        bufferedTime: TimeInterval? = nil,
        audioTracks: [MediaTrack] = [],
        subtitleTracks: [MediaTrack] = [],
        selectedAudioID: MediaTrack.ID? = nil,
        selectedSubtitleID: MediaTrack.ID? = nil,
        liveProgramme: LiveProgramme? = nil,
        timeshiftWindow: ClosedRange<TimeInterval>? = nil,
        volume: Float = 1,
        isMuted: Bool = false,
        controlsVisible: Bool = true,
        isSwitchingStream: Bool = false,
        statusMessage: String? = nil,
        feedback: PlayerFeedback.Kind? = nil,
        pictureInPictureSupported: Bool = true,
        techInfo: StreamTechSnapshot = .empty
    ) -> PlayerController {
        let preferences = PlayerPreferences(
            defaults: UserDefaults(suiteName: "prism.player.preview") ?? .standard, keyPrefix: "preview.")
        let controller = PlayerController(
            item: item, preferences: preferences,
            engineFactory: { _, _ in PreviewEngine() },
            loadTimeout: .seconds(3600), reconnectPolicy: .standard,
            uptime: { ProcessInfo.processInfo.systemUptime })
        controller.phase = phase
        controller.playRequested = phase == .playing || phase == .buffering || phase == .loading
        controller.currentTime = currentTime
        controller.duration = item.isLive ? nil : duration
        controller.bufferedTime = bufferedTime ?? min(duration ?? 0, currentTime + 40)
        controller.audioTracks = audioTracks
        controller.subtitleTracks = subtitleTracks
        controller.selectedAudioID = selectedAudioID ?? audioTracks.first?.id
        controller.selectedSubtitleID = selectedSubtitleID
        controller.liveProgramme = liveProgramme
        controller.timeshiftWindow = timeshiftWindow
        controller.volume = volume
        controller.isMuted = isMuted
        controller.controlsVisible = controlsVisible
        controller.isSwitchingStream = isSwitchingStream
        controller.statusMessage = statusMessage
        controller.isPictureInPictureSupported = pictureInPictureSupported
        controller.techInfo = techInfo
        controller.engineKind = EngineSelector.engine(for: item)
        if let feedback {
            controller.feedbackCounter += 1
            controller.feedback = PlayerFeedback(id: controller.feedbackCounter, kind: feedback)
        }
        return controller
    }
}

/// Inert engine used by previews.
final class PreviewEngine: PlaybackEngine {
    let kind: PlaybackEngineKind = .avFoundation
    let videoView: NSView = BlackVideoSurfaceView(frame: .zero)
    var eventHandler: ((EngineEvent) -> Void)?
    func load(url: URL, headers: [String: String], startPosition: TimeInterval?, isLive: Bool) {}
    func play() {}
    func pause() {}
    func seek(to seconds: TimeInterval) async {}
    func stop() {}
    var rate: Float = 1
    var volume: Float = 1
    var isMuted = false
    var audioTracks: [MediaTrack] { [] }
    var subtitleTracks: [MediaTrack] { [] }
    var selectedAudioID: MediaTrack.ID? { nil }
    var selectedSubtitleID: MediaTrack.ID? { nil }
    func select(audio id: MediaTrack.ID?) {}
    func select(subtitle id: MediaTrack.ID?) {}
    var subtitleStyle: SubtitleStyle = .system
    var videoGravity: VideoGravity = .fit
    var aspectRatio: VideoAspectRatio = .automatic
    var supportsAspectRatioOverride: Bool { false }
    var seekableRange: ClosedRange<TimeInterval>? { nil }
    var techInfo: StreamTechSnapshot { .empty }
    var supportsPictureInPicture: Bool { false }
    var isPictureInPictureActive: Bool { false }
    func togglePictureInPicture() {}
    var routingPlayer: AVPlayer? { nil }
}
