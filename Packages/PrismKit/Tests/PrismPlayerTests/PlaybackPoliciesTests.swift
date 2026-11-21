import Foundation
import Testing

@testable import PrismPlayer

@Suite struct ControlsAutoHideTests {
    @Test func hidesThreeSecondsAfterActivityWhilePlaying() {
        var state = ControlsAutoHide(now: 0)
        state.setPlaying(true, at: 0)
        #expect(state.hideDeadline == 3)
        state.tick(at: 2.9)
        #expect(state.isVisible)
        let r1 = state.tick(at: 3.0); #expect(r1)
        #expect(!state.isVisible)
        #expect(state.hideDeadline == nil)
    }

    @Test func activityRevealsAndRestartsCountdown() {
        var state = ControlsAutoHide(now: 0)
        state.setPlaying(true, at: 0)
        state.tick(at: 5)
        #expect(!state.isVisible)
        state.registerActivity(at: 6)
        #expect(state.isVisible)
        #expect(state.hideDeadline == 9)
        state.registerActivity(at: 8)
        state.tick(at: 9)
        #expect(state.isVisible)
        state.tick(at: 11)
        #expect(!state.isVisible)
    }

    @Test func neverHidesWhilePaused() {
        var state = ControlsAutoHide(now: 0)
        state.setPlaying(true, at: 0)
        state.setPlaying(false, at: 1)
        #expect(state.hideDeadline == nil)
        let r2 = state.tick(at: 100); #expect(!r2)
        #expect(state.isVisible)
        let r3 = state.hideNow(); #expect(!r3)
    }

    @Test func pausingRevealsHiddenControls() {
        var state = ControlsAutoHide(now: 0)
        state.setPlaying(true, at: 0)
        state.tick(at: 4)
        #expect(!state.isVisible)
        state.setPlaying(false, at: 5)
        #expect(state.isVisible)
    }

    @Test func menusPanelsHoverAndScrubbingBlockHiding() {
        var state = ControlsAutoHide(now: 0)
        state.setPlaying(true, at: 0)
        state.setMenuOpen(true, at: 1)
        let r4 = state.tick(at: 10); #expect(!r4)
        state.setMenuOpen(false, at: 10)
        #expect(state.hideDeadline == 13)

        state.setPanelOpen(true, at: 11)
        #expect(state.hideDeadline == nil)
        state.setPanelOpen(false, at: 12)

        state.setHoveringControls(true, at: 12)
        let r5 = state.tick(at: 20); #expect(!r5)
        state.setHoveringControls(false, at: 20)

        state.setScrubbing(true, at: 21)
        let r6 = state.tick(at: 30); #expect(!r6)
        state.setScrubbing(false, at: 30)
        let r7 = state.tick(at: 33); #expect(r7)
    }

    @Test func pointerExitHidesImmediatelyOnlyWhenAllowed() {
        var state = ControlsAutoHide(now: 0)
        state.setPlaying(true, at: 0)
        let r8 = state.hideNow(); #expect(r8)
        #expect(!state.isVisible)
        state.registerActivity(at: 1)
        state.setMenuOpen(true, at: 1)
        let r9 = state.hideNow(); #expect(!r9)
    }
}

@Suite struct ReconnectAndProgressPolicyTests {
    @Test func backoffSequence() {
        let policy = ReconnectPolicy.standard
        #expect((0..<6).map { policy.delay(forAttempt: $0) } == [1, 2, 4, 4, 4, nil])
        #expect(policy.delay(forAttempt: -1) == nil)
        #expect(policy.stallThreshold == 8)
    }

    @Test func progressThrottle() {
        var throttle = ProgressThrottle(interval: 5)
        let r10 = throttle.shouldReport(at: 0); #expect(r10)
        let r11 = throttle.shouldReport(at: 4.9); #expect(!r11)
        let r12 = throttle.shouldReport(at: 5); #expect(r12)
        throttle.recordForced(at: 7)
        let r13 = throttle.shouldReport(at: 11); #expect(!r13)
        let r14 = throttle.shouldReport(at: 12); #expect(r14)
        throttle.reset()
        let r15 = throttle.shouldReport(at: 12.1); #expect(r15)
    }

    @Test func liveProgrammeProgress() {
        let start = Date(timeIntervalSince1970: 1_000)
        let programme = LiveProgramme(title: "JT", start: start, end: start.addingTimeInterval(100))
        #expect(programme.progress(at: start.addingTimeInterval(25)) == 0.25)
        #expect(programme.progress(at: start.addingTimeInterval(-10)) == 0)
        #expect(programme.progress(at: start.addingTimeInterval(500)) == 1)
    }
}
