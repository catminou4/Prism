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
    @Environment(\.prismIsScrollingContent) private var isScrollingContent

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let surface = content
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(PrismColors.artworkStroke, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        // `lifted` can only be true while not scrolling (cards gate hover on it), so the
        // shadow branch and its animation modifiers are skipped entirely mid-scroll —
        // shelf materialization stays on the cheapest path.
        if isScrollingContent {
            surface
        } else {
            Group {
                if lifted && !reduceMotion {
                    surface
                        .background {
                            // Only hovered artwork allocates a shadow layer.
                            shape.fill(.black)
                                .shadow(color: PrismColors.hoverShadow, radius: 18, y: 10)
                                .transition(.opacity)
                                .allowsHitTesting(false)
                        }
                } else {
                    surface
                }
            }
            .animation(PrismMotion.hover, value: lifted)
        }
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
            bandPlaceholderOrImage(artworkSize: artworkSize)
                .overlay(Color.black.opacity(darkening))
            sharpPlaceholderOrImage(artworkSize: artworkSize)
                .mask {
                    LinearGradient(
                        stops: [.init(color: .black, location: 0), .init(color: .black, location: meltStart), .init(color: .clear, location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    /// `RemoteImage`'s nil-URL path produces exactly this tree; skipping the loader's
    /// node, state and environment reads keeps wide-card materialization cheap.
    @ViewBuilder private func bandPlaceholderOrImage(artworkSize: CGSize) -> some View {
        if let url {
            RemoteImage(url: url, size: size, placeholderSeed: seed, placeholderStyle: .none, blurRadius: 24)
                .blursArtwork(sized: artworkSize)
        } else {
            // `.clipped()` would be a no-op: the placeholder fills its frame exactly.
            PlaceholderArtwork(seed: seed)
                .frame(width: size.width, height: size.height)
        }
    }

    @ViewBuilder private func sharpPlaceholderOrImage(artworkSize: CGSize) -> some View {
        if let url {
            RemoteImage(url: url, size: artworkSize, placeholderSeed: seed, placeholderTitle: title)
        } else {
            PlaceholderArtwork(seed: seed, title: title)
                .frame(width: artworkSize.width, height: artworkSize.height)
        }
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
        // While a scroll container is moving, cards take a lean path: a tap gesture
        // replaces the Button's control machinery, and the hover/lift environment and
        // tracking modifiers are skipped — shelves materialize ~8 cards in a single
        // layout pass and every saved node counts. The untaken branch is never
        // instantiated, so these modifiers cost nothing during the scroll itself.
        Group {
            if isScrollingContent {
                if let action {
                    content(isHovered)
                        .contentShape(.rect)
                        .onTapGesture { action() }
                } else {
                    content(isHovered)
                }
            } else {
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
                    hovering = inside
                }
                .focusEffectDisabled()
            }
        }
        .onChange(of: isScrollingContent) { _, scrolling in
            // Drop stale hover state: missed exits would otherwise leave a lift behind.
            if !scrolling { hovering = false }
        }
        .modifier(OptionalContextMenu(menu: menu))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(action == nil ? [] : .isButton)
        .modifier(CardDefaultAction(action: action))
    }
}

/// During scroll, cards activate through a tap gesture instead of a `Button`, so the
/// default accessibility action (VoiceOver activation) must be attached explicitly —
/// applied after `accessibilityElement(children: .combine)` so it lands on the merged
/// element. Outside scroll the `Button` already provides it.
private struct CardDefaultAction: ViewModifier {
    let action: (() -> Void)?
    @Environment(\.prismIsScrollingContent) private var isScrollingContent

    func body(content: Content) -> some View {
        if isScrollingContent, let action {
            content.accessibilityAction { action() }
        } else {
            content
        }
    }
}

struct OptionalContextMenu<MenuContent: View>: ViewModifier {
    let menu: () -> MenuContent
    @Environment(\.prismIsScrollingContent) private var isScrollingContent

    func body(content: Content) -> some View {
        if MenuContent.self == EmptyView.self {
            content
        } else if isScrollingContent {
            // `.contextMenu` is lazy, but `.accessibilityActions` makes SwiftUI evaluate
            // the menu content for every card's accessibility node — on shelves that is
            // ~8 extra view subtrees per layout pass. The actions return as soon as the
            // scroll settles.
            content.contextMenu { menu() }
        } else {
            content
                .contextMenu { menu() }
                .accessibilityActions { menu() }
        }
    }
}

func isEmptyMenu<M: View>(_ type: M.Type) -> Bool { type == EmptyView.self }
