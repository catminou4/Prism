import SwiftUI

/// Circled age rating (`16+`, `18+`, `TP`) as in the hero metadata line.
public struct AgeRatingBadge: View {
    private let rating: String
    private let size: CGFloat

    public init(_ rating: String, size: CGFloat = 14) {
        self.rating = rating
        self.size = size
    }

    public var body: some View {
        Circle()
            .strokeBorder(.foreground, lineWidth: 1.1)
            .overlay {
                Text(rating)
                    .font(.system(size: size * (rating.count > 2 ? 0.42 : 0.5), weight: .bold))
                    .tracking(-0.3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 1.5)
            }
            .frame(width: size, height: size)
            .accessibilityLabel(Text("Déconseillé aux moins de \(rating.trimmingCharacters(in: CharacterSet(charactersIn: "+")))"))
    }
}

#Preview("AgeRatingBadge") {
    HStack(spacing: 10) {
        AgeRatingBadge("10+")
        AgeRatingBadge("12+")
        AgeRatingBadge("16+")
        AgeRatingBadge("18+", size: 18)
    }
    .foregroundStyle(.white.opacity(0.85))
    .padding(30)
    .background(.black)
}
