import AppKit
import SwiftUI

/// Weak handle on the player window (fullscreen toggling from keyboard/double-click).
@Observable
public final class PlayerWindowHandle {
    public internal(set) weak var window: NSWindow?
    public internal(set) var isFullScreen = false

    public init() {}

    public func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }
}

/// Configures the hosting window like the Apple TV player: transparent title bar, full-size
/// content, black background, fullscreen-primary, Mission Control title = item title, traffic
/// lights fading with the controls and (optionally) a locked aspect ratio.
public struct PlayerWindowConfigurator: NSViewRepresentable {
    var title: String
    var controlsVisible: Bool
    var aspectRatio: CGSize?
    var handle: PlayerWindowHandle?

    /// - Parameters:
    ///   - aspectRatio: video size to keep while resizing, nil = free resizing.
    public init(title: String, controlsVisible: Bool, aspectRatio: CGSize? = nil, handle: PlayerWindowHandle? = nil) {
        self.title = title
        self.controlsVisible = controlsVisible
        self.aspectRatio = aspectRatio
        self.handle = handle
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> NSView {
        let view = WindowObservingView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        context.coordinator.configuration = self
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.configuration = self
        context.coordinator.apply()
    }

    public final class Coordinator {
        var configuration: PlayerWindowConfigurator?
        private weak var window: NSWindow?
        private var tokens: [any NSObjectProtocol] = []
        private var lastControlsVisible: Bool?
        private var lastAspect: CGSize?

        init() {}

        isolated deinit {
            for token in tokens { NotificationCenter.default.removeObserver(token) }
        }

        func attach(to newWindow: NSWindow?) {
            guard newWindow !== window else { return }
            for token in tokens { NotificationCenter.default.removeObserver(token) }
            tokens = []
            window = newWindow
            lastControlsVisible = nil
            lastAspect = nil
            guard let newWindow else { return }
            newWindow.titlebarAppearsTransparent = true
            newWindow.titleVisibility = .hidden
            newWindow.styleMask.insert(.fullSizeContentView)
            newWindow.backgroundColor = .black
            newWindow.collectionBehavior.insert(.fullScreenPrimary)
            newWindow.isMovableByWindowBackground = false
            newWindow.appearance = NSAppearance(named: .darkAqua)
            let center = NotificationCenter.default
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                tokens.append(
                    center.addObserver(forName: name, object: newWindow, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.updateFullScreenState() }
                    })
            }
            if let handle = configuration?.handle, handle.window !== newWindow { handle.window = newWindow }
            updateFullScreenState()
            apply()
        }

        func apply() {
            guard let window, let configuration else { return }
            if let handle = configuration.handle, handle.window !== window { handle.window = window }
            if window.title != configuration.title { window.title = configuration.title }
            if lastControlsVisible != configuration.controlsVisible {
                let animate = lastControlsVisible != nil
                lastControlsVisible = configuration.controlsVisible
                setTrafficLights(visible: configuration.controlsVisible, animated: animate)
            }
            if lastAspect != configuration.aspectRatio {
                lastAspect = configuration.aspectRatio
                if let ratio = configuration.aspectRatio, ratio.width > 0, ratio.height > 0 {
                    window.contentAspectRatio = ratio
                } else {
                    window.resizeIncrements = NSSize(width: 1, height: 1)
                }
            }
        }

        private func setTrafficLights(visible: Bool, animated: Bool) {
            guard let window else { return }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animated ? PlayerMetrics.controlsFade : 0
                context.allowsImplicitAnimation = true
                for button in buttons {
                    (animated ? button.animator() : button).alphaValue = visible ? 1 : 0
                }
            }
        }

        private func updateFullScreenState() {
            let isFullScreen = window?.styleMask.contains(.fullScreen) ?? false
            if configuration?.handle?.isFullScreen != isFullScreen {
                configuration?.handle?.isFullScreen = isFullScreen
            }
        }
    }
}

/// Reports the window it is attached to.
private final class WindowObservingView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
