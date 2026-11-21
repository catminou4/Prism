import SwiftUI

/// Source tints. Same raw values and order as `PrismCore.SourceTint`
/// (`PrismTint(rawValue: sourceTint.rawValue)`).
nonisolated public enum PrismTint: Int, CaseIterable, Sendable, Hashable {
    case blue, purple, pink, red, orange, yellow, green, teal

    /// System accent colour for the tint.
    public var color: Color {
        switch self {
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        }
    }

    /// Light → deep colour pair used for monograms, tiles and gradients (sRGB, tuned to read
    /// well under white text in both appearances).
    public var gradientColors: (top: Color, bottom: Color) {
        switch self {
        case .blue: (Color(red: 0.36, green: 0.62, blue: 1.00), Color(red: 0.05, green: 0.33, blue: 0.86))
        case .purple: (Color(red: 0.72, green: 0.50, blue: 1.00), Color(red: 0.42, green: 0.20, blue: 0.82))
        case .pink: (Color(red: 1.00, green: 0.48, blue: 0.70), Color(red: 0.84, green: 0.16, blue: 0.45))
        case .red: (Color(red: 1.00, green: 0.45, blue: 0.40), Color(red: 0.80, green: 0.12, blue: 0.15))
        case .orange: (Color(red: 1.00, green: 0.66, blue: 0.30), Color(red: 0.90, green: 0.38, blue: 0.05))
        case .yellow: (Color(red: 1.00, green: 0.84, blue: 0.30), Color(red: 0.92, green: 0.60, blue: 0.02))
        case .green: (Color(red: 0.42, green: 0.86, blue: 0.48), Color(red: 0.10, green: 0.58, blue: 0.26))
        case .teal: (Color(red: 0.36, green: 0.84, blue: 0.86), Color(red: 0.04, green: 0.52, blue: 0.62))
        }
    }

    /// Two-colour vertical gradient.
    public var gradient: LinearGradient {
        let colors = gradientColors
        return LinearGradient(colors: [colors.top, colors.bottom], startPoint: .top, endPoint: .bottom)
    }

    /// Deterministic tint for an arbitrary string (names, ids).
    public static func forSeed(_ seed: String) -> PrismTint {
        let all = PrismTint.allCases
        return all[Int(StableHash.fnv1a(seed) % UInt64(all.count))]
    }
}
