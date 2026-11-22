import SwiftUI

/// One chip of a `ChipBar`.
nonisolated public struct ChipItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String?
    public let count: Int?

    public init(id: String, title: String, systemImage: String? = nil, count: Int? = nil) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.count = count
    }
}

/// Horizontal glass category chips (Live TV categories, filters). The selected chip is
/// white with black text; the white indicator slides between chips.
public struct ChipBar: View {
    private let items: [ChipItem]
    @Binding private var selection: String?
    private let horizontalMargin: CGFloat
    @Namespace private var namespace

    public init(items: [ChipItem], selection: Binding<String?>, horizontalMargin: CGFloat = PrismMetrics.contentMargin) {
        self.items = items
        _selection = selection
        self.horizontalMargin = horizontalMargin
    }

    public var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                LazyHStack(spacing: 8) {
                    ForEach(items) { item in
                        Chip(item: item, isSelected: item.id == selection, namespace: namespace) {
                            withAnimation(PrismMotion.standard) { selection = item.id }
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 6)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .scrollIndicators(.never)
        .scrollClipDisabled()
        .contentMargins(.horizontal, horizontalMargin, for: .scrollContent)
        .accessibilityElement(children: .contain)
    }
}

private struct Chip: View {
    let item: ChipItem
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol = item.systemImage {
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                }
                Text(item.title)
                    .font(PrismFont.chip)
                    .lineLimit(1)
                if let count = item.count {
                    Text(count, format: .number)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .opacity(0.6)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(height: PrismMetrics.capsuleHeight)
            .background {
                if isSelected {
                    Capsule()
                        .fill(selectedFill)
                        .matchedGeometryEffect(id: "chip.indicator", in: namespace)
                } else if isHovered {
                    Capsule().fill(Color.primary.opacity(0.06))
                }
            }
            .prismGlass(.regular, in: .capsule, interactive: true)
            .contentShape(.capsule)
        }
        .buttonStyle(.pressable)
        .onHover { hovering in
            withAnimation(PrismMotion.quickFade) { isHovered = hovering }
        }
        .focusEffectDisabled()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var selectedFill: Color { colorScheme == .dark ? .white : Color(white: 0.1) }

    private var foreground: Color {
        if isSelected { return colorScheme == .dark ? .black : .white }
        return .primary
    }
}

#Preview("ChipBar") {
    @Previewable @State var selection: String? = "all"
    ChipBar(
        items: [
            ChipItem(id: "all", title: "Toutes", count: 12_453),
            ChipItem(id: "fav", title: "Favorites", systemImage: "star.fill"),
            ChipItem(id: "sport", title: "Sport"),
            ChipItem(id: "news", title: "Info"),
            ChipItem(id: "kids", title: "Jeunesse"),
            ChipItem(id: "cinema", title: "Cinéma"),
        ],
        selection: $selection
    )
    .frame(width: 700)
    .padding(.vertical, 30)
}
