import SwiftUI

extension View {
    /// Apple TV hover affordance: scale + soft shadow on pointer hover, spring-animated.
    /// Only transform and shadow opacity animate.
    public func hoverLift(scale: CGFloat = 1.04, shadow: Bool = true) -> some View {
        modifier(HoverLiftModifier(scale: scale, shadow: shadow))
    }

    func hoverLiftEffect(isHovered: Bool, isPressed: Bool, scale: CGFloat, pressedScale: CGFloat, shadow: Bool, reduceMotion: Bool) -> some View {
        modifier(HoverLiftEffect(isHovered: isHovered, isPressed: isPressed, scale: scale,
                                 pressedScale: pressedScale, shadow: shadow, reduceMotion: reduceMotion))
    }
}

/// Applies the lift only when it can be seen: while a scroll container is scrolling the
/// scale/shadow/brightness modifiers are skipped entirely (fewer layout nodes per card
/// per frame), and restored when the scroll phase ends.
private struct HoverLiftEffect: ViewModifier {
    let isHovered: Bool
    let isPressed: Bool
    let scale: CGFloat
    let pressedScale: CGFloat
    let shadow: Bool
    let reduceMotion: Bool
    @Environment(\.prismIsScrollingContent) private var isScrollingContent

    @ViewBuilder func body(content: Content) -> some View {
        if isScrollingContent {
            content
        } else {
            let target: CGFloat = isPressed ? pressedScale : (isHovered ? scale : 1)
            content
                .modifier(ContentShadow(enabled: shadow, isHovered: isHovered))
                .scaleEffect(reduceMotion ? 1 : target)
                .brightness(reduceMotion && isHovered ? 0.04 : 0)
                .animation(isPressed ? PrismMotion.press : PrismMotion.hover, value: isHovered)
                .animation(PrismMotion.press, value: isPressed)
        }
    }
}

/// A shadow cast by the content's own pixels. Only for callers that ask for it: cards draw theirs
/// from their artwork shape instead (see `ArtworkSurface`).
private struct ContentShadow: ViewModifier {
    let enabled: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.shadow(color: PrismColors.hoverShadow.opacity(isHovered ? 1 : 0), radius: 18, y: 10)
        } else {
            content
        }
    }
}

private struct HoverLiftModifier: ViewModifier {
    let scale: CGFloat
    let shadow: Bool
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.prismIsScrollingContent) private var isScrollingContent

    func body(content: Content) -> some View {
        content
            .hoverLiftEffect(isHovered: isHovered && !isScrollingContent, isPressed: false, scale: scale, pressedScale: 1, shadow: shadow, reduceMotion: reduceMotion)
            .onHover { inside in
                guard !isScrollingContent else { return }
                isHovered = inside
            }
            .onChange(of: isScrollingContent) { _, scrolling in
                if !scrolling { isHovered = false }
            }
    }
}

#Preview("HoverLift") {
    HStack(spacing: 20) {
        RoundedRectangle(cornerRadius: 12).fill(.blue.gradient).frame(width: 200, height: 112).hoverLift()
        Button {} label: {
            RoundedRectangle(cornerRadius: 10).fill(.purple.gradient).frame(width: 137, height: 205)
        }
        .buttonStyle(.card)
    }
    .padding(60)
}
