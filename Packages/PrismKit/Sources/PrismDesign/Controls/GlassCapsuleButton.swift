import SwiftUI

/// Glass capsule with optional tint dot, symbol and trailing `chevron.down`
/// (source / variant picker: `[●] Source A · 4K ⌄`). Wrap in a `Menu` label when needed.
public struct GlassCapsuleButton: View {
    private let title: String
    private let systemImage: String?
    private let tint: Color?
    private let trailingChevron: Bool
    private let style: PrismGlassStyle
    private let action: () -> Void

    public init(
        title: String,
        systemImage: String? = nil,
        tint: Color? = nil,
        trailingChevron: Bool = true,
        style: PrismGlassStyle = .dark,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.trailingChevron = trailingChevron
        self.style = style
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            GlassCapsuleLabel(title: title, systemImage: systemImage, tint: tint, trailingChevron: trailingChevron)
        }
        .buttonStyle(GlassCapsuleStyle(style: style))
    }
}

/// The label of `GlassCapsuleButton`, reusable as a `Menu` label.
public struct GlassCapsuleLabel: View {
    let title: String
    let systemImage: String?
    let tint: Color?
    let trailingChevron: Bool

    public init(title: String, systemImage: String? = nil, tint: Color? = nil, trailingChevron: Bool = true) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.trailingChevron = trailingChevron
    }

    public var body: some View {
        HStack(spacing: 7) {
            if let tint {
                Circle().fill(tint).frame(width: 8, height: 8)
            }
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
            }
            Text(title)
                .font(PrismFont.capsuleButton)
                .lineLimit(1)
            if trailingChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(0.7)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: PrismMetrics.circleButtonSize)
        .contentShape(.capsule)
    }
}

/// Glass capsule chrome for buttons and menus.
public struct GlassCapsuleStyle: ButtonStyle {
    let style: PrismGlassStyle

    public init(style: PrismGlassStyle = .dark) {
        self.style = style
    }

    public func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, style: style)
    }

    struct StyleBody: View {
        let configuration: Configuration
        let style: PrismGlassStyle
        @State private var isHovered = false
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .foregroundStyle(style == .regular && colorScheme == .light ? Color.primary : Color.white)
                .prismGlass(style, in: .capsule, interactive: true)
                .overlay { Capsule().fill(.white).opacity(isHovered ? 0.08 : 0).allowsHitTesting(false) }
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
                .animation(PrismMotion.press, value: configuration.isPressed)
                .animation(PrismMotion.quickFade, value: isHovered)
                .onHover { isHovered = $0 }
                .focusEffectDisabled()
        }
    }
}

#Preview("GlassCapsuleButton") {
    HStack(spacing: 12) {
        GlassCapsuleButton(title: "Source A · 4K", tint: PrismTint.purple.color) {}
        GlassCapsuleButton(title: "Saison 1", trailingChevron: true) {}
        GlassCapsuleButton(title: "Bande-annonce", systemImage: "play.rectangle", trailingChevron: false) {}
    }
    .padding(40)
    .background(.black)
}
