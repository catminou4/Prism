import SwiftUI

/// `Titre >` shelf header (17 bold + chevron), clickable when `action` is set, with an
/// optional 13 pt secondary subtitle.
public struct ShelfHeader<Accessory: View>: View {
    private let title: String
    private let subtitle: String?
    private let action: (() -> Void)?
    private let accessory: Accessory
    @State private var isHovered = false

    public init(_ title: String, subtitle: String? = nil, action: (() -> Void)? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.action = action
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                titleRow
                if let subtitle {
                    Text(subtitle)
                        .font(PrismFont.shelfSubtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            accessory
        }
    }

    @ViewBuilder private var titleRow: some View {
        let label = HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
                .font(PrismFont.shelfTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(PrismFont.shelfChevron)
                    .foregroundStyle(.secondary)
                    .offset(x: isHovered ? 2 : 0)
            }
        }
        if let action {
            Button(action: action) { label.contentShape(.rect) }
                .buttonStyle(.plain)
                .opacity(isHovered ? 0.72 : 1)
                .onHover { hovering in withAnimation(PrismMotion.hover) { isHovered = hovering } }
                .focusEffectDisabled()
                .accessibilityLabel(Text(title))
                .accessibilityHint("Afficher tout")
        } else {
            label.accessibilityAddTraits(.isHeader)
        }
    }
}

extension ShelfHeader where Accessory == EmptyView {
    public init(_ title: String, subtitle: String? = nil, action: (() -> Void)? = nil) {
        self.init(title, subtitle: subtitle, action: action) { EmptyView() }
    }

    /// Matches `ShelfHeader(title:subtitle:action:)`.
    public init(title: String, subtitle: String? = nil, action: (() -> Void)? = nil) {
        self.init(title, subtitle: subtitle, action: action) { EmptyView() }
    }
}

/// Shelf header whose title is a menu (`Saison 1 ⌃⌄` season picker).
public struct ShelfMenuHeader<MenuContent: View>: View {
    private let title: String
    private let menu: MenuContent
    @State private var isHovered = false

    public init(_ title: String, @ViewBuilder menu: () -> MenuContent) {
        self.title = title
        self.menu = menu()
    }

    public var body: some View {
        Menu {
            menu
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(title)
                    .font(PrismFont.shelfTitle)
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(isHovered ? 0.72 : 1)
        .onHover { hovering in withAnimation(PrismMotion.hover) { isHovered = hovering } }
        .focusEffectDisabled()
        .accessibilityLabel(Text(title))
        .accessibilityHint("Choisir une saison")
    }
}

#Preview("ShelfHeader") {
    VStack(alignment: .leading, spacing: 20) {
        ShelfHeader("Continuer", action: {})
        ShelfHeader("À ne pas manquer", subtitle: "Disponible en VF.", action: {})
        ShelfHeader("Distribution")
        ShelfMenuHeader("Saison 1") {
            Button("Saison 1") {}
            Button("Saison 2") {}
        }
    }
    .padding(40)
    .frame(width: 500)
}
