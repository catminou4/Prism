import Foundation

/// Controls auto-hide state machine (pure, clock injected as seconds).
///
/// Controls are visible on any activity and hide `delay` seconds after the last activity, only
/// while playing and when no menu/panel is open, the pointer is not resting on a control and the
/// user is not scrubbing.
nonisolated public struct ControlsAutoHide: Sendable, Equatable {
    public var delay: TimeInterval
    public private(set) var isVisible = true
    public private(set) var lastActivity: TimeInterval
    public private(set) var isPlaying = false
    public private(set) var isMenuOpen = false
    public private(set) var isPanelOpen = false
    public private(set) var isHoveringControls = false
    public private(set) var isScrubbing = false

    public init(delay: TimeInterval = 3, now: TimeInterval) {
        self.delay = delay
        self.lastActivity = now
    }

    /// Whether the hide timer may run.
    public var canAutoHide: Bool {
        isPlaying && !isMenuOpen && !isPanelOpen && !isHoveringControls && !isScrubbing
    }

    /// Instant at which the controls should hide, nil when they stay visible.
    public var hideDeadline: TimeInterval? {
        guard isVisible, canAutoHide else { return nil }
        return lastActivity + delay
    }

    /// Mouse move, key press, click…
    public mutating func registerActivity(at now: TimeInterval) {
        isVisible = true
        lastActivity = now
    }

    /// Re-evaluates the deadline. Returns true when visibility changed.
    @discardableResult
    public mutating func tick(at now: TimeInterval) -> Bool {
        guard let deadline = hideDeadline, now >= deadline else { return false }
        isVisible = false
        return true
    }

    /// Hides immediately (pointer left the window while playing). No-op when hiding is blocked.
    @discardableResult
    public mutating func hideNow() -> Bool {
        guard isVisible, canAutoHide else { return false }
        isVisible = false
        return true
    }

    public mutating func setPlaying(_ playing: Bool, at now: TimeInterval) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        // Pausing reveals the controls; resuming restarts the countdown.
        registerActivity(at: now)
    }

    public mutating func setMenuOpen(_ open: Bool, at now: TimeInterval) {
        isMenuOpen = open
        registerActivity(at: now)
    }

    public mutating func setPanelOpen(_ open: Bool, at now: TimeInterval) {
        isPanelOpen = open
        registerActivity(at: now)
    }

    public mutating func setHoveringControls(_ hovering: Bool, at now: TimeInterval) {
        guard hovering != isHoveringControls else { return }
        isHoveringControls = hovering
        registerActivity(at: now)
    }

    public mutating func setScrubbing(_ scrubbing: Bool, at now: TimeInterval) {
        isScrubbing = scrubbing
        registerActivity(at: now)
    }
}

/// Live auto-reconnect backoff: 1 s, 2 s, 4 s, 4 s, 4 s then give up.
nonisolated public struct ReconnectPolicy: Sendable, Equatable {
    public var delays: [TimeInterval]
    public var maxAttempts: Int
    /// Stall duration after which a live stream is reconnected.
    public var stallThreshold: TimeInterval
    /// Uninterrupted playback after which the attempt counter resets.
    public var stableAfter: TimeInterval

    public init(
        delays: [TimeInterval] = [1, 2, 4], maxAttempts: Int = 5, stallThreshold: TimeInterval = 8,
        stableAfter: TimeInterval = 15
    ) {
        self.delays = delays
        self.maxAttempts = maxAttempts
        self.stallThreshold = stallThreshold
        self.stableAfter = stableAfter
    }

    public static let standard = ReconnectPolicy()

    /// Delay before reconnect attempt number `attempt` (0-based), nil when exhausted.
    public func delay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 0, attempt < maxAttempts, let last = delays.last else { return nil }
        return attempt < delays.count ? delays[attempt] : last
    }
}

/// Throttles `onProgress` callbacks (every `interval` seconds while playing, forced on events).
/// 20 s keeps resume positions fresh enough while cutting disk writes ~4×; pause,
/// seek, stop and end still report immediately via `reportProgress(force: true)`.
nonisolated public struct ProgressThrottle: Sendable, Equatable {
    public var interval: TimeInterval
    public private(set) var lastReport: TimeInterval?

    public init(interval: TimeInterval = 20) {
        self.interval = interval
    }

    /// Whether a periodic report is due at `now` (records it when true).
    public mutating func shouldReport(at now: TimeInterval) -> Bool {
        if let lastReport, now - lastReport < interval { return false }
        lastReport = now
        return true
    }

    /// Records a forced report (pause/seek/stop).
    public mutating func recordForced(at now: TimeInterval) {
        lastReport = now
    }

    public mutating func reset() {
        lastReport = nil
    }
}
