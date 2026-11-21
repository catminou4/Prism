import SwiftUI

extension View {
    /// Apple TV hover affordance: scale + soft shadow on pointer hover, spring-animated.
    /// Only transform and shadow opacity animate.
    public func hoverLift(scale: CGFloat = 1.04, shadow: Bool = true) -> some View {
        modifier(HoverLiftModifier(scale: scale, shadow: shadow))
    }

    func hoverLiftEffect(isHovered: Bool, isPressed: Bool, scale: CGFloat, pressedScale: CGFloat, shadow: Bool, reduceMotion: Bool) -> some View {
        let target: CGFloat = isPressed ? pressedScale : (isHovered ? scale : 1)
        return self
            .shadow(color: PrismColors.hoverShadow.opacity(shadow && isHovered ? 1 : 0), radius: 18, y: 10)
            .scaleEffect(reduceMotion ? 1 : target)
            .brightness(reduceMotion && isHovered ? 0.04 : 0)
            .animation(isPressed ? PrismMotion.press : PrismMotion.hover, value: isHovered)
            .animation(PrismMotion.press, value: isPressed)
    }
}

private struct HoverLiftModifier: ViewModifier {
    let scale: CGFloat
    let shadow: Bool
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .hoverLiftEffect(isHovered: isHovered, isPressed: false, scale: scale, pressedScale: 1, shadow: shadow, reduceMotion: reduceMotion)
            .onHover { isHovered = $0 }
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
