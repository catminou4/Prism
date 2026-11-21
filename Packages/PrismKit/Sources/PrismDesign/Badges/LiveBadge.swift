import SwiftUI

/// Red `EN DIRECT` capsule with an optional pulsing dot.
public struct LiveBadge: View {
    private let title: String
    private let pulsing: Bool
    private let compact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ title: String = "EN DIRECT", pulsing: Bool = true, compact: Bool = false) {
        self.title = title
        self.pulsing = pulsing
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: 4) {
            if pulsing {
                Circle()
                    .fill(.white)
                    .frame(width: 5, height: 5)
                    .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.35]) { dot, opacity in
                        dot.opacity(opacity)
                    } animation: { _ in .easeInOut(duration: 0.9) }
            }
            Text(title)
                .font(.system(size: compact ? 9 : 10, weight: .bold))
                .tracking(0.3)
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, compact ? 5 : 6)
        .frame(height: compact ? 14 : 16)
        .background(PrismColors.live, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("En direct")
    }
}

#Preview("LiveBadge") {
    HStack(spacing: 10) {
        LiveBadge()
        LiveBadge(pulsing: false)
        LiveBadge("LIVE", compact: true)
    }
    .padding(30)
}
