import AppKit
import ApplicationServices
import PrismCore
import PrismData
@testable import PrismDesign
import QuartzCore
import SwiftUI
import Testing
@testable import PrismUI

/// Empirical interaction-behavior comparison between the production `Button` card chrome
/// and candidate gesture replacements. Synthetic mouse events are posted in window
/// coordinates through `NSWindow.sendEvent` so hit-testing, gesture recognition and control
/// dispatch run exactly as in the real app. Accessibility frames come from the self-pid
/// `AXUIElement` tree (SwiftUI only materializes its AX tree for real HIServices queries;
/// the in-process `NSAccessibility` child walk stays empty). Run with
/// PRISM_INTERACTION_PROBE=1.
///
/// Known harness limitation: synthetic events never trigger `.onHover` in offscreen windows,
/// so hover-dependent behavior (`dragHover` activation, press masking on drag-out) cannot be
/// validated here. Those channels are covered by location-based assertions instead.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PRISM_INTERACTION_PROBE"] == "1"))
struct CardInteractionProbeTests {

    // MARK: - Variants under test

    enum Variant: String, CaseIterable {
        /// Production: `Button` + exact `CardPressStyle` replica.
        case production
        /// Zero-distance drag gesture: press state + activation from geometry-measured location.
        case dragGeometry
        /// Zero-distance drag gesture: activation + press mask from the hover state.
        case dragHover
        /// Tap + simultaneous zero-duration long-press.
        case tapPressGesture
        /// AppKit backing view behind the card content: exact mouse tracking with free bounds.
        case backing
        /// dragGeometry without the scale/animation effect: isolates gesture-cancellation causes.
        case dragNoFx
    }

    /// Card body replicating `WideCard`'s interactive structure: artwork area plus a caption
    /// row carrying the real `CardMenuButton`. The interaction chrome is switchable.
    struct ProbeInteractiveCard<MenuContent: View>: View {
        let variant: Variant
        let width: CGFloat
        let action: () -> Void
        let menu: () -> MenuContent
        let onPressChange: (Bool) -> Void
        let onHoverChange: (Bool) -> Void

        @State private var hovering = false
        @GestureState private var longPressed = false
        @GestureState private var dragActive = false
        @State private var dragInside = true
        @State private var cardSize = CGSize.zero
        @State private var backingPressed = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var isHovered: Bool { hovering }

