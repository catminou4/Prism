import SwiftUI

/// Truncated description followed by the Apple TV `PLUS` pill.
///
/// When the text overflows `lineLimit`, the pill sits at the trailing end of the last
/// visible line and the text fades out right before it. Clicking opens a popover with the
/// full text (`.popover`, the Mac behaviour) or expands in place (`.inline`).
public struct ExpandableText: View {
    public enum Expansion: Sendable {
        case popover
        case inline
    }

    private let text: Text
    private let plainText: String
    private let lineLimit: Int
    private let font: Font
    private let moreTitle: String
    private let expansion: Expansion
    private let popoverTitle: String?
    private let lineSpacing: CGFloat

    @State private var isTruncated = false
    @State private var isExpanded = false
    @State private var lineHeight: CGFloat = 16
    @State private var pillWidth: CGFloat = 50
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - text: Full description.
    ///   - emphasis: Optional bold prefix (`S1, É1 · Titre :`), rendered inline.
    public init(
        _ text: String,
        emphasis: String? = nil,
        lineLimit: Int = 2,
        font: Font = PrismFont.heroBody,
        moreTitle: String = "PLUS",
        expansion: Expansion = .popover,
        popoverTitle: String? = nil,
        lineSpacing: CGFloat = PrismFont.heroLineSpacing
    ) {
        self.lineSpacing = lineSpacing
        if let emphasis, !emphasis.isEmpty {
            self.text = Text("\(Text(emphasis).fontWeight(.semibold)) \(text)")
        } else {
            self.text = Text(text)
        }
        plainText = [emphasis, text].compactMap { $0 }.joined(separator: " ")
        self.lineLimit = lineLimit
        self.font = font
        self.moreTitle = moreTitle
        self.expansion = expansion
        self.popoverTitle = popoverTitle
    }

    /// Matches `ExpandableText(text:lineLimit:)`.
    public init(text: String, lineLimit: Int = 2) {
        self.init(text, lineLimit: lineLimit)
    }

    public var body: some View {
        let showsInlineFull = expansion == .inline && isExpanded
        text
            .font(font)
            .lineSpacing(lineSpacing)
            .lineLimit(showsInlineFull ? nil : lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mask { fadeMask(active: isTruncated && !showsInlineFull) }
            .overlay(alignment: .bottomTrailing) {
                if isTruncated || showsInlineFull {
                    pill
                        .offset(y: max(0, (18 - lineHeight) / 2))
                }
            }
            .background(alignment: .topLeading) { truncationProbe }
            .background(alignment: .topLeading) { lineProbe }
            // Only inline expansion re-lays the text out; popover mode has nothing to animate.
            .animation(
                expansion == .inline ? PrismMotion.respecting(reduceMotion, PrismMotion.standard) : nil,
                value: isExpanded
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(plainText))
            .accessibilityAction(named: Text("Afficher plus")) { isExpanded = true }
    }

    private var pill: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Text(expansion == .inline && isExpanded ? "MOINS" : moreTitle)
                .font(PrismFont.plusPill)
                .tracking(0.3)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 10)
                .frame(height: 18)
                .background(.white.opacity(0.16), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.pressable)
        .focusEffectDisabled()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pillWidth = $0 }
        .popover(isPresented: popoverBinding, arrowEdge: .bottom) {
            ExpandedTextPopover(title: popoverTitle, text: text)
        }
        .accessibilityLabel("Afficher plus")
    }

    private var popoverBinding: Binding<Bool> {
        Binding(get: { expansion == .popover && isExpanded }, set: { isExpanded = $0 })
    }

    /// Opaque everywhere except a fade before the pill on the last line.
    private func fadeMask(active: Bool) -> some View {
        VStack(spacing: 0) {
            Rectangle()
            HStack(spacing: 0) {
                Rectangle()
                if active {
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 28)
                    Color.clear.frame(width: pillWidth + 2)
                }
            }
            .frame(height: lineHeight + lineSpacing / 2)
        }
    }

    /// Full text laid out invisibly to detect truncation (cheap: one extra text layout).
    private var truncationProbe: some View {
        text
            .font(font)
            .lineSpacing(lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight in
                let limit = CGFloat(lineLimit) * (lineHeight + lineSpacing)
                isTruncated = fullHeight > limit + lineHeight * 0.5
            }
            .accessibilityHidden(true)
    }

    private var lineProbe: some View {
        Text(verbatim: "Ag")
            .font(font)
            .lineLimit(1)
            .hidden()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { lineHeight = $0 }
            .accessibilityHidden(true)
    }
}

private struct ExpandedTextPopover: View {
    let title: String?
    let text: Text

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let title {
                    Text(title).font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
                text
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(16)
            .frame(width: 360, alignment: .leading)
        }
        .frame(maxHeight: 320)
        .fixedSize(horizontal: false, vertical: true)
        // The hero uses white text in both system appearances. Give the popover its own
        // opaque surface so the native light popover material cannot wash that text out.
        .background(Color(white: 0.13))
    }
}

#Preview("ExpandableText") {
    VStack(alignment: .leading, spacing: 30) {
        ExpandableText(
            "Mark is promoted to lead a team of employees whose memories have been surgically divided between their work and personal lives.",
            emphasis: "S1, É1 · Good News About Hell:"
        )
        ExpandableText("Une phrase courte qui tient.")
    }
    .foregroundStyle(.white.opacity(0.82))
    .frame(width: 280)
    .padding(40)
    .background(.black)
}
