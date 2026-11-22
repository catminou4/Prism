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
    /// Chip chrome. `.glass` is the Liquid Glass capsule; `.plain` is a flat fill —
    /// cheaper per chip for very long lists (no `glassEffect`, no hover tracking).
    public enum Style: Sendable, Hashable {
        case glass
        case plain
    }

    private let items: [ChipItem]
    @Binding private var selection: String?
    private let horizontalMargin: CGFloat
    private let style: Style
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(items: [ChipItem], selection: Binding<String?>, horizontalMargin: CGFloat = PrismMetrics.contentMargin, style: Style = .glass) {
        self.items = items
        _selection = selection
        self.horizontalMargin = horizontalMargin
        self.style = style
    }

    public var body: some View {
        ScrollView(.horizontal) {
            Group {
                if style == .glass {
                    GlassEffectContainer(spacing: 8) { chips }
                } else {
                    chips
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .scrollIndicators(.never)
        .scrollClipDisabled()
        .contentMargins(.horizontal, horizontalMargin, for: .scrollContent)
        .accessibilityElement(children: .contain)
    }

    private var chips: some View {
        LazyHStack(spacing: 8) {
            ForEach(items) { item in
                Chip(item: item, isSelected: item.id == selection, namespace: namespace, style: style) {
                    withAnimation(PrismMotion.respecting(reduceMotion, PrismMotion.standard)) { selection = item.id }
                }
            }
        }
        .scrollTargetLayout()
        .padding(.vertical, 6)
    }
}

private struct Chip: View {
    let item: ChipItem
    let isSelected: Bool
    let namespace: Namespace.ID
    let style: ChipBar.Style
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let button = Button(action: action) {
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
            .background { chipFill }
            .modifier(ChipChrome(style: style))
            .contentShape(.capsule)
        }
        .buttonStyle(.pressable)
        .focusEffectDisabled()
        .accessibilityAddTraits(isSelected ? .isSelected : [])

        if style == .glass {
            button
                .onHover { hovering in
                    withAnimation(PrismMotion.respecting(reduceMotion, PrismMotion.quickFade)) { isHovered = hovering }
                }
        } else {
            button
        }
    }

    @ViewBuilder private var chipFill: some View {
        if isSelected {
            Capsule()
                .fill(selectedFill)
                .matchedGeometryEffect(id: "chip.indicator", in: namespace)
        } else if style == .plain {
            Capsule().fill(Color.primary.opacity(0.07))
        } else if isHovered {
            Capsule().fill(Color.primary.opacity(0.06))
        }
    }

    private var selectedFill: Color { colorScheme == .dark ? .white : Color(white: 0.1) }

    private var foreground: Color {
        if isSelected { return colorScheme == .dark ? .black : .white }
        return .primary
    }
}

/// Liquid Glass capsule for `.glass` chips; a hairline stroke for `.plain` ones.
private struct ChipChrome: ViewModifier {
    let style: ChipBar.Style

    func body(content: Content) -> some View {
        switch style {
        case .glass:
            content.prismGlass(.regular, in: .capsule, interactive: true)
        case .plain:
            content.overlay {
                Capsule().strokeBorder(.primary.opacity(0.10), lineWidth: 0.5).allowsHitTesting(false)
            }
        }
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
