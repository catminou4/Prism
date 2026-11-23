import SwiftUI

/// Full-width glass scrubber: elapsed · track (buffered + played + knob) · remaining / EN DIRECT.
/// Reads time updates in isolation, only while the transport controls are mounted.
struct PlayerScrubber: View {
    let controller: PlayerController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var dragFraction: Double?
    @State private var hoverFraction: Double?
    /// Hover tooltip doesn't need per-event updates: mouse-move events arrive at
    /// display rate (up to 120 Hz+) and each `hoverFraction` write re-evaluates the
    /// whole scrubber. ~30 Hz is indistinguishable for a 52 pt tooltip.
    @State private var lastHoverWrite = Date.distantPast
    private static let hoverWriteInterval: TimeInterval = 1.0 / 30

    private var isLive: Bool { controller.isLive }
    private var isSeekableLive: Bool { isLive && controller.timeshiftWindow != nil }
    private var forceHours: Bool { (controller.duration ?? 0) >= 3600 }
    /// VOD whose duration is not known yet (loading): bare track, no labels/knob.
    private var isUnknownVOD: Bool { !isLive && (controller.duration ?? 0) <= 0 }

    var body: some View {
        HStack(spacing: 10.5) {
            leadingLabel
            track
            trailingLabel
        }
        .padding(.horizontal, PlayerMetrics.scrubberPadding)
        .frame(height: PlayerMetrics.scrubberHeight)
        .frame(maxWidth: .infinity)
        .playerGlass(Capsule())
        .onChange(of: dragFraction != nil) { _, dragging in controller.setScrubbing(dragging) }
        .onDisappear {
            if controller.isScrubbing { controller.setScrubbing(false) }
        }
    }

    // MARK: Labels

    @ViewBuilder private var leadingLabel: some View {
        if isUnknownVOD {
            EmptyView()
        } else if isLive, !isSeekableLive {
            if let programme = controller.liveProgramme {
                timeText(PlayerFormat.clockTime(programme.start))
            }
        } else if isSeekableLive, let window = controller.timeshiftWindow {
            timeText("-" + PlayerFormat.timecode(window.upperBound - displayedTime))
        } else {
            timeText(PlayerFormat.timecode(displayedTime, forceHours: forceHours))
        }
    }

    @ViewBuilder private var trailingLabel: some View {
        if isLive {
            HStack(spacing: 8) {
                if !isSeekableLive, let programme = controller.liveProgramme {
                    timeText(PlayerFormat.clockTime(programme.end))
                }
                if isSeekableLive {
                    Button {
                        controller.seekToLiveEdge()
                    } label: {
                        PlayerLiveBadge(dimmed: controller.isBehindLiveEdge)
                    }
                    .buttonStyle(.plain)
                    .help(controller.isBehindLiveEdge ? "Revenir au direct" : "En direct")
                } else {
                    PlayerLiveBadge()
                }
            }
        } else if !isUnknownVOD {
            timeText(PlayerFormat.remaining(current: displayedTime, duration: controller.duration ?? 0))
        }
    }

