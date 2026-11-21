import SwiftUI

/// Animation curves shared by every Prism component.
nonisolated public enum PrismMotion {
    /// Default spring (navigation, selection, layout-free state changes).
    public static let standard: Animation = .smooth(duration: 0.35)
    /// Hover lift / reveal.
    public static let hover: Animation = .spring(response: 0.3, dampingFraction: 0.8)
    /// Press feedback (fast, slightly bouncy release).
    public static let press: Animation = .spring(response: 0.22, dampingFraction: 0.7)
    /// Hero carousel cross-fade.
    public static let heroFade: Animation = .easeInOut(duration: 0.8)
    /// Remote image fade-in.
    public static let imageFade: Animation = .easeOut(duration: 0.25)
    /// Quick fades (controls appearing on hover, toasts).
    public static let quickFade: Animation = .easeInOut(duration: 0.2)
    /// Ken Burns duration for hero backdrops.
    public static let kenBurnsDuration: Double = 12
    /// Hero auto-advance interval.
    public static let heroInterval: Double = 8

    /// Returns `animation`, or `nil` when Reduce Motion asks to drop transforms.
    public static func respecting(_ reduceMotion: Bool, _ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }
}
