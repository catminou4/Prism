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

/// An AppKit event monitor scoped to the visible hero in the key window. Its invisible view never
/// becomes a hit-test target, leaving buttons, links and vertical scrolling with SwiftUI.
struct HeroHorizontalScrollReader: NSViewRepresentable {
    let onPage: (Int) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onPage = onPage
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onPage = onPage
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
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
            if !event.momentumPhase.isEmpty {
                let discard = isTracking && gesture.consumesMomentum
                if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                    isTracking = false
                }
                return discard
            }

            let insideHero = visibleRect.contains(convert(event.locationInWindow, from: nil))
            let phase = event.phase
            if phase.contains(.began) || phase.contains(.mayBegin) {
                isTracking = insideHero
                gesture = HeroScrollGesture()
            } else if phase.isEmpty {
                // Horizontal wheels and some mice send deltas without gesture phases.
                if event.timestamp - lastUnphasedEvent > 0.20 || !insideHero {
                    isTracking = insideHero
                    gesture = HeroScrollGesture()
                }
                lastUnphasedEvent = event.timestamp
            }
            guard isTracking, insideHero, !phase.contains(.ended), !phase.contains(.cancelled) else { return false }

            let pointsPerUnit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            let change = gesture.add(
                horizontal: event.scrollingDeltaX * pointsPerUnit,
                vertical: event.scrollingDeltaY * pointsPerUnit
            )
            if let offset = change.pageOffset { onPage?(offset) }
            return change.consumesEvent
        }
    }
}