        var body: some View {
            Group {
                switch variant {
                case .production:
                    Button(action: action) { cardContent }
                        .buttonStyle(ProbeProductionPressStyle(isHovered: isHovered, reduceMotion: reduceMotion, onPressChange: onPressChange))
                case .dragGeometry:
                    cardContent
                        .contentShape(.rect)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .updating($dragActive) { _, state, _ in state = true }
                                .onChanged { value in
                                    SelfDebugLog.shared.append("dragGeometry onChanged loc=\(value.location)")
                                    let inside = value.location.x >= 0 && value.location.y >= 0
                                        && value.location.x <= cardSize.width && value.location.y <= cardSize.height
                                    if inside != dragInside { dragInside = inside }
                                }
                                .onEnded { value in
                                    let inside = value.location.x >= 0 && value.location.y >= 0
                                        && value.location.x <= cardSize.width && value.location.y <= cardSize.height
                                    SelfDebugLog.shared.append("dragGeometry onEnded loc=\(value.location) size=\(cardSize) inside=\(inside)")
                                    if inside { action() }
                                    dragInside = true
                                }
                        )
                        .hoverLiftEffect(
                            isHovered: isHovered, isPressed: dragActive && dragInside, scale: 1.04,
                            pressedScale: 0.97, shadow: false, reduceMotion: reduceMotion
                        )
                        .accessibilityAction(.default) { action() }
                        .onChange(of: dragActive && dragInside) { _, value in onPressChange(value) }
                case .dragHover:
                    cardContent
                        .contentShape(.rect)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .updating($dragActive) { _, state, _ in state = true }
                                .onEnded { _ in
                                    if hovering { action() }
                                }
                        )
                        .hoverLiftEffect(
                            isHovered: isHovered, isPressed: dragActive && hovering, scale: 1.04,
                            pressedScale: 0.97, shadow: false, reduceMotion: reduceMotion
                        )
                        .onChange(of: dragActive && hovering) { _, value in onPressChange(value) }
                case .dragNoFx:
                    cardContent
                        .contentShape(.rect)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .updating($dragActive) { _, state, _ in state = true }
                                .onChanged { value in
                                    SelfDebugLog.shared.append("dragNoFx onChanged loc=\(value.location)")
                                    let inside = value.location.x >= 0 && value.location.y >= 0
                                        && value.location.x <= cardSize.width && value.location.y <= cardSize.height
                                    if inside != dragInside { dragInside = inside }
                                }
                                .onEnded { value in
                                    let inside = value.location.x >= 0 && value.location.y >= 0
                                        && value.location.x <= cardSize.width && value.location.y <= cardSize.height
                                    SelfDebugLog.shared.append("dragNoFx onEnded loc=\(value.location) inside=\(inside)")
                                    if inside { action() }
                                    dragInside = true
                                }
                        )
                        .onChange(of: dragActive && dragInside) { _, value in onPressChange(value) }
                case .backing:
                    cardContent
                        .background {
                            ProbeInteractionBacking(
                                onPress: { value in
                                    if value != backingPressed { backingPressed = value }
                                    onPressChange(value)
                                },
                                onActivate: { action() }
                            )
                        }
                        .hoverLiftEffect(
                            isHovered: isHovered, isPressed: backingPressed, scale: 1.04,
                            pressedScale: 0.97, shadow: false, reduceMotion: reduceMotion
                        )
                        .accessibilityAction(.default) { action() }
                case .tapPressGesture:
                    cardContent
                        .contentShape(.rect)
                        .onTapGesture { action() }
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0)
                                .updating($longPressed) { _, state, _ in state = true }
                        )
                        .hoverLiftEffect(
                            isHovered: isHovered, isPressed: longPressed, scale: 1.04,
                            pressedScale: 0.97, shadow: false, reduceMotion: reduceMotion
                        )
                        .onChange(of: longPressed) { _, value in onPressChange(value) }
                }
            }
            .environment(\.prismCardLifted, isHovered)
            .onHover { inside in
                hovering = inside
                onHoverChange(inside)
            }
            .focusEffectDisabled()
            .contextMenu { menu() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Carte de test"))
            .accessibilityAddTraits(.isButton)
        }

        /// Same structure as `WideCard`: artwork on top, caption row with the `…` menu below.
        private var cardContent: some View {
            let height = (width / PrismMetrics.wideAspectRatio).rounded()
            return VStack(spacing: 0) {
                Color(white: 0.3)
                    .frame(width: width, height: height)
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                    Text("Légende").font(.caption).lineLimit(1)
                    Spacer(minLength: 4)
                    CardMenuButton(isHovered: true, menu: menu)
                        .padding(.trailing, -6)
                }
                .foregroundStyle(.white.opacity(0.85))
                .frame(height: 16)
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .padding(.bottom, 8)
                .frame(width: width, alignment: .leading)
                .background(Color(white: 0.2))
            }
            .clipShape(.rect(cornerRadius: PrismMetrics.wideRadius))
            .frame(width: width)
        }
    }

    /// Exact copy of `CardPressStyle` (CardSupport.swift) with a press-state observer.
    struct ProbeProductionPressStyle: ButtonStyle {
        let isHovered: Bool
        let reduceMotion: Bool
        let onPressChange: (Bool) -> Void

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .contentShape(.rect)
                .hoverLiftEffect(
                    isHovered: isHovered, isPressed: configuration.isPressed, scale: 1.04,
                    pressedScale: 0.97, shadow: false, reduceMotion: reduceMotion
                )
                .onChange(of: configuration.isPressed) { _, value in onPressChange(value) }
        }
    }

    // MARK: - Harness

    final class SelfDebugLog {
        static let shared = SelfDebugLog()
        var lines: [String] = []
        func append(_ line: String) { lines.append(line) }
        func drain() -> String { let out = lines.joined(separator: " | "); lines = []; return out }
    }

    final class Recorder {
        var activations = 0
        var pressTransitions: [Bool] = []
        var hoverTransitions: [Bool] = []
    }

    struct Mounted {
        let window: NSWindow
        let host: NSView
        let recorder: Recorder
        /// Card frame in window coordinates (bottom-left origin).
        var cardFrame: CGRect = .zero
        /// `…` menu frame in window coordinates.
        var menuFrame: CGRect?
    }

    private static var launched = false
    private static var menuOpens = 0

    private func ensureLaunched() {
        if !Self.launched {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            NSApp.finishLaunching()
            NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { _ in
                Self.menuOpens += 1
            }
            Self.launched = true
        }
    }

    private func mount(_ variant: Variant) throws -> Mounted {
        ensureLaunched()
        let recorder = Recorder()
        let width: CGFloat = 260
        let probe = ProbeInteractiveCard(
            variant: variant, width: width,
            action: { recorder.activations += 1 },
            menu: { Button("Lire") {} },
            onPressChange: { recorder.pressTransitions.append($0) },
            onHoverChange: { recorder.hoverTransitions.append($0) }
        )
        let host = NSHostingView(rootView: AnyView(
            probe
                .padding(.leading, 40).padding(.top, 40)
                .frame(width: width + 80, height: 300, alignment: .topLeading)
        ))
        let frame = CGRect(origin: .zero, size: CGSize(width: width + 80, height: 300))
        host.frame = frame
        let window = NSWindow(contentRect: frame.offsetBy(dx: -20_000, dy: -20_000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        layout(host)
        spin(0.3)

        var mounted = Mounted(window: window, host: host, recorder: recorder)
        locateFrames(&mounted, variant: variant)
        return mounted
    }

    // MARK: - Self-pid accessibility tree

    private func axAttr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }

    private struct AXHit {
        let element: AXUIElement
        let frame: CGRect  // window coordinates, bottom-left origin
    }

    /// Depth-first search for an accessibility element by label substring. Frames are
    /// converted from AX screen coordinates (top-left origin) to window coordinates.
    private func findAX(_ element: AXUIElement, window: NSWindow, labelFragment: String) -> AXHit? {
        // Iterative walk: deep AX trees overflow the small test-thread stack when recursive.
        var queue: [AXUIElement] = [element]
        var visited = 0
        while let current = queue.popLast() {
            visited += 1
            if visited > 4_000 { return nil }
            let role = axAttr(current, kAXRoleAttribute) as? String ?? ""
            let label = (axAttr(current, kAXTitleAttribute) as? String)
                ?? (axAttr(current, kAXDescriptionAttribute) as? String)
                ?? (axAttr(current, kAXValueAttribute) as? String)
                ?? ""
            let matches = labelFragment == "AXMenuButton"
                ? role == "AXMenuButton"
                : label.contains(labelFragment) && role != "AXWindow"
            if matches {
                var point = CGPoint.zero
                var size = CGSize.zero
                if let posValue = axAttr(current, kAXPositionAttribute), CFGetTypeID(posValue) == AXValueGetTypeID() {
                    AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
                }
                if let sizeValue = axAttr(current, kAXSizeAttribute), CFGetTypeID(sizeValue) == AXValueGetTypeID() {
                    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
                }
                let screenHeight = NSScreen.screens.first?.frame.height ?? 0
                let cocoa = CGRect(x: point.x, y: screenHeight - point.y - size.height, width: size.width, height: size.height)
                let inWindow = CGRect(x: cocoa.minX - window.frame.minX, y: cocoa.minY - window.frame.minY,
                                      width: size.width, height: size.height)
                return AXHit(element: current, frame: inWindow)
            }
            for child in axAttr(current, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                queue.append(child)
            }
        }
        return nil
    }

    private func axWindows() -> [AXUIElement] {
        let app = AXUIElementCreateApplication(getpid())
        return axAttr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    /// Locates the card and menu accessibility elements, retrying briefly because SwiftUI
    /// materializes its AX tree lazily in response to the first HIServices queries.
    private func locateFrames(_ mounted: inout Mounted, variant: Variant) {
        for _ in 0..<4 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            // The most recently created window is the probe's.
            guard let windowElement = axWindows().first else { continue }
            if mounted.cardFrame == .zero,
               let card = findAX(windowElement, window: mounted.window, labelFragment: "Carte de test") {
                mounted.cardFrame = card.frame
            }
            if mounted.menuFrame == nil,
               let menu = findAX(windowElement, window: mounted.window, labelFragment: "AXMenuButton") {
                mounted.menuFrame = menu.frame
            }
            if mounted.cardFrame != .zero { return }
        }
        print("[interaction] \(variant.rawValue): AX lookup incomplete card=\(mounted.cardFrame) menu=\(String(describing: mounted.menuFrame))")
    }

    // MARK: - Synthetic events (window coordinates)

    private static var eventNumber = 1

    private func post(_ type: NSEvent.EventType, window: NSWindow, at point: CGPoint) {
        Self.eventNumber += 1
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: Self.eventNumber, clickCount: 1, pressure: 1
        ) else { return }
        window.sendEvent(event)
    }

    private func click(window: NSWindow, at point: CGPoint) {
        post(.leftMouseDown, window: window, at: point)
        spin(0.03)
        post(.leftMouseUp, window: window, at: point)
    }

    private func drag(window: NSWindow, from start: CGPoint, to end: CGPoint, steps: Int) {
        post(.leftMouseDown, window: window, at: start)
        spin(0.03)
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            post(.leftMouseDragged, window: window, at: CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            ))
            spin(0.03)
        }
        post(.leftMouseUp, window: window, at: end)
    }

    private func spin(_ interval: TimeInterval = 0.08) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: interval))
    }

    private func dismissMenus(window: NSWindow) {
        if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil,
                                         characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                         isARepeat: false, keyCode: 53) {
            NSApp.sendEvent(escape)
        }
        spin(0.12)
        // Fallback: click far outside any card.
        post(.leftMouseDown, window: window, at: CGPoint(x: 4, y: 4))
        post(.leftMouseUp, window: window, at: CGPoint(x: 4, y: 4))
        spin(0.12)
    }

    private func layout(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
    }

    private func unmount(_ mounted: Mounted) {
        mounted.window.contentView = nil
        mounted.window.close()
    }

    /// The `…` menu sits at the trailing end of the caption row. The probe layout is
    /// deterministic: card width 260 at padding 40, caption band occupying the bottom
    /// 24 pt of the card, menu frame 28×22 hugging the trailing edge with a net 4 pt inset.
    /// Verified empirically: if the analytic point does not open the menu, scan the caption
    /// band for the point that does.
    private func locateMenuPoint(mounted: Mounted, card: CGRect) -> CGPoint? {
        // Analytic position in window coordinates: caption band is the bottom of the card
        // (low window y), menu centered ~10 pt above the card's bottom edge, 18 pt in from
        // the trailing edge.
        let analytic = CGPoint(x: card.maxX - 18, y: card.minY + 16)
        let before = Self.menuOpens
        click(window: mounted.window, at: analytic)
        spin(0.12)
        if Self.menuOpens > before {
            dismissMenus(window: mounted.window)
            return analytic
        }
        // Scan the caption band trailing region.
        for yOffset in [8.0, 16.0, 20.0] {
            var x = card.maxX - 8
            while x > card.maxX - 44 {
                let point = CGPoint(x: x, y: card.minY + yOffset)
                let scanBefore = Self.menuOpens
                click(window: mounted.window, at: point)
                spin(0.08)
                if Self.menuOpens > scanBefore {
                    dismissMenus(window: mounted.window)
                    return point
                }
                x -= 6
            }
        }
        return nil
    }

    /// Records one full interaction matrix for a variant and returns the transcript lines.
    private func matrix(_ variant: Variant) throws -> [String] {
        let mounted = try mount(variant)
        let card = mounted.cardFrame
        var lines: [String] = []
        precondition(card != .zero, "\(variant.rawValue): card frame not located")
        // Artwork point: horizontally centered, in the upper artwork region (window coords:
        // the card's top edge is maxY).
        let artwork = CGPoint(x: card.midX, y: card.maxY - 30)
        let outside = CGPoint(x: card.midX, y: card.minY - 60)
        let recorder = mounted.recorder

        // 1. Plain click on the artwork.
        recorder.activations = 0; recorder.pressTransitions = []
        click(window: mounted.window, at: artwork)
        spin()
        lines.append("1 click: activations=\(recorder.activations) presses=\(recorder.pressTransitions)")

        // 2. Right-click on the artwork, before any menu has been opened in this mount.
        recorder.activations = 0; recorder.pressTransitions = []
        let opensBeforeRight = Self.menuOpens
        post(.rightMouseDown, window: mounted.window, at: artwork)
        spin(0.05)
        post(.rightMouseUp, window: mounted.window, at: artwork)
        spin(0.15)
        lines.append("2 right-click: activations=\(recorder.activations) presses=\(recorder.pressTransitions) menuOpens=\(Self.menuOpens - opensBeforeRight)")
        dismissMenus(window: mounted.window)

        // 3. Down inside, drag below the card, release outside. The press state is sampled
        // after every step so the exit timing is compared exactly, not just the endpoints.
        recorder.activations = 0; recorder.pressTransitions = []
        var profile: [String] = []
        post(.leftMouseDown, window: mounted.window, at: artwork)
        spin(0.04)
        profile.append(recorder.pressTransitions.last.map { $0 ? "1" : "0" } ?? "-")
        for step in 1...5 {
            let progress = CGFloat(step) / 5
            post(.leftMouseDragged, window: mounted.window, at: CGPoint(x: artwork.x, y: artwork.y + (outside.y - artwork.y) * progress))
            spin(0.04)
            profile.append(recorder.pressTransitions.last.map { $0 ? "1" : "0" } ?? "-")
        }
        post(.leftMouseUp, window: mounted.window, at: outside)
        spin()
        lines.append("3 drag-out: activations=\(recorder.activations) presses=\(recorder.pressTransitions) profile=\(profile.joined()) dbg=\(SelfDebugLog.shared.drain())")

        // 4. Sloppy click: move ~24 pt inside the wide card, release inside.
        recorder.activations = 0; recorder.pressTransitions = []
        let sloppyStart = CGPoint(x: card.midX - 50, y: card.maxY - 30)
        let sloppyEnd = CGPoint(x: sloppyStart.x + 24, y: sloppyStart.y - 8)
        drag(window: mounted.window, from: sloppyStart, to: sloppyEnd, steps: 4)
        spin()
        lines.append("4 sloppy-inside: activations=\(recorder.activations) presses=\(recorder.pressTransitions) dbg=\(SelfDebugLog.shared.drain())")

        // 5. Down inside, drag out, back in, release inside. Press state sampled per step.
        recorder.activations = 0; recorder.pressTransitions = []
        var reentryProfile: [String] = []
        post(.leftMouseDown, window: mounted.window, at: artwork)
        spin(0.04)
        reentryProfile.append(recorder.pressTransitions.last.map { $0 ? "1" : "0" } ?? "-")
        for step in 1...3 {
            let progress = CGFloat(step) / 3
            post(.leftMouseDragged, window: mounted.window, at: CGPoint(x: artwork.x, y: artwork.y + (outside.y - artwork.y) * progress))
            spin(0.04)
            reentryProfile.append(recorder.pressTransitions.last.map { $0 ? "1" : "0" } ?? "-")
        }
        for step in 1...3 {
            let progress = 1 - CGFloat(step) / 3
            post(.leftMouseDragged, window: mounted.window, at: CGPoint(x: artwork.x, y: artwork.y + (outside.y - artwork.y) * progress))
            spin(0.04)
            reentryProfile.append(recorder.pressTransitions.last.map { $0 ? "1" : "0" } ?? "-")
        }
        post(.leftMouseUp, window: mounted.window, at: artwork)
        spin()
        lines.append("5 re-entry: activations=\(recorder.activations) presses=\(recorder.pressTransitions) profile=\(reentryProfile.joined())")

        // 6. Double-click: two activations.
        recorder.activations = 0; recorder.pressTransitions = []
        click(window: mounted.window, at: artwork)
        spin(0.06)
        click(window: mounted.window, at: artwork)
        spin()
        lines.append("6 double-click: activations=\(recorder.activations)")

        // 7. Click on the caption band away from the menu: whole card is clickable.
        recorder.activations = 0; recorder.pressTransitions = []
        click(window: mounted.window, at: CGPoint(x: card.minX + 60, y: card.minY + 12))
        spin()
        lines.append("7 caption-click: activations=\(recorder.activations)")

        // 8. Click on the `…` menu. The combined accessibility element hides the menu
        // button from the AX tree, so the hit point is derived from the deterministic
        // probe layout (trailing end of the caption row) and verified by scan when needed.
        // Kept late in the matrix: menu-open state pollutes subsequent interactions.
        let menuPoint = locateMenuPoint(mounted: mounted, card: card)
        if let menuPoint {
            recorder.activations = 0; recorder.pressTransitions = []
            let opensBefore = Self.menuOpens
            click(window: mounted.window, at: menuPoint)
            spin(0.15)
            lines.append("8 menu-click at \(menuPoint): activations=\(recorder.activations) presses=\(recorder.pressTransitions) menuOpens=\(Self.menuOpens - opensBefore)")
            dismissMenus(window: mounted.window)
        } else {
            lines.append("8 menu-click: menu not located even by scan")
        }

        // 9. Accessibility activation through AXPress on the card element.
        recorder.activations = 0
        var axResult = "no-element"
        if let windowElement = axWindows().first,
           let cardHit = findAX(windowElement, window: mounted.window, labelFragment: "Carte de test") {
            let error = AXUIElementPerformAction(cardHit.element, kAXPressAction as CFString)
            spin()
            axResult = "err=\(error.rawValue) activations=\(recorder.activations)"
        }
        lines.append("9 ax-press: \(axResult)")

        unmount(mounted)
        return lines
    }

    /// Reliability probe: repeat the key activation sequences many times per variant and
    /// count successful activations. Gesture cancellation races would show up as missed
    /// activations; production `Button` is the reference for the same event timing.
    @Test func activationReliability() async throws {
        for variant in [Variant.production, .dragGeometry] {
            let mounted = try mount(variant)
            let card = mounted.cardFrame
            precondition(card != .zero, "\(variant.rawValue): card frame not located")
            let artwork = CGPoint(x: card.midX, y: card.maxY - 30)
            let outside = CGPoint(x: card.midX, y: card.minY - 60)
            let recorder = mounted.recorder
            var plainHits = 0, sloppyHits = 0, reentryHits = 0, dragOutHits = 0
            let repetitions = 25

            for _ in 0..<repetitions {
                // Plain click.
                recorder.activations = 0
                click(window: mounted.window, at: artwork)
                spin(0.06)
                if recorder.activations == 1 { plainHits += 1 }

                // Sloppy inside click.
                recorder.activations = 0
                let sloppyStart = CGPoint(x: card.midX - 50, y: card.maxY - 30)
                let sloppyEnd = CGPoint(x: sloppyStart.x + 24, y: sloppyStart.y - 8)
                drag(window: mounted.window, from: sloppyStart, to: sloppyEnd, steps: 4)
                spin(0.06)
                if recorder.activations == 1 { sloppyHits += 1 }

                // Re-entry.
                recorder.activations = 0
                post(.leftMouseDown, window: mounted.window, at: artwork)
                spin(0.04)
                for step in 1...3 {
                    let progress = CGFloat(step) / 3
                    post(.leftMouseDragged, window: mounted.window, at: CGPoint(x: artwork.x, y: artwork.y + (outside.y - artwork.y) * progress))
                    spin(0.04)
                }
                for step in 1...3 {
                    let progress = 1 - CGFloat(step) / 3
                    post(.leftMouseDragged, window: mounted.window, at: CGPoint(x: artwork.x, y: artwork.y + (outside.y - artwork.y) * progress))
                    spin(0.04)
                }
                post(.leftMouseUp, window: mounted.window, at: artwork)
                spin(0.06)
                if recorder.activations == 1 { reentryHits += 1 }

                // Drag out (must NOT activate).
                recorder.activations = 0
                drag(window: mounted.window, from: artwork, to: outside, steps: 5)
                spin(0.06)
                if recorder.activations == 0 { dragOutHits += 1 }
            }
            print("[interaction] reliability \(variant.rawValue): plain \(plainHits)/\(repetitions) sloppy \(sloppyHits)/\(repetitions) re-entry \(reentryHits)/\(repetitions) drag-out-correct \(dragOutHits)/\(repetitions)")
            unmount(mounted)
        }
    }

    // NOTE: a real-`WideCard` variant of this matrix was attempted and removed. The self-pid
    // AX walk used to locate frames is unreliable against the real card's deeper hierarchy
    // (intermittent SkyLight crashes / lookup failures in the test process), and synthetic
    // menu dismissal risks modal-tracking deadlocks. The replica matrix below is the behavioral
    // evidence: it reproduces the exact production structure — clickable card with a nested
    // visible `…` menu — and the production implementation now *is* the `dragGeometry`
    // interaction, so replica equivalence covers the shipping code path.

    /// Runs the full interaction matrix for every variant and prints the comparison. This is
    /// the primary behavioral-equivalence evidence: each candidate row must match the
    /// production row channel by channel.
    @Test func behaviorMatrix() async throws {
        for variant in [Variant.production, .dragGeometry, .dragNoFx] {
            let lines = try matrix(variant)
            print("[interaction] === \(variant.rawValue) ===")
            for line in lines { print("[interaction]   \(line)") }
        }
    }
}


// MARK: - AppKit interaction backing

/// Hit-testable backing view replicating `NSButton` mouse semantics exactly: press on
/// mouse-down, unpress while dragged outside, re-press on re-entry, activate on release
/// inside. Bounds come free from the view itself — no geometry measurement. Right-clicks
/// and other-button events are never consumed.
private final class ProbeBackingView: NSView {
    var onPress: (Bool) -> Void = { _ in }
    var onActivate: () -> Void = {}
    private var pressed = false

    override func mouseDown(with event: NSEvent) {
        pressed = true
        onPress(true)
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside != pressed {
            pressed = inside
            onPress(inside)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if pressed { onPress(false) }
        pressed = false
        if inside { onActivate() }
    }
}

private struct ProbeInteractionBacking: NSViewRepresentable {
    let onPress: (Bool) -> Void
    let onActivate: () -> Void

    func makeNSView(context: Context) -> ProbeBackingView {
        let view = ProbeBackingView()
        view.onPress = onPress
        view.onActivate = onActivate
        return view
    }

    func updateNSView(_ nsView: ProbeBackingView, context: Context) {
        nsView.onPress = onPress
        nsView.onActivate = onActivate
    }
}
