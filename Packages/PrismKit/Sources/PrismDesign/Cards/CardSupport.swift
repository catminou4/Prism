import SwiftUI

extension EnvironmentValues {
    /// Column width chosen by the enclosing `Shelf`/grid. Cards use it when no explicit width is given.
    @Entry public var prismCardWidth: CGFloat? = nil
    /// The enclosing card is hovered: its artwork casts the lift shadow.
    @Entry var prismCardLifted: Bool = false
    /// A scroll container is scrolling: cards suspend hover lift/shadow and skip hover tracking.
    @Entry public var prismIsScrollingContent: Bool = false
}

extension View {
    /// Sets the width cards adopt when they are not given an explicit width.
    public func prismCardWidth(_ width: CGFloat?) -> some View {
        environment(\.prismCardWidth, width)
    }
}

/// Artwork clipped to a continuous rounded rectangle with Apple's 1 pt inner hairline.
struct ArtworkSurface<Content: View>: View {
    let radius: CGFloat
    let content: Content

    init(radius: CGFloat, @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.content = content()
    }

    @Environment(\.prismCardLifted) private var lifted
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(PrismColors.artworkStroke, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .background {
                // Only hovered artwork allocates a shadow layer.
                if lifted && !reduceMotion {
                    shape.fill(.black)
                        .shadow(color: PrismColors.hoverShadow, radius: 18, y: 10)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(PrismMotion.hover, value: lifted)
    }
}

/// Apple TV "16:9 artwork + caption band" background: sharp artwork on top melting into a
/// pre-blurred, darkened copy that fills the band (cheap version of the system extension blur).
struct ExtendedArtwork: View {
    let url: URL?
    let seed: String
    let title: String?
    let size: CGSize
    let artworkHeight: CGFloat
    /// Fraction of the artwork height where the sharp image starts melting into the blur.
    var meltStart: CGFloat = 0.72
    var darkening: Double = 0.28

    var body: some View {
        let artworkSize = CGSize(width: size.width, height: artworkHeight)
        ZStack(alignment: .top) {
            // The colour band uses the same decoded artwork as the sharp card.
            RemoteImage(url: url, size: size, placeholderSeed: seed, placeholderStyle: .none, blurRadius: 24)
                .blursArtwork(sized: artworkSize)
                .overlay(Color.black.opacity(darkening))
            RemoteImage(url: url, size: artworkSize, placeholderSeed: seed, placeholderTitle: title)
                .mask {
                    LinearGradient(
                        stops: [.init(color: .black, location: 0), .init(color: .black, location: meltStart), .init(color: .clear, location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }
}

/// `…` button revealed at full opacity on hover; opens the card menu.
struct CardMenuButton<MenuContent: View>: View {
    let isHovered: Bool
    /// Evaluated when the menu opens, not on every card render.
    let menu: () -> MenuContent

    var body: some View {
        Menu {
            menu()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 22)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(isHovered ? 0.95 : 0.6)
        .accessibilityLabel("Plus d'options")
    }
}

// CardContainer tracks the hover used by the artwork and menu.
private struct CardPressStyle: ButtonStyle {
    let isHovered: Bool
    let hoverScale: CGFloat
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.rect)
            .hoverLiftEffect(
                isHovered: isHovered, isPressed: configuration.isPressed, scale: hoverScale,
                pressedScale: 0.97, shadow: false, reduceMotion: reduceMotion
            )
    }
}

/// Shared card behaviour: optional action, hover lift + press scale on the whole card
/// (including overlays like the `…` menu), context menu, accessibility.
struct CardContainer<Content: View, MenuContent: View>: View {
    let accessibilityLabel: Text
    let action: (() -> Void)?
    var hoverScale: CGFloat = 1.04
    /// Built lazily: context menu and `…` menu only evaluate it when opened.
    let menu: () -> MenuContent
    let content: (_ isHovered: Bool) -> Content

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.prismSnapshotHover) private var forcedHover
    @Environment(\.prismIsScrollingContent) private var isScrollingContent

    private var isHovered: Bool { (hovering || forcedHover) && !isScrollingContent }

    init(
        accessibilityLabel: Text,
        action: (() -> Void)?,
        hoverScale: CGFloat = 1.04,
        menu: @escaping () -> MenuContent,
        @ViewBuilder content: @escaping (_ isHovered: Bool) -> Content
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.action = action
        self.hoverScale = hoverScale
        self.menu = menu
        self.content = content
    }

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    content(isHovered)
                }
                .buttonStyle(CardPressStyle(isHovered: isHovered, hoverScale: hoverScale, reduceMotion: reduceMotion))
            } else {
                content(isHovered)
                    .hoverLiftEffect(
                        isHovered: isHovered, isPressed: false, scale: hoverScale,
                        pressedScale: 0.97, shadow: false, reduceMotion: reduceMotion
                    )
            }
        }
        .environment(\.prismCardLifted, isHovered)
        .onHover { inside in
            // Hover churn while scrolling costs a full card re-evaluation per card crossed.
            guard !isScrollingContent else { return }
            hovering = inside
        }
        .onChange(of: isScrollingContent) { _, scrolling in
            // Drop stale hover state: missed exits would otherwise leave a lift behind.
            if !scrolling { hovering = false }
        }
        .modifier(OptionalContextMenu(menu: menu))
        .focusEffectDisabled()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(action == nil ? [] : .isButton)
    }
}

struct OptionalContextMenu<MenuContent: View>: ViewModifier {
    let menu: () -> MenuContent

    func body(content: Content) -> some View {
        if MenuContent.self == EmptyView.self {
            content
        } else {
            content
                .contextMenu { menu() }
                .accessibilityActions { menu() }
        }
    }
}

func isEmptyMenu<M: View>(_ type: M.Type) -> Bool { type == EmptyView.self }
