import SwiftUI

extension EnvironmentValues {
    /// Column width chosen by the enclosing `Shelf`/grid. Cards use it when no explicit width is given.
    @Entry public var prismCardWidth: CGFloat? = nil
    /// The enclosing card is hovered: its artwork casts the lift shadow.
    @Entry var prismCardLifted: Bool = false
    /// A scroll container is scrolling: cards suspend hover lift/shadow and skip hover tracking.
    @Entry public var prismIsScrollingContent: Bool = false
    /// `false` for pages hidden below the top of a page stack or in an unselected section.
    /// Set by PrismUI's `PageStack`/`LibraryShell`; cards use it to skip eager work on
    /// unreachable pages.
    @Entry public var isPageActive: Bool = true
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

/// Size carrier for the card interaction inside-test. A reference type so the geometry
/// write at mount does not invalidate the card for a second render — the size is only read
/// inside gesture callbacks, never for layout or visuals.
private final class CardSizeBox {
    var size = CGSize.zero
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
    @GestureState private var pressing = false
    @State private var dragInside = true
    @State private var sizeBox = CardSizeBox()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.prismSnapshotHover) private var forcedHover
    @ScrollingContent private var isScrollingContent

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

    /// Inside test for the zero-distance drag interaction, in the card's local coordinate
    /// space. Matches the hit region defined by `.contentShape(.rect)`.
    private func inside(_ location: CGPoint) -> Bool {
        let size = sizeBox.size
        return location.x >= 0 && location.y >= 0 && location.x <= size.width && location.y <= size.height
    }

    var body: some View {
        // Keep the interaction, artwork and accessibility elements mounted when the scroll
        // phase changes. Replacing them also restarts the artwork tasks for visible cards.
        //
        // The activation interaction is a zero-distance drag gesture rather than a `Button`:
        // replacing the button saved a consistent 30–50 ms of CPU per shelf-scroll pass in the
        // interleaved mount probe (≈6–9 % of total), while reproducing the button behaviour
        // exactly (verified by CardInteractionProbeTests): press feedback
        // while held, unpress when dragged out, re-press on re-entry, activation only when
        // released inside, full suppression when the click lands on the nested `…` menu, and
        // accessibility activation through `.accessibilityAction(.default)`.
        Group {
            if let action {
                content(isHovered)
                    .contentShape(.rect)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { sizeBox.size = $0 }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .updating($pressing) { _, state, _ in state = true }
                            .onChanged { value in
                                let inside = inside(value.location)
                                if inside != dragInside { dragInside = inside }
                            }
                            .onEnded { value in
                                if inside(value.location) { action() }
                                dragInside = true
                            }
                    )
                    .hoverLiftEffect(
                        isHovered: isHovered, isPressed: pressing && dragInside, scale: hoverScale,
                        pressedScale: 0.97, shadow: false, reduceMotion: reduceMotion
                    )
                    .accessibilityAction(.default) { action() }
                    // A cancelled gesture never reaches `onEnded`: reset the inside tracking
                    // whenever the press ends so the next interaction starts clean.
                    .onChange(of: pressing) { _, pressed in
                        if !pressed { dragInside = true }
                    }
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
            if !inside || !isScrollingContent { hovering = inside }
        }
        .onChange(of: hovering && isScrollingContent) { _, shouldReset in
            if shouldReset { hovering = false }
        }
        .focusEffectDisabled()
        .modifier(OptionalContextMenu(menu: menu))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(action == nil ? [] : .isButton)
    }
}

struct OptionalContextMenu<MenuContent: View>: ViewModifier {
    let menu: () -> MenuContent
    @ScrollingContent private var isScrollingContent
    @Environment(\.isPageActive) private var isPageActive

    func body(content: Content) -> some View {
        if MenuContent.self == EmptyView.self {
            content
        } else {
            content
                .contextMenu { menu() }
                .accessibilityActions {
                    // Defer menu construction while the card moves or its page is hidden.
                    if !isScrollingContent && isPageActive { menu() }
                }
        }
    }
}

func isEmptyMenu<M: View>(_ type: M.Type) -> Bool { type == EmptyView.self }
