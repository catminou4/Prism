import SwiftUI

/// Glass variants used by Prism controls.
nonisolated public enum PrismGlassStyle: Sendable, Hashable {
    /// System regular Liquid Glass (toolbar circles, capsules, chips).
    case regular
    /// Darker glass for controls sitting on the always-dark hero (`+` Ma liste).
    case dark
    /// Clear glass for controls over video/artwork (player).
    case clear
}

extension EnvironmentValues {
    /// When `true`, glass and materials are replaced by flat approximations so offscreen
    /// snapshots (`prism-tools gallery`) render faithfully. Never set this in the app.
    @Entry public var prismSnapshotRendering: Bool = false

    /// Snapshot-only: renders hover-dependent chrome (card lift, shelf/hero chevrons) as hovered.
    @Entry public var prismSnapshotHover: Bool = false
}

extension View {
    /// Applies Liquid Glass in `shape`, or an opaque fill when Reduce Transparency is on.
    public func prismGlass(_ style: PrismGlassStyle = .regular, in shape: some Shape = .capsule, interactive: Bool = false) -> some View {
        modifier(PrismGlassModifier(style: style, shape: shape, interactive: interactive))
    }
}

private struct PrismGlassModifier<S: Shape>: ViewModifier {
    let style: PrismGlassStyle
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.prismSnapshotRendering) private var snapshot

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(solidFill, in: shape)
        } else if snapshot {
            content
                .background(simulatedFill, in: shape)
                .overlay {
                    shape.stroke(
                        LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04), .white.opacity(0.12)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
                }
        } else {
            content.glassEffect(glass, in: shape)
        }
    }

    private var glass: Glass {
        let base: Glass = switch style {
        case .regular: .regular
        case .dark: .regular.tint(.black.opacity(0.45))
        case .clear: .clear
        }
        return base.interactive(interactive)
    }

    /// Flat stand-in for snapshots (glass cannot be rendered offscreen).
    private var simulatedFill: Color {
        switch style {
        case .regular: colorScheme == .dark ? Color(white: 0.38, opacity: 0.92) : Color(white: 0.97, opacity: 0.92)
        case .dark: Color(white: 0.2, opacity: 0.9)
        case .clear: Color(white: 0.3, opacity: 0.55)
        }
    }

    private var solidFill: Color {
        switch style {
        case .regular: colorScheme == .dark ? Color(white: 0.24) : Color(white: 0.9)
        case .dark: Color(white: 0.16)
        case .clear: Color(white: 0.2)
        }
    }
}
