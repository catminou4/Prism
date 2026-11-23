import SwiftUI

/// Fills the rubber-band space with the same artwork while keeping the hero's content still.
private struct HeroOverscrollZoom: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let exposedOnly: Bool

    func body(content: Content) -> some View {
        let shouldReduceMotion = reduceMotion
        let onlyWhenExposed = exposedOnly
        content.visualEffect { effect, proxy in
            let pull = max(0, proxy.frame(in: .scrollView(axis: .vertical)).minY)
            let zoom = shouldReduceMotion ? 1 : 1 + pull / max(1, proxy.size.height)
            return effect
                .scaleEffect(zoom, anchor: .bottom)
                .opacity(onlyWhenExposed && (pull <= 0 || shouldReduceMotion) ? 0 : 1)
        }
    }
}

extension View {
    func heroOverscrollZoom(exposedOnly: Bool = false) -> some View {
        modifier(HeroOverscrollZoom(exposedOnly: exposedOnly))
    }
}
