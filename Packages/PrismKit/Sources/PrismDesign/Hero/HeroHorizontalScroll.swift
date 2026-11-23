import AppKit
import SwiftUI

/// Classifies a horizontal swipe once before committing a page. Vertical motion remains available
/// to the enclosing catalogue scroll view, and a fast swipe can only advance one page.
nonisolated struct HeroScrollGesture {
    private enum Axis { case undecided, horizontal, vertical }

    struct Change: Equatable {
        let consumesEvent: Bool
        let pageOffset: Int?
    }

    private var axis = Axis.undecided
    private var width: CGFloat = 0
    private var height: CGFloat = 0
    private var hasPaged = false

    var consumesMomentum: Bool { axis == .horizontal }

    mutating func add(horizontal: CGFloat, vertical: CGFloat) -> Change {
        width += horizontal
        height += vertical
        if axis == .undecided, max(abs(width), abs(height)) >= 7 {
            if abs(width) > abs(height) * 1.4 {
                axis = .horizontal
            } else if abs(height) >= abs(width) * 0.9 {
                axis = .vertical
            }
        }
        guard axis == .horizontal else { return Change(consumesEvent: false, pageOffset: nil) }
        guard !hasPaged, abs(width) >= 44 else { return Change(consumesEvent: true, pageOffset: nil) }
        hasPaged = true
        return Change(consumesEvent: true, pageOffset: width < 0 ? 1 : -1)
    }
}

/// Updated during layout without invalidating the carousel on every scroll frame.
final class HeroScrollHitRegion {
    var frame: CGRect = .zero

    func contains(_ point: CGPoint, in viewport: CGRect) -> Bool {
        viewport.contains(point) && frame.contains(point)
    }
}

/// An AppKit event monitor scoped to the visible hero in the key window. Its invisible view never
/// becomes a hit-test target, leaving buttons, links and vertical scrolling with SwiftUI.
struct HeroHorizontalScrollReader: NSViewRepresentable {
    let region: HeroScrollHitRegion
    let onPage: (Int) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.region = region
        view.onPage = onPage
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.region = region
        view.onPage = onPage
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var region: HeroScrollHitRegion?
        var onPage: ((Int) -> Void)?
        private var monitor: Any?
        private var gesture = HeroScrollGesture()
        private var isTracking = false
        private var lastUnphasedEvent: TimeInterval = -.infinity

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // AppKit delivers local monitors on the main thread. Return only the decision
                // from the isolated block since the original event is not Sendable.
                let consumesEvent = MainActor.assumeIsolated {
                    self?.shouldConsume(event) ?? false
                }
                return consumesEvent ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            gesture = HeroScrollGesture()
            isTracking = false
            lastUnphasedEvent = -.infinity
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func shouldConsume(_ event: NSEvent) -> Bool {
            guard let window, window.isKeyWindow, window.attachedSheet == nil, event.window === window else { return false }
            // SwiftUI clips a scrolling hero inside its hosting view; AppKit's visibleRect
            // alone does not reflect that clipping and may still cover a shelf below it.
            guard let contentView = window.contentView, let region else { return false }
            let point = contentView.convert(event.locationInWindow, from: nil)
            let bounds = contentView.bounds
            let position = CGPoint(
                x: point.x - bounds.minX,
                y: contentView.isFlipped ? point.y - bounds.minY : bounds.maxY - point.y
            )
            let viewport = CGRect(origin: .zero, size: bounds.size)
            let insideHero = region.contains(position, in: viewport)
            if !event.momentumPhase.isEmpty {
                let discard = insideHero && isTracking && gesture.consumesMomentum
                if !insideHero || event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                    isTracking = false
                }
                return discard
            }
            let phase = event.phase
            let deltaX = event.scrollingDeltaX
            let deltaY = event.scrollingDeltaY
            if phase.contains(.began) || phase.contains(.mayBegin) {
                isTracking = insideHero
                gesture = HeroScrollGesture()
            } else if phase.isEmpty {
                // Horizontal wheels and some mice send deltas without gesture phases.
                // A clear vertical turn returns scrolling to the surrounding page immediately.
                let turnedVertical = gesture.consumesMomentum && abs(deltaY) > abs(deltaX) * 1.4
                if event.timestamp - lastUnphasedEvent > 0.20 || !insideHero || turnedVertical {
                    isTracking = insideHero
                    gesture = HeroScrollGesture()
                }
                lastUnphasedEvent = event.timestamp
            }
            guard isTracking, insideHero, !phase.contains(.ended), !phase.contains(.cancelled) else { return false }

            let pointsPerUnit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            let change = gesture.add(
                horizontal: deltaX * pointsPerUnit,
                vertical: deltaY * pointsPerUnit
            )
            if let offset = change.pageOffset { onPage?(offset) }
            return change.consumesEvent
        }
    }
}
