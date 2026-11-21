import SwiftUI

/// Circular tinted monogram (profile avatar, sources, people without portraits).
public struct Monogram: View {
    private let initials: String
    private let tint: PrismTint
    private let size: CGFloat

    /// - Parameters:
    ///   - text: A name; its initials are displayed (`Louis Faust` → `LF`).
    ///   - tint: Background tint; defaults to a deterministic tint derived from `text`.
    public init(text: String, tint: PrismTint? = nil, size: CGFloat = 28) {
        initials = Monogram.initials(from: text)
        self.tint = tint ?? .forSeed(text)
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(tint.gradient)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// Up to two uppercase initials (letters/digits only).
    public nonisolated static func initials(from text: String) -> String {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        if letters.isEmpty { return "?" }
        return letters.joined()
    }
}

#Preview("Monogram") {
    HStack(spacing: 12) {
        Monogram(text: "Louis Faust")
        Monogram(text: "Source A", tint: .purple, size: 40)
        Monogram(text: "Canal+", tint: .orange, size: 56)
    }
    .padding(30)
}
