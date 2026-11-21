import SwiftUI

/// Hero label above the title: `Nouveau`, `Ajouté récemment`, `En direct`, `2026 Oscar® Winner`.
public struct LabelPill: View {
    private let text: String
    private let systemImage: String?

    public init(_ text: String, systemImage: String? = nil) {
        self.text = text
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 10, weight: .bold))
            }
            Text(text)
                .font(PrismFont.labelPill)
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(.white.opacity(0.08))
                .strokeBorder(.white.opacity(0.32), lineWidth: 1)
        }
    }
}

#Preview("LabelPill") {
    HStack(spacing: 10) {
        LabelPill("Nouveau")
        LabelPill("Ajouté récemment")
        LabelPill("En direct", systemImage: "dot.radiowaves.left.and.right")
    }
    .padding(30)
    .background(.black)
}
