import SwiftUI

/// "Prism" wordmark: SF Pro Display semibold, tight tracking.
public struct PrismWordmark: View {
    private let size: CGFloat
    private let color: Color

    public init(size: CGFloat = 34, color: Color = .primary) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        Text(verbatim: "Prism")
            .font(.system(size: size, weight: .semibold))
            .tracking(-size * 0.025)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel("Prism")
    }
}

/// Mark + wordmark lockup.
public struct PrismLogoLockup: View {
    private let size: CGFloat
    private let axis: Axis
    private let style: PrismLogoMark.Style
    private let wordmarkColor: Color

    /// - Parameter size: Wordmark point size; the mark scales with it.
    public init(size: CGFloat = 34, axis: Axis = .horizontal, style: PrismLogoMark.Style = .spectral, wordmarkColor: Color = .primary) {
        self.size = size
        self.axis = axis
        self.style = style
        self.wordmarkColor = wordmarkColor
    }

    public var body: some View {
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: size * 0.22))
            : AnyLayout(VStackLayout(spacing: size * 0.35))
        layout {
            PrismLogoMark(size: axis == .horizontal ? size * 1.25 : size * 2.4, style: style)
            PrismWordmark(size: size, color: wordmarkColor)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Prism")
    }
}

#Preview("PrismLogoLockup") {
    VStack(spacing: 30) {
        PrismLogoLockup(wordmarkColor: .white)
        PrismLogoLockup(size: 28, axis: .vertical, wordmarkColor: .white)
    }
    .padding(40)
    .background(.black)
}
