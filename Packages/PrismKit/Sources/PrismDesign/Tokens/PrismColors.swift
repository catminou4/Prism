import AppKit
import SwiftUI

/// Semantic colours.
nonisolated public enum PrismColors {
    /// Page background (follows the system appearance like Apple TV for Mac).
    public static let pageBackground = Color(nsColor: .windowBackgroundColor)
    /// Hero zones are always dark.
    public static let heroBackground = Color.black
    /// Secondary fill for panels (`À propos`, source cards) — adapts to the appearance.
    public static let panelFill = Color(nsColor: NSColor(name: "PrismPanelFill") { appearance in
        appearance.isDark
            ? NSColor(white: 1, alpha: 0.08)
            : NSColor(white: 0, alpha: 0.05)
    })
    /// Card placeholder base when nothing else is known.
    public static let cardPlaceholder = Color(nsColor: NSColor(name: "PrismCardPlaceholder") { appearance in
        appearance.isDark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.88, alpha: 1)
    })
    /// Hairline stroke drawn inside artwork (white 8 %).
    public static let artworkStroke = Color.white.opacity(0.08)
    /// Text on artwork.
    public static let onArtwork = Color.white
    public static let onArtworkSecondary = Color.white.opacity(0.72)
    /// Live red.
    public static let live = Color(red: 0.95, green: 0.16, blue: 0.20)
    /// Hover shadow.
    public static let hoverShadow = Color.black.opacity(0.35)
}

nonisolated extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) != nil
    }
}