    private func timeText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: PlayerMetrics.timeFontSize, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.78))
            .lineLimit(1)
            .fixedSize()
    }

    // MARK: Time mapping

    private var seekable: Bool { controller.canSeek }

    /// Time shown in the labels (drag preview while scrubbing).
    private var displayedTime: TimeInterval {
        if let dragFraction { return time(at: dragFraction) }
        return controller.currentTime
    }

    private func time(at fraction: Double) -> TimeInterval {
        if let window = controller.timeshiftWindow, isLive {
            return window.lowerBound + fraction * (window.upperBound - window.lowerBound)
        }
        return fraction * (controller.duration ?? 0)
    }

    // MARK: Track

    private var track: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            ZStack(alignment: .leading) {
                if isUnknownVOD {
                    bars(width: width, played: 0, buffered: 0)
                } else if isLive, !isSeekableLive {
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        bars(width: width, played: controller.playbackFraction(at: context.date), buffered: 0)
                    }
                } else {
                    let played = dragFraction ?? controller.playbackFraction()
                    bars(width: width, played: played, buffered: max(played, controller.bufferedFraction))
                    knob
                        .offset(x: played * width - PlayerMetrics.knobSize.width / 2)
                }
                if seekable, let hoverFraction, dragFraction == nil {
                    tooltip(PlayerFormat.timecode(time(at: hoverFraction), forceHours: forceHours))
                        .offset(x: hoverFraction * width - 26, y: -30)
                        .allowsHitTesting(false)
                } else if let dragFraction {
                    tooltip(PlayerFormat.timecode(time(at: dragFraction), forceHours: forceHours))
                        .offset(x: dragFraction * width - 26, y: -30)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: geo.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    if seekable {
                        let now = Date()
                        guard now.timeIntervalSince(lastHoverWrite) >= Self.hoverWriteInterval
                        else { return }
                        lastHoverWrite = now
                        hoverFraction = min(1, max(0, location.x / width))
                    }
                case .ended:
                    hoverFraction = nil
                    lastHoverWrite = .distantPast
                }
            }
            .gesture(seekable ? dragGesture(width: width) : nil)
        }
        .frame(height: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Position de lecture")
        .accessibilityValue(seekable ? PlayerFormat.timecode(displayedTime, forceHours: forceHours) : "")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: controller.skip(by: 10)
            case .decrement: controller.skip(by: -10)
            @unknown default: break
            }
        }
        .accessibilityHidden(!seekable)
    }

    private func bars(width: CGFloat, played: Double, buffered: Double) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.18))
                .frame(width: width, height: PlayerMetrics.trackHeight)
            if buffered > 0 {
                Capsule().fill(.white.opacity(0.35))
                    .frame(width: max(PlayerMetrics.trackHeight, buffered * width), height: PlayerMetrics.trackHeight)
            }
            Capsule().fill(.white)
                .frame(width: max(PlayerMetrics.trackHeight, played * width), height: PlayerMetrics.trackHeight)
        }
    }

    private var knob: some View {
        Capsule()
            .fill(Color(white: 0.87))
            .frame(width: PlayerMetrics.knobSize.width, height: PlayerMetrics.knobSize.height)
            .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
            .scaleEffect(dragFraction == nil || reduceMotion ? 1 : 1.12)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: dragFraction == nil)
    }

    private func tooltip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: 52, height: 22)
            .playerGlass(Capsule())
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($dragFraction) { value, fraction, _ in
                fraction = min(1, max(0, value.location.x / width))
            }
            .onEnded { value in
                let fraction = min(1, max(0, value.location.x / width))
                controller.seek(to: time(at: fraction))
            }
    }
}

/// Native volume slider and mute toggle inside the transport glass.
struct PlayerVolumeControl: View {
    let controller: PlayerController
    @State private var isAdjusting = false

    private var volume: Binding<Float> {
        Binding(
            get: { controller.isMuted ? 0 : controller.volume },
            set: { value in
                controller.noteUserActivity()
                controller.setVolume(value, save: !isAdjusting)
            }
        )
    }

    var body: some View {
        HStack(spacing: 11) {
            Slider(value: volume, in: 0...1) { adjusting in
                isAdjusting = adjusting
                if !adjusting { controller.saveVolume() }
            } label: {
                Text("Volume")
            }
            .labelsHidden()
            .controlSize(.small)
            .tint(.white)
            .frame(width: PlayerMetrics.volumeSliderWidth)
            .accessibilityValue(controller.isMuted ? "Muet" : "\(Int(controller.volume * 100)) %")

            Button {
                controller.toggleMute()
            } label: {
                Image(
                    systemName: controller.isMuted || controller.volume == 0
                        ? "speaker.slash.fill" : "speaker.wave.3.fill",
                    variableValue: Double(controller.volume)
                )
                .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PlayerCapsuleButtonStyle(width: 27))
            .help(controller.isMuted ? "Réactiver le son (M)" : "Couper le son (M)")
        }
        .padding(.leading, 15)
        .padding(.trailing, 10)
        .frame(height: PlayerMetrics.capsuleHeight)
        .playerGlass(Capsule())
    }
}
