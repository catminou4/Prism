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

/// During scroll, return to neutral transforms without replacing the modified view.
private struct HoverLiftEffect: ViewModifier {
    let isHovered: Bool
    let isPressed: Bool
    let scale: CGFloat
    let pressedScale: CGFloat
    let shadow: Bool
    let reduceMotion: Bool
    @ScrollingContent private var isScrollingContent

    func body(content: Content) -> some View {
        let hovering = isHovered && !isScrollingContent
        let pressing = isPressed && !isScrollingContent
        let target: CGFloat = pressing ? pressedScale : (hovering ? scale : 1)
        content
            .modifier(ContentShadow(enabled: shadow, isHovered: hovering))
            .scaleEffect(reduceMotion ? 1 : target)
            .brightness(reduceMotion && hovering ? 0.04 : 0)
            .animation(pressing ? PrismMotion.press : PrismMotion.hover, value: hovering)
            .animation(PrismMotion.press, value: pressing)
    }
}

/// The hover shadow. Only for callers that ask for it: cards draw theirs from their artwork
/// shape instead (see `ArtworkSurface`). Same pattern as `ArtworkSurface`: the shadow only
/// exists in the render tree while hovered — a permanent `.shadow` whose colour is merely
/// transparent still cost a compositing pass on every frame. The caster sits in the
/// background (the content branch is untouched, so remote-image state is never recreated)
/// and uses the card corner radius: for the opaque cards this serves, its silhouette is
/// identical to the content-alpha shadow it replaces, and the black backing never shows
/// through. The enclosing `HoverLiftEffect` animates the insertion/removal transition.
private struct ContentShadow: ViewModifier {
    let enabled: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .background {
                    if isHovered {
                        RoundedRectangle(cornerRadius: PrismMetrics.wideRadius, style: .continuous)
                            .fill(.black)
                            .shadow(color: PrismColors.hoverShadow, radius: 18, y: 10)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
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
    @ScrollingContent private var isScrollingContent

    func body(content: Content) -> some View {
        content
            .hoverLiftEffect(isHovered: isHovered && !isScrollingContent, isPressed: false, scale: scale, pressedScale: 1, shadow: shadow, reduceMotion: reduceMotion)
            .onHover { inside in
                if !inside || !isScrollingContent { isHovered = inside }
            }
            .onChange(of: isHovered && isScrollingContent) { _, shouldReset in
                if shouldReset { isHovered = false }
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
