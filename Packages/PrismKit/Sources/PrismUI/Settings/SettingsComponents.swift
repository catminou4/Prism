import SwiftUI
import PrismDesign

/// Building blocks of the Prism settings window, in the macOS 26 grouped-settings idiom:
/// rounded cards of hairline-separated rows under a semibold section header, with secondary
/// footnotes. Rows use small tinted icon tiles (System Settings generation) tinted with the
/// `PrismTint` palette so the window belongs to the same family as monograms and tiles.

// MARK: - Group container

/// A settings section: optional header, a rounded card of rows separated by hairlines,
/// optional footnote. Separators are inserted automatically between the rows.
struct SettingsGroup<Rows: View>: View {
    let title: String?
    let footer: String?
    /// Leading inset of the hairlines, aligned with the row labels.
    let separatorInset: CGFloat
    @ViewBuilder let rows: () -> Rows

    init(
        _ title: String? = nil,
        footer: String? = nil,
        separatorInset: CGFloat = SettingsMetrics.separatorInsetWithIcon,
        @ViewBuilder rows: @escaping () -> Rows
    ) {
        self.title = title
        self.footer = footer
        self.separatorInset = separatorInset
        self.rows = rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.headerSpacing) {
            if let title {
                Text(title)
                    .font(SettingsMetrics.headerFont)
                    .accessibilityAddTraits(.isHeader)
            }
            Group(subviews: rows()) { collection in
                let entries = Array(collection.enumerated())
                VStack(spacing: 0) {
                    ForEach(entries, id: \.element.id) { index, row in
                        row
                        if index < collection.count - 1 {
                            Divider()
                                .padding(.leading, separatorInset)
                        }
                    }
                }
                // The clip shapes the hover highlight of the first/last actionable rows.
                .clipShape(.rect(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
                .background(SettingsMetrics.cardFill, in: .rect(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
            }
            if let footer {
                Text(footer)
                    .font(SettingsMetrics.footerFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, SettingsMetrics.headerInset)
    }
}

// MARK: - Metrics

enum SettingsMetrics {
    /// Horizontal margin of the page content.
    static let pageMargin: CGFloat = 20
    /// Vertical gap between two groups.
    static let groupSpacing: CGFloat = 24
    /// Gap between the header and its card, and between the card and its footnote.
    static let headerSpacing: CGFloat = 7
    /// Extra leading inset aligning headers/footers with the card edge.
    static let headerInset: CGFloat = 2
    static let cardRadius: CGFloat = 10
    /// Fill of the cards — the same panel fill as the source sheets and detail panels.
    static let cardFill = PrismColors.panelFill
    /// Row horizontal padding.
    static let rowPadding: CGFloat = 12
    /// Minimum row height.
    static let rowMinHeight: CGFloat = 38
    /// Icon tile side.
    static let iconSize: CGFloat = 24
    /// Gap between the icon tile and the label.
    static let iconSpacing: CGFloat = 10
    /// Hairline inset when rows carry an icon tile (padding + tile + gap).
    static let separatorInsetWithIcon: CGFloat = rowPadding + iconSize + iconSpacing
    /// Hairline inset for icon-less rows.
    static let separatorInsetPlain: CGFloat = rowPadding

    static let headerFont: Font = .system(size: 13, weight: .semibold)
    static let rowFont: Font = .system(size: 13)
    static let rowSubtitleFont: Font = .system(size: 11)
    static let footerFont: Font = .system(size: 11)
}

// MARK: - Icon tile

/// Small rounded-square tile with a white glyph on a `PrismTint` gradient —
/// the System Settings row icon, in the same colour family as `Monogram`.
struct SettingsIconTile: View {
    let symbol: String
    let tint: PrismTint
    var size: CGFloat = SettingsMetrics.iconSize

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: (size * 0.5).rounded(), weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Row

/// One settings row: icon tile, label (optional subtitle), trailing control.
/// The visible label is hidden from accessibility — interactive rows (toggle, picker,
/// button) carry their own label so VoiceOver never reads it twice.
struct SettingsRow<Trailing: View>: View {
    let icon: SettingsIconTile?
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let trailing: () -> Trailing

    @Environment(\.isEnabled) private var isEnabled

    init(
        symbol: String,
        tint: PrismTint,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        icon = SettingsIconTile(symbol: symbol, tint: tint)
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: SettingsMetrics.iconSpacing) {
            HStack(spacing: SettingsMetrics.iconSpacing) {
                if let icon {
                    icon
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SettingsMetrics.rowFont)
                        .accessibilityHidden(true)
                    if let subtitle {
                        Text(subtitle)
                            .font(SettingsMetrics.rowSubtitleFont)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .opacity(isEnabled ? 1 : 0.5)
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, SettingsMetrics.rowPadding)
        .padding(.vertical, 7)
        .frame(minHeight: SettingsMetrics.rowMinHeight)
    }
}

extension SettingsRow where Trailing == EmptyView {
    /// A purely informative row without trailing control.
    init(symbol: String, tint: PrismTint, title: String, subtitle: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Row controls

/// Trailing switch carrying the accessible label of its row.
struct SettingsToggle: View {
    let label: String
    @Binding var isOn: Bool

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        _isOn = isOn
    }

    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
    }
}

/// Small glass capsule button for actions inside rows (the sheets' `.glass` button,
/// rendered through the shared pipeline so snapshots stay faithful).
struct SettingsCapsuleButton: View {
    enum Role {
        case normal
        case destructive
    }

    let title: String
    var systemImage: String? = nil
    var role: Role = .normal
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: 26)
            .contentShape(.capsule)
        }
        .buttonStyle(SettingsCapsuleStyle(role: role))
    }
}

private struct SettingsCapsuleStyle: ButtonStyle {
    let role: SettingsCapsuleButton.Role

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, role: role)
    }

    struct StyleBody: View {
        let configuration: Configuration
        let role: SettingsCapsuleButton.Role
        @State private var isHovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(role == .destructive ? Color.red : Color.primary)
                .prismGlass(.regular, in: .capsule, interactive: true)
                .overlay { Capsule().fill(.white).opacity(isHovered ? 0.08 : 0).allowsHitTesting(false) }
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
                .opacity(isEnabled ? 1 : 0.45)
                .animation(PrismMotion.press, value: configuration.isPressed)
                .animation(PrismMotion.quickFade, value: isHovered)
                .onHover { isHovered = $0 }
        }
    }
}

/// API-key entry row: label line, then a wide secure field with its save capsule —
/// keys are long, the field gets the full row width instead of a cramped trailing slot.
struct SettingsKeyRow: View {
    let symbol: String
    let tint: PrismTint
    let title: String
    @Binding var text: String
    let saveTitle: String
    let saveAccessibilityLabel: String
    var saveEnabled: Bool = true
    let save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: SettingsMetrics.iconSpacing) {
                SettingsIconTile(symbol: symbol, tint: tint)
                Text(title)
                    .font(SettingsMetrics.rowFont)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                SecureField(title, text: $text)
                    .textFieldStyle(.roundedBorder)
                SettingsCapsuleButton(title: saveTitle, action: save)
                    .accessibilityLabel(saveAccessibilityLabel)
                    .disabled(!saveEnabled)
            }
            .padding(.leading, SettingsMetrics.iconSize + SettingsMetrics.iconSpacing)
        }
        .padding(.horizontal, SettingsMetrics.rowPadding)
        .padding(.vertical, 9)
    }
}

/// A full-width clickable row (opens a sheet or runs an action), in the spirit of the
/// add-source choices: hover highlight, optional trailing chevron.
struct SettingsActionRow: View {
    let symbol: String
    let tint: PrismTint
    let title: String
    var subtitle: String? = nil
    var destructive = false
    var chevron = false
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: SettingsMetrics.iconSpacing) {
                SettingsIconTile(symbol: symbol, tint: destructive ? .red : tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SettingsMetrics.rowFont)
                        .foregroundStyle(destructive ? Color.red : Color.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(SettingsMetrics.rowSubtitleFont)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, SettingsMetrics.rowPadding)
            .padding(.vertical, 7)
            .frame(minHeight: SettingsMetrics.rowMinHeight)
            .contentShape(.rect)
            .background {
                if isHovered && isEnabled {
                    Rectangle().fill(.primary.opacity(0.05))
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(PrismMotion.respecting(reduceMotion, PrismMotion.quickFade), value: isHovered)
        .onHover { isHovered = $0 }
    }
}
