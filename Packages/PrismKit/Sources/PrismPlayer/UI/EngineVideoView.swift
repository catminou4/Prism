import AVFoundation
import AVKit
import AppKit
import SwiftUI

/// Hosts the controller's video container (current engine view + the retiring one that keeps
/// its last frame). The container is black and layer-backed: swapping engines never flashes.
struct EngineVideoView: NSViewRepresentable {
    let controller: PlayerController

    func makeNSView(context: Context) -> NSView {
        let host = VideoHostView()
        host.attach(controller.videoContainer)
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? VideoHostView)?.attach(controller.videoContainer)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? VideoHostView)?.detach()
    }
}

/// Black wrapper so the shared container can move between SwiftUI hierarchies.
private final class VideoHostView: NSView {
    private weak var container: NSView?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func attach(_ view: NSView) {
        guard view.superview !== self else { return }
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        container = view
    }

    func detach() {
        if container?.superview === self { container?.removeFromSuperview() }
    }
}

/// AirPlay button: system `AVRoutePickerView` (transparent) under the `airplayvideo` symbol so
/// it matches the other capsule buttons.
struct PlayerAirPlayButton: View {
    let player: AVPlayer?
    @Environment(\.playerSnapshotRendering) private var snapshot
    @State private var hovering = false

    var body: some View {
        ZStack {
            Capsule()
                .fill(.white.opacity(hovering ? 0.14 : 0))
            if !snapshot {
                RoutePickerRepresentable(player: player)
            }
            Image(systemName: "airplayvideo")
                .font(.system(size: PlayerMetrics.capsuleSymbolSize, weight: .medium))
                .foregroundStyle(.white)
                .allowsHitTesting(false)
        }
        .frame(
            width: PlayerMetrics.capsuleButtonWidth,
            height: PlayerMetrics.capsuleHeight - 2 * PlayerMetrics.capsulePadding)
        .onHover { hovering = $0 }
        .help("AirPlay")
        .accessibilityLabel("AirPlay")
    }
}

private struct RoutePickerRepresentable: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView(frame: NSRect(x: 0, y: 0, width: 30, height: 24))
        picker.isRoutePickerButtonBordered = false
        for state in [
            AVRoutePickerView.ButtonState.normal, .normalHighlighted, .active, .activeHighlighted,
        ] {
            picker.setRoutePickerButtonColor(.clear, for: state)
        }
        picker.player = player
        return picker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}
