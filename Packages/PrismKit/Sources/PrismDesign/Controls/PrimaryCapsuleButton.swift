import SwiftUI

/// Apple TV primary action: white capsule, black 15 pt semibold label, optional leading symbol.
///
/// With `progress`, renders the resume variant `▶ ━━━─── 33 min` (inline progress capsule).
public struct PrimaryCapsuleButton: View {
    public enum Style: Sendable {
        /// White capsule, black label (hero).
        case white
        /// Accent capsule, white label (onboarding / sheets).
        case accent
    }

    private let title: String
    private let systemImage: String?
    private let progress: Double?
    private let style: Style
    private let height: CGFloat
    private let minWidth: CGFloat
    private let fillsWidth: Bool
    private let action: () -> Void

    public init(
        _ title: String,
        systemImage: String? = nil,
        progress: Double? = nil,
        style: Style = .white,
        height: CGFloat = PrismMetrics.primaryButtonHeight,
        minWidth: CGFloat = 180,
        fillsWidth: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.progress = progress
        self.style = style
        self.height = height
        self.minWidth = minWidth
        self.fillsWidth = fillsWidth
        self.action = action
    }

    /// Convenience matching `PrimaryCapsuleButton(title:systemImage:progress:action:)`.
    public init(title: String, systemImage: String? = nil, progress: Double? = nil, action: @escaping () -> Void) {
        self.init(title, systemImage: systemImage, progress: progress, action: action)
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .bold))
                        .imageScale(.medium)
                }
                if let progress {
                    ProgressCapsule(
                        fraction: progress, width: 40, height: 4,
                        tint: foreground, track: foreground.opacity(0.22)
                    )
                    .padding(.horizontal, 2)
                }
                Text(title)
                    .font(height >= PrismMetrics.largeButtonHeight ? PrismFont.largeButton : PrismFont.primaryButton)
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, PrismMetrics.primaryButtonHorizontalPadding)
            .frame(minWidth: minWidth, maxWidth: fillsWidth ? .infinity : nil, minHeight: height, maxHeight: height)
        }
        .buttonStyle(PrimaryCapsuleStyle(background: background))
        .accessibilityLabel(accessibilityTitle)
    }

    private var foreground: Color { style == .white ? .black : .white }
    private var background: Color { style == .white ? .white : .accentColor }

    private var accessibilityTitle: Text {
        if let progress {
            Text("\(title), \(Int((progress * 100).rounded())) % regardé")
        } else {
            Text(title)
        }
    }
}

private struct PrimaryCapsuleStyle: ButtonStyle {
    let background: Color

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, background: background)
    }

    struct StyleBody: View {
        let configuration: Configuration
        let background: Color
        @State private var isHovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .background(background, in: .capsule)
                .overlay {
                    // Hover brighten / press dim without touching the label layout.
                    Capsule().fill(.white).opacity(isHovered && !configuration.isPressed ? 0.12 : 0).blendMode(.plusLighter)
                    Capsule().fill(.black).opacity(configuration.isPressed ? 0.08 : 0)
                }
                .contentShape(.capsule)
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : (isHovered ? 1.02 : 1)))
                .opacity(isEnabled ? 1 : 0.5)
                .animation(PrismMotion.hover, value: isHovered)
                .animation(PrismMotion.press, value: configuration.isPressed)
                .onHover { isHovered = $0 }
                .focusEffectDisabled()
        }
    }
}

#Preview("PrimaryCapsuleButton") {
    VStack(alignment: .leading, spacing: 16) {
        PrimaryCapsuleButton("Lecture", systemImage: "play.fill") {}
        PrimaryCapsuleButton("33 min", systemImage: "play.fill", progress: 0.42) {}
        PrimaryCapsuleButton("Lire S1, É3", systemImage: "play.fill") {}
        PrimaryCapsuleButton("Continuer", style: .accent, height: PrismMetrics.largeButtonHeight, fillsWidth: true) {}
            .frame(width: 320)
    }
    .padding(40)
    .background(.black)
}
