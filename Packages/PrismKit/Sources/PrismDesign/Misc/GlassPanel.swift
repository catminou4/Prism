import SwiftUI

/// Rounded Liquid Glass container (floating panels: channel list, pickers, overlays).
/// Falls back to an opaque fill under Reduce Transparency.
public struct GlassPanel<Content: View>: View {
    private let cornerRadius: CGFloat
    private let padding: CGFloat
    private let style: PrismGlassStyle
    private let content: Content

    public init(cornerRadius: CGFloat = 20, padding: CGFloat = 16, style: PrismGlassStyle = .regular, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.style = style
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .prismGlass(style, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

#Preview("GlassPanel") {
    GlassPanel {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chaînes").font(.headline)
            Text("TF1 · France 2 · France 3").foregroundStyle(.secondary)
        }
    }
    .padding(40)
    .background(PrismTint.purple.gradient)
}
