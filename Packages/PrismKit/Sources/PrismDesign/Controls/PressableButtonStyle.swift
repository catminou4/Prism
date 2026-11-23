import SwiftUI

/// Press feedback only: scales to `pressedScale` with a quick spring. No focus ring.
public struct PressableButtonStyle: ButtonStyle {
    private let pressedScale: CGFloat

    public init(pressedScale: CGFloat = 0.97) {
        self.pressedScale = pressedScale
    }

    public func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration, pressedScale: pressedScale)
    }

    private struct PressableBody: View {
        let configuration: Configuration
        let pressedScale: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .contentShape(.rect)
                .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
                .opacity(configuration.isPressed && reduceMotion ? 0.8 : 1)
                .animation(PrismMotion.press, value: configuration.isPressed)
        }
    }
}

/// Card behaviour: hover lift (scale + shadow) and press scale, the Apple TV affordance.
public struct CardButtonStyle: ButtonStyle {
    private let hoverScale: CGFloat
    private let pressedScale: CGFloat
    private let shadow: Bool

    public init(hoverScale: CGFloat = 1.04, pressedScale: CGFloat = 0.97, shadow: Bool = true) {
        self.hoverScale = hoverScale
        self.pressedScale = pressedScale
        self.shadow = shadow
    }

    public func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration, hoverScale: hoverScale, pressedScale: pressedScale, shadow: shadow)
    }

    private struct CardBody: View {
        let configuration: Configuration
        let hoverScale: CGFloat
        let pressedScale: CGFloat
        let shadow: Bool
        @State private var isHovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.prismScrollActivity) private var scrollActivity

        var body: some View {
            configuration.label
                .contentShape(.rect)
                .hoverLiftEffect(
                    isHovered: isHovered && isEnabled && scrollActivity?.isScrolling != true,
                    isPressed: configuration.isPressed, scale: hoverScale, pressedScale: pressedScale,
                    shadow: shadow, reduceMotion: reduceMotion
                )
                .onHover { inside in
                    if !inside || scrollActivity?.isScrolling != true { isHovered = inside }
                }
        }
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// Scale-on-press, no chrome.
    public static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

extension ButtonStyle where Self == CardButtonStyle {
    /// Hover lift + press, no chrome (cards).
    public static var card: CardButtonStyle { CardButtonStyle() }
}
