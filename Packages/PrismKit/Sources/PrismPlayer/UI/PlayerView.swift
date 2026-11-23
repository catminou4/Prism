import AppKit
import Combine
import SwiftUI

/// Apple TV–style player (macOS 26): black stage, auto-hiding Liquid Glass controls, native
/// menus, keyboard shortcuts and optional slots.
///
/// Slots (all optional):
/// - `infoAccessory`: card above the title row (live "now / next").
/// - `sidePanel`: trailing glass panel (340 pt) toggled by `list.bullet` or `L` (channel list,
///   episodes).
/// - `upNext`: VOD card shown bottom-right during the last 30 s (see `PlayerUpNextCard`).
public struct PlayerView<InfoAccessory: View, SidePanel: View, UpNext: View>: View {
    let controller: PlayerController
    let sourceOptions: [PlayerSourceOption]
    let configuresWindow: Bool
    let stopsOnDisappear: Bool
    let onClose: (() -> Void)?
    let onShare: (() -> Void)?
    let onChannelUp: (() -> Void)?
    let onChannelDown: (() -> Void)?
    let infoAccessory: InfoAccessory
    let sidePanel: SidePanel
    let upNext: UpNext

    @State private var windowHandle = PlayerWindowHandle()
    @State private var isSidePanelOpen = false
    @State private var isInfoVisible = false
    @State private var isPointerInside = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.playerSnapshotRendering) private var snapshot

    /// - Parameters:
    ///   - sourceOptions: variants for the `rectangle.stack` menu and the error card (shown when > 1).
    ///   - configuresWindow: applies `PlayerWindowConfigurator` to the hosting window (dedicated
    ///     player window). Pass false when embedding the player in another window.
    ///   - stopsOnDisappear: calls `controller.stop()` when the view goes away.
    ///   - onClose: adds a close (`xmark`) button and makes Esc close the player when windowed.
    ///   - onChannelUp/onChannelDown: ↑/↓ zap instead of changing the volume.
    public init(
        controller: PlayerController,
        sourceOptions: [PlayerSourceOption] = [],
        configuresWindow: Bool = true,
        stopsOnDisappear: Bool = true,
        onClose: (() -> Void)? = nil,
        onShare: (() -> Void)? = nil,
        onChannelUp: (() -> Void)? = nil,
        onChannelDown: (() -> Void)? = nil,
        @ViewBuilder infoAccessory: () -> InfoAccessory,
        @ViewBuilder sidePanel: () -> SidePanel,
        @ViewBuilder upNext: () -> UpNext
    ) {
        self.controller = controller
        self.sourceOptions = sourceOptions
        self.configuresWindow = configuresWindow
        self.stopsOnDisappear = stopsOnDisappear
        self.onClose = onClose
        self.onShare = onShare
        self.onChannelUp = onChannelUp
        self.onChannelDown = onChannelDown
        self.infoAccessory = infoAccessory()
        self.sidePanel = sidePanel()
        self.upNext = upNext()
    }

    /// Snapshot/preview helper: initial panel and info overlay state.
    func previewing(sidePanelOpen: Bool = false, infoVisible: Bool = false) -> Self {
        var copy = self
        copy._isSidePanelOpen = State(initialValue: sidePanelOpen)
        copy._isInfoVisible = State(initialValue: infoVisible)
        return copy
    }

    private var hasSidePanel: Bool { SidePanel.self != EmptyView.self }
    private var hasInfoAccessory: Bool { InfoAccessory.self != EmptyView.self }
    private var hasUpNext: Bool { UpNext.self != EmptyView.self }

    private var topInset: CGFloat {
        windowHandle.isFullScreen || !configuresWindow ? PlayerMetrics.margin : PlayerMetrics.windowedTopInset
    }

    private var failureMessage: String? {
        if case .failed(let message) = controller.phase { return message }
        return nil
    }

    private var fade: Animation {
        .easeInOut(duration: PlayerMetrics.controlsFade)
    }

    public var body: some View {
        ZStack {
            Color.black
            EngineVideoView(controller: controller)
            videoInteractionLayer
            loadingLayer
            controlsLayer
        }
        // Secondary layers are overlays so their content can never resize the stage.
        .overlay { hudLayer }
        .overlay { errorLayer }
        .overlay(alignment: .topLeading) { infoLayer }
        .overlay(alignment: .bottomTrailing) { upNextLayer }
        .overlay(alignment: .trailing) { sidePanelLayer }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .background {
            if configuresWindow, !snapshot {
                PlayerWindowConfigurator(
                    title: controller.item.title,
                    controlsVisible: controller.controlsVisible,
                    aspectRatio: controller.preferences.keepsWindowAspectRatio ? controller.videoSize : nil,
                    handle: windowHandle)
            }
        }
        // `.edit` interactions: focusable regardless of the "keyboard navigation" setting.
        .focusable(interactions: .edit)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in handleKey(press) }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if !isPointerInside { isPointerInside = true }
                controller.pointerMoved()
            case .ended:
                if isPointerInside { isPointerInside = false }
                controller.pointerExited()
            }
        }
        .onChange(of: controller.controlsVisible) { _, visible in
            if !visible, isPointerInside, !snapshot { NSCursor.setHiddenUntilMouseMoves(true) }
        }
        .onChange(of: isSidePanelOpen) { _, open in controller.setPanelOpen(open) }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            controller.setMenuOpen(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            controller.setMenuOpen(false)
        }
        .onAppear {
            if !snapshot { controller.start() }
        }
        .task {
            isFocused = true
        }
        .onDisappear {
            if stopsOnDisappear, !snapshot { controller.stop() }
        }
    }

    // MARK: - Layers

    private var videoInteractionLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { windowHandle.toggleFullScreen() }
            .onTapGesture {
                isFocused = true
                controller.noteUserActivity()
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var loadingLayer: some View {
        let dimmed = controller.isLoading || failureMessage != nil
        Color.black
            .opacity(dimmed ? (failureMessage != nil ? 0.55 : 0.35) : 0)
            .allowsHitTesting(false)
            .animation(fade, value: dimmed)
        if controller.isLoading, failureMessage == nil {
            PlayerLoadingOverlay(message: controller.statusMessage)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
        if controller.isPictureInPictureActive {
            VStack(spacing: 10) {
                Image(systemName: "pip")
                    .font(.system(size: 44, weight: .light))
                Text("Lecture en Image dans l’image")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.55))
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private var controlsLayer: some View {
        ZStack {
            if controller.controlsVisible {
                transportControls
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(controller.controlsVisible)
        .accessibilityHidden(!controller.controlsVisible)
        .animation(fade, value: controller.controlsVisible)
    }

    private var transportControls: some View {
        let showsTransport = !controller.isLoading && failureMessage == nil
        return VStack(spacing: 0) {
            topBar
            Spacer(minLength: 12)
            bottomBlock
        }
        .padding(.horizontal, PlayerMetrics.margin)
        .padding(.top, topInset)
        .padding(.bottom, PlayerMetrics.bottomMargin)
        .overlay {
            centerCluster
                .opacity(showsTransport ? 1 : 0)
                .allowsHitTesting(showsTransport)
                .accessibilityHidden(!showsTransport)
                .animation(fade, value: showsTransport)
        }
        .background {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.58), location: 0),
                    .init(color: .clear, location: 0.22),
                    .init(color: .clear, location: 0.62),
                    .init(color: .black.opacity(0.82), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: Top

    private var topBar: some View {
        HStack(alignment: .top, spacing: PlayerMetrics.margin) {
            topLeadingCapsule
            Spacer(minLength: 0)
            PlayerVolumeControl(controller: controller)
                .onHover { controller.setHoveringControls($0) }
        }
        .overlay(alignment: .top) {
            if controller.isLive, !hasInfoAccessory, let secondary = controller.secondaryTitle, !secondary.isEmpty {
                Text(secondary)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: PlayerMetrics.capsuleHeight)
                    .padding(.horizontal, 200)
                    .allowsHitTesting(false)
            }
        }
    }

    private var topLeadingCapsule: some View {
        PlayerGlassCapsule {
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(PlayerCapsuleButtonStyle())
                    .help("Fermer")
                    .accessibilityLabel("Fermer")
            }
            if controller.isPictureInPictureSupported {
                Button {
                    controller.togglePictureInPicture()
                } label: {
                    Image(systemName: controller.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PlayerCapsuleButtonStyle())
                .help("Image dans l’image")
                .accessibilityLabel("Image dans l’image")
            }
            PlayerAirPlayButton(player: controller.routingPlayer)
            if let onShare {
                Button(action: onShare) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(PlayerCapsuleButtonStyle())
                    .help("Partager")
                    .accessibilityLabel("Partager")
            }
        }
        .onHover { controller.setHoveringControls($0) }
    }

    // MARK: Center

    private var centerCluster: some View {
        let showsSkip = controller.canSeek
        return GlassEffectContainer(spacing: 8) {
            HStack(spacing: PlayerMetrics.centerSpacing) {
                if showsSkip {
                    skipButton(-10)
                }
                Button {
                    controller.togglePlayPause()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: PlayerMetrics.playSymbolSize, weight: .medium))
                        .contentTransition(.symbolEffect(.replace))
                        .offset(x: controller.isPlaying ? 0 : 1.5)
                }
                .buttonStyle(PlayerTransportButtonStyle(diameter: PlayerMetrics.playDiameter))
                .help(controller.isPlaying ? "Pause (espace)" : "Lecture (espace)")
                .accessibilityLabel(controller.isPlaying ? "Pause" : "Lecture")
                if showsSkip {
                    skipButton(10)
                }
            }
            .onHover { controller.setHoveringControls($0) }
        }
    }

    private func skipButton(_ seconds: Int) -> some View {
        Button {
            controller.skip(by: TimeInterval(seconds))
        } label: {
            Image(systemName: seconds < 0 ? "gobackward.10" : "goforward.10")
                .font(.system(size: PlayerMetrics.skipSymbolSize, weight: .medium))
        }
        .buttonStyle(PlayerTransportButtonStyle(diameter: PlayerMetrics.skipDiameter))
        .overlay(alignment: .top) {
            if case .skip(let skipped)? = controller.feedback?.kind, (skipped < 0) == (seconds < 0) {
                PlayerSkipBubble(seconds: skipped)
                    .fixedSize()
                    .offset(y: -40)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
                    .id(controller.feedback?.id)
            }
        }
        .animation(.smooth(duration: 0.25), value: controller.feedback?.id)
        .help(seconds < 0 ? "Reculer de 10 s (←)" : "Avancer de 10 s (→)")
        .accessibilityLabel(seconds < 0 ? "Reculer de 10 secondes" : "Avancer de 10 secondes")
    }

    // MARK: Bottom

    private var bottomBlock: some View {
        VStack(alignment: .leading, spacing: PlayerMetrics.rowSpacing) {
            if hasInfoAccessory {
                infoAccessory
                    .onHover { controller.setHoveringControls($0) }
            }
            HStack(alignment: .bottom, spacing: PlayerMetrics.margin) {
                titleBlock
                Spacer(minLength: 0)
                bottomTrailingCapsule
            }
            PlayerScrubber(controller: controller)
                .onHover { controller.setHoveringControls($0) }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(controller.item.title)
                .font(.system(size: PlayerMetrics.titleSize, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if !controller.isLive, let subtitle = controller.item.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
    }

    private var bottomTrailingCapsule: some View {
        PlayerGlassCapsule {
            PlayerMenuButton(systemImage: "captions.bubble", help: "Sous-titres") {
                SubtitlesMenuContent(controller: controller)
            }
            PlayerMenuButton(systemImage: "waveform", help: "Audio") {
                AudioMenuContent(controller: controller)
            }
            PlayerMenuButton(systemImage: "gauge.with.dots.needle.67percent", help: "Vitesse et format") {
                SpeedMenuContent(controller: controller)
            }
            if sourceOptions.count > 1 {
                PlayerMenuButton(systemImage: "rectangle.stack", help: "Source") {
                    SourceMenuContent(options: sourceOptions)
                }
            }
            if hasSidePanel {
                Button {
                    toggleSidePanel()
                } label: {
                    Image(systemName: "list.bullet")
                }
                .buttonStyle(PlayerCapsuleButtonStyle())
                .help("Liste (L)")
                .accessibilityLabel("Liste")
            }
        }
        .onHover { controller.setHoveringControls($0) }
    }

    // MARK: HUD, error, info, up next, panel

    @ViewBuilder private var hudLayer: some View {
        ZStack {
            if let feedback = controller.feedback {
                switch feedback.kind {
                case .volume, .message:
                    PlayerHUD(kind: feedback.kind)
                        .fixedSize()
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92)))
                case .skip:
                    EmptyView()
                }
            }
        }
        .offset(y: -(PlayerMetrics.playDiameter / 2 + 56))
        .allowsHitTesting(false)
        .animation(.smooth(duration: 0.25), value: controller.feedback)
    }

    @ViewBuilder private var errorLayer: some View {
        if let failureMessage {
            PlayerErrorCard(
                message: failureMessage, sourceOptions: sourceOptions,
                onRetry: { controller.retry() }, onClose: onClose
            )
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
        }
    }

    @ViewBuilder private var infoLayer: some View {
        if isInfoVisible {
            PlayerStreamInfoCard(controller: controller) {
                withAnimation(fade) { isInfoVisible = false }
            }
            .padding(.top, topInset + PlayerMetrics.capsuleHeight + 12)
            .padding(.leading, PlayerMetrics.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transition(.opacity)
        }
    }

    @ViewBuilder private var upNextLayer: some View {
        if hasUpNext {
            PlayerUpNextHost(controller: controller) { upNext }
                .padding(.trailing, PlayerMetrics.margin)
                .padding(
                    .bottom,
                    PlayerMetrics.bottomMargin + PlayerMetrics.scrubberHeight + PlayerMetrics.rowSpacing
                        + PlayerMetrics.capsuleHeight + 12
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    @ViewBuilder private var sidePanelLayer: some View {
        if hasSidePanel, isSidePanelOpen {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { toggleSidePanel() }
                .accessibilityHidden(true)
            sidePanel
                .frame(width: PlayerMetrics.sidePanelWidth)
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: PlayerMetrics.panelRadius, style: .continuous))
                .playerGlass(RoundedRectangle(cornerRadius: PlayerMetrics.panelRadius, style: .continuous))
                // Between the top bar and the bottom-right capsule: every control stays reachable.
                .padding(.top, topInset + PlayerMetrics.capsuleHeight + 12)
                .padding(
                    .bottom,
                    PlayerMetrics.bottomMargin + PlayerMetrics.scrubberHeight + PlayerMetrics.rowSpacing
                        + PlayerMetrics.capsuleHeight + 12
                )
                .padding(.trailing, PlayerMetrics.margin)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
        }
    }

    private func toggleSidePanel() {
        withAnimation(reduceMotion ? fade : .smooth(duration: 0.35)) {
            isSidePanelOpen.toggle()
        }
    }

    // MARK: - Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard !press.modifiers.contains(.command) else { return .ignored }
        let isRepeat = press.phase == .repeat
        controller.noteUserActivity()
        switch press.key {
        case .space:
            if !isRepeat { controller.togglePlayPause() }
            return .handled
        case .leftArrow:
            if !isRepeat { controller.skip(by: -10) }
            return .handled
        case .rightArrow:
            if !isRepeat { controller.skip(by: 10) }
            return .handled
        case .upArrow:
            if let onChannelUp {
                if !isRepeat { onChannelUp() }
            } else {
                controller.setVolume(controller.volume + 0.1, showHUD: true)
            }
            return .handled
        case .downArrow:
            if let onChannelDown {
                if !isRepeat { onChannelDown() }
            } else {
                controller.setVolume(controller.volume - 0.1, showHUD: true)
            }
            return .handled
        case .escape:
            return handleEscape() ? .handled : .ignored
        default:
            break
        }
        guard !isRepeat else { return .ignored }
        switch press.characters.lowercased() {
        case "f":
            windowHandle.toggleFullScreen()
        case "m":
            controller.toggleMute()
        case "s":
            controller.cycleSubtitles()
        case "l":
            guard hasSidePanel else { return .ignored }
            toggleSidePanel()
        case "i":
            withAnimation(fade) { isInfoVisible.toggle() }
        default:
            return .ignored
        }
        return .handled
    }

    private func handleEscape() -> Bool {
        if isInfoVisible {
            withAnimation(fade) { isInfoVisible = false }
        } else if isSidePanelOpen {
            toggleSidePanel()
        } else if windowHandle.isFullScreen {
            windowHandle.toggleFullScreen()
        } else if let onClose {
            onClose()
        } else {
            return false
        }
        return true
    }
}

/// Shows the `upNext` slot during the last 30 s of a VOD item (reads the 4 Hz clock in isolation).
private struct PlayerUpNextHost<Content: View>: View {
    let controller: PlayerController
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isVisible: Bool {
        guard !controller.isLive, let duration = controller.duration, duration > 60,
            let remaining = controller.remainingTime
        else { return false }
        return remaining <= 30 && (remaining > 0 || controller.phase == .ended)
    }

    var body: some View {
        ZStack {
            if isVisible {
                content
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.35), value: isVisible)
    }
}

// MARK: - Convenience initializers

extension PlayerView where InfoAccessory == EmptyView, SidePanel == EmptyView, UpNext == EmptyView {
    /// Player without slots.
    public init(
        controller: PlayerController,
        sourceOptions: [PlayerSourceOption] = [],
        configuresWindow: Bool = true,
        onClose: (() -> Void)? = nil,
        onShare: (() -> Void)? = nil,
        onChannelUp: (() -> Void)? = nil,
        onChannelDown: (() -> Void)? = nil
    ) {
        self.init(
            controller: controller, sourceOptions: sourceOptions, configuresWindow: configuresWindow,
            onClose: onClose, onShare: onShare, onChannelUp: onChannelUp, onChannelDown: onChannelDown,
            infoAccessory: { EmptyView() }, sidePanel: { EmptyView() }, upNext: { EmptyView() })
    }
}

extension PlayerView where UpNext == EmptyView {
    /// Live TV: programme card + channel list panel.
    public init(
        controller: PlayerController,
        sourceOptions: [PlayerSourceOption] = [],
        configuresWindow: Bool = true,
        onClose: (() -> Void)? = nil,
        onShare: (() -> Void)? = nil,
        onChannelUp: (() -> Void)? = nil,
        onChannelDown: (() -> Void)? = nil,
        @ViewBuilder infoAccessory: () -> InfoAccessory,
        @ViewBuilder sidePanel: () -> SidePanel
    ) {
        self.init(
            controller: controller, sourceOptions: sourceOptions, configuresWindow: configuresWindow,
            onClose: onClose, onShare: onShare, onChannelUp: onChannelUp, onChannelDown: onChannelDown,
            infoAccessory: infoAccessory, sidePanel: sidePanel, upNext: { EmptyView() })
    }
}

extension PlayerView where InfoAccessory == EmptyView {
    /// VOD / series: episode list panel + "Épisode suivant" card.
    public init(
        controller: PlayerController,
        sourceOptions: [PlayerSourceOption] = [],
        configuresWindow: Bool = true,
        onClose: (() -> Void)? = nil,
        onShare: (() -> Void)? = nil,
        @ViewBuilder sidePanel: () -> SidePanel,
        @ViewBuilder upNext: () -> UpNext
    ) {
        self.init(
            controller: controller, sourceOptions: sourceOptions, configuresWindow: configuresWindow,
            onClose: onClose, onShare: onShare, infoAccessory: { EmptyView() }, sidePanel: sidePanel,
            upNext: upNext)
    }
}
