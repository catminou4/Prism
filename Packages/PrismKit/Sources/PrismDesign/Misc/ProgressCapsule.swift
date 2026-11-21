import SwiftUI

/// Thin progress capsule (white on white 30 %) used on cards and in the resume button.
public struct ProgressCapsule: View {
    private let fraction: Double
    private let width: CGFloat?
    private let height: CGFloat
    private let tint: Color
    private let track: Color

    public init(fraction: Double, width: CGFloat? = 28, height: CGFloat = 4, tint: Color = .white, track: Color = .white.opacity(0.3)) {
        self.fraction = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        self.width = width
        self.height = height
        self.tint = tint
        self.track = track
    }

    public var body: some View {
        Capsule()
            .fill(track)
            .overlay(alignment: .leading) {
                if let width {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(height, width * fraction))
                } else {
                    // Unknown width: a leading-anchored scale keeps it layout-free.
                    Capsule()
                        .fill(tint)
                        .scaleEffect(x: fraction, y: 1, anchor: .leading)
                }
            }
            .clipShape(.capsule)
            .frame(width: width, height: height)
            .accessibilityElement()
            .accessibilityLabel("Progression")
            .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}

#Preview("ProgressCapsule") {
    VStack(spacing: 12) {
        ProgressCapsule(fraction: 0.3)
        ProgressCapsule(fraction: 0.7, width: 40)
        ProgressCapsule(fraction: 0.5, width: nil, height: 3).frame(width: 200)
    }
    .padding(30)
    .background(.black)
}
