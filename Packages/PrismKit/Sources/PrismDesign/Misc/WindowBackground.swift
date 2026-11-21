import SwiftUI

extension View {
    /// Page background following the system appearance (Apple TV for Mac pages).
    public func prismWindowBackground() -> some View {
        background(PrismColors.pageBackground.ignoresSafeArea())
    }

    /// Always-dark background for hero zones, the player and onboarding.
    public func prismDarkBackground() -> some View {
        background(PrismColors.heroBackground.ignoresSafeArea())
            .environment(\.colorScheme, .dark)
    }

    /// Standard horizontal page margin (40 pt).
    public func prismContentMargins() -> some View {
        padding(.horizontal, PrismMetrics.contentMargin)
    }
}
