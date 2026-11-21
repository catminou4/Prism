import SwiftUI

/// Cast & crew portrait: 96 pt circle (photo or monogram), name 12 medium, role 11 secondary.
public struct PersonCircle: View {
    private let name: String
    private let role: String?
    private let imageURL: URL?
    private let diameter: CGFloat
    private let action: (() -> Void)?

    public init(name: String, role: String? = nil, imageURL: URL? = nil, diameter: CGFloat = PrismMetrics.personDiameter, action: (() -> Void)? = nil) {
        self.name = name
        self.role = role
        self.imageURL = imageURL
        self.diameter = diameter
        self.action = action
    }

    public var body: some View {
        CardContainer(accessibilityLabel: Text([name, role].compactMap { $0 }.joined(separator: ", ")), action: action, menu: EmptyView()) { _ in
            VStack(spacing: 10) {
                RemoteImage(
                    url: imageURL, size: CGSize(width: diameter, height: diameter), placeholderSeed: name,
                    placeholderTitle: name, placeholderStyle: .monogram
                )
                .clipShape(.circle)
                .overlay { Circle().strokeBorder(.primary.opacity(0.06), lineWidth: 1) }
                VStack(spacing: 2) {
                    Text(name)
                        .font(PrismFont.personName)
                        .foregroundStyle(.primary)
                    if let role {
                        Text(role)
                            .font(PrismFont.personRole)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: diameter + 16)
            }
        }
    }
}

#Preview("PersonCircle") {
    HStack(alignment: .top, spacing: 20) {
        PersonCircle(name: "Adam Scott", role: "Mark")
        PersonCircle(name: "Patricia Arquette", role: "Harmony Cobel")
        PersonCircle(name: "Ben Stiller", role: "Réalisation")
    }
    .padding(40)
}
