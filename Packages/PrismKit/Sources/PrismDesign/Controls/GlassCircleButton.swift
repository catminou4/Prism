import SwiftUI

/// Circular Liquid Glass icon button (toolbar back/mute/fullscreen/share, player controls).
public struct GlassCircleButton: View {
    private let systemName: String
    private let size: CGFloat
    private let style: PrismGlassStyle
    private let label: String?
    private let action: () -> Void

    public init(
        systemName: String,
        size: CGFloat = PrismMetrics.toolbarButtonSize,
        style: PrismGlassStyle = .regular,
        accessibilityLabel: String? = nil,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.size = size
        self.style = style
        self.label = accessibilityLabel
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: (size * 0.4).rounded(), weight: .medium))
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(GlassCircleStyle(style: style))
        .accessibilityLabel(Text(label ?? GlassCircleButton.defaultLabel(for: systemName)))
    }

    static func defaultLabel(for symbol: String) -> String {
        switch symbol {
        case "chevron.left": "Retour"
        case "chevron.right": "Suivant"
        case "speaker.slash", "speaker.slash.fill": "Activer le son"
        case "speaker.wave.2", "speaker.wave.2.fill": "Couper le son"
        case "arrow.up.left.and.arrow.down.right": "Plein écran"
        case "square.and.arrow.up": "Partager"
        case "plus": "Ajouter à Ma liste"
        case "checkmark": "Retirer de Ma liste"
        case "ellipsis": "Plus d'options"
        case "xmark": "Fermer"
        default: symbol
        }
    }
}

struct GlassCircleStyle: ButtonStyle {
    let style: PrismGlassStyle

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, style: style)
    }

    struct StyleBody: View {
        let configuration: Configuration
        let style: PrismGlassStyle
        @State private var isHovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            configuration.label
                .foregroundStyle(foreground)
                .prismGlass(style, in: .circle, interactive: true)
                .overlay {
                    Circle().fill(.white).opacity(isHovered ? 0.08 : 0).allowsHitTesting(false)
                }
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.94 : 1))
                .animation(PrismMotion.press, value: configuration.isPressed)
                .animation(PrismMotion.quickFade, value: isHovered)
                .onHover { isHovered = $0 }
                .focusEffectDisabled()
        }

        private var foreground: Color {
            switch style {
            case .regular: colorScheme == .dark ? .white : .primary
            case .dark, .clear: .white
            }
        }
    }
}

#Preview("GlassCircleButton") {
    HStack(spacing: 8) {
        GlassCircleButton(systemName: "chevron.left") {}
        Spacer()
        GlassCircleButton(systemName: "speaker.slash") {}
        GlassCircleButton(systemName: "arrow.up.left.and.arrow.down.right") {}
        GlassCircleButton(systemName: "square.and.arrow.up") {}
    }
    .padding(8)
    .frame(width: 500)
    .background(.black)
}
