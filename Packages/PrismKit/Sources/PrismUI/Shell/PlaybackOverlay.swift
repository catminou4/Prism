import PrismDesign
import SwiftUI

/// Window-level presenter for the playback sheet. Unlike `.sheet`, it can open the sheet out of
/// the card that was clicked (Apple TV zoom) and fold it back into that card when closing.
///
/// The transition starts from an exact copy of the card (`sourceView`), drawn over the real card,
/// which the page hides meanwhile (`isShowingSource(_:)`): the first frame is the card itself.
/// The copy grows with a panel and cross-fades into it while the card's artwork flies into the
/// sheet's hero band; the sheet content then fades in over the same picture. Closing runs the
/// same frames backwards and ends on the card again.
///
/// The flying artwork is the very image the sheet's hero displays (same URL, size and crop, so
/// the same cache entry), and the sheet keeps its own hero artwork hidden while it flies
/// (`showsHeroArtwork`): the moving picture is never cross-faded with a still copy of itself
/// (no double image), and the hero takes over only once the flight has settled on it. Until that
/// image is decoded, a small decode of the same artwork stands in. The zoom waits for the first
/// of the two and for the sheet's synopsis, at most `preparationBudget`.
@Observable
final class PlaybackOverlayModel {
    struct Presentation: Identifiable {
        let id = UUID()
        /// Layout frame of the originating card in global coordinates; `nil` zooms from the centre.
        let source: CGRect?
        /// Identifies the card, so its page can hide it while the copy stands in for it.
        let sourceID: AnyHashable?
        /// A copy of the card, laid out at `source`'s size.
        let sourceView: AnyView?
        let content: (CGSize) -> AnyView
    }

    private(set) var presentation: Presentation?
    /// Animated 0 → 1 once the sheet is ready, back to 0 before removal.
    fileprivate(set) var expanded = false
    /// The artwork flying into the hero band: the hero's own image, or a small stand-in.
    fileprivate(set) var flightArtwork: CGImage?
    /// False while the flight stands in for the sheet's hero artwork (the sheet hides its own).
    private(set) var showsHeroArtwork = true
    /// Whether the flight is drawn: from the start of the opening until the hero has taken over,
    /// and again while closing from an unscrolled sheet.
    fileprivate(set) var flightActive = false
    /// Reported by the sheet: its hero sits at its resting place (not scrolled away), so the
    /// flight can take its place when closing.
    @ObservationIgnored var heroAtRest = true
    /// Visual scale of the card when the transition leaves it (hover lift when opening by click),
    /// 1 when closing so the copy lands on the card at rest.
    fileprivate(set) var sourceScale: CGFloat = 1
    @ObservationIgnored private var closingID: UUID?
    @ObservationIgnored private var openedID: UUID?
    @ObservationIgnored private var artworkPending = false
    @ObservationIgnored private var artworkURL: URL?
    @ObservationIgnored private var contentPending = false

    /// Critically damped: decelerates into place without overshooting (no settle wobble).
    static let openAnimation = Animation.smooth(duration: 0.5)
    static let closeAnimation = Animation.smooth(duration: 0.4)
    /// Longest the zoom waits before starting anyway.
    static let preparationBudget = Duration.milliseconds(160)
    /// Stand-in decode: a few milliseconds from the card's download already on disk.
    private static let standInPixelSize = CGSize(width: 640, height: 360)

    var isPresented: Bool { presentation != nil }

    /// Whether the card `id` is currently stood in for by the overlay (its page hides it).
    func isShowingSource(_ id: some Hashable) -> Bool {
        presentation?.sourceID == AnyHashable(id)
    }

    func present(
        from source: CGRect?, artwork: URL? = nil, sourceID: AnyHashable? = nil, sourceScale: CGFloat = 1,
        sourceView: (some View)? = Optional<EmptyView>.none, content: @escaping (CGSize) -> some View
    ) {
        closingID = nil
        openedID = nil
        expanded = false
        self.sourceScale = sourceScale
        let presentation = Presentation(
            source: source, sourceID: source == nil ? nil : sourceID,
            sourceView: source == nil ? nil : sourceView.map { AnyView($0) }
        ) { AnyView(content($0)) }
        self.presentation = presentation
        contentPending = true
        flightArtwork = nil
        artworkURL = source == nil ? nil : artwork
        artworkPending = artworkURL != nil
        showsHeroArtwork = artworkURL == nil
        flightActive = artworkURL != nil
        heroAtRest = true
    }

    /// Loads the flying artwork once the host knows the hero's pixel size: the hero's own image
    /// (joining the hero's load of it), with a small stand-in if that one is not decoded yet.
    fileprivate func prepareFlight(_ id: UUID, heroPixelSize: CGSize) {
        guard presentation?.id == id, let url = artworkURL else { return }
        let pipeline = ImagePipeline.shared
        if let hero = pipeline.cachedImage(for: url, pixelSize: heroPixelSize, fitting: .landscapeFill) {
            flightArtwork = hero
            artworkPending = false
            openIfReady(id)
            return
        }
        if let standIn = pipeline.cachedImage(for: url, pixelSize: Self.standInPixelSize, fitting: .landscapeFill) {
            flightArtwork = standIn
            artworkPending = false
            openIfReady(id)
        } else {
            Task { [weak self] in
                let standIn = await pipeline.image(for: url, pixelSize: Self.standInPixelSize, fitting: .landscapeFill)
                guard let self, self.presentation?.id == id, artworkPending else { return }
                flightArtwork = standIn
                artworkPending = false
                openIfReady(id)
            }
        }
        Task { [weak self] in
            let hero = await pipeline.image(for: url, pixelSize: heroPixelSize, fitting: .landscapeFill)
            guard let self, self.presentation?.id == id, let hero else { return }
            // Upgrades the stand-in, even mid-flight: same picture, same crop, sharper.
            flightArtwork = hero
            if artworkPending {
                artworkPending = false
                openIfReady(id)
            }
        }
    }

    /// Called by the presented sheet once its first frame is final.
    func contentReady() {
        guard let id = presentation?.id else { return }
        contentPending = false
        openIfReady(id)
    }

    func dismiss() {
        guard let id = presentation?.id, closingID != id else { return }
        closingID = id
        guard openedID == id else {
            // Closed before the zoom started: only the card copy is on screen, identical to the card.
            presentation = nil
            closingID = nil
            flightArtwork = nil
            return
        }
        // Invisible at progress 1; makes the copy land on the card at rest.
        sourceScale = 1
        // The flight takes the hero's place before it moves (same image, same frame); not if the
        // sheet is scrolled, where the hero is elsewhere: the panel then closes on its own.
        let flies = flightArtwork != nil && heroAtRest
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            flightActive = flies
            if flies { showsHeroArtwork = false }
        }
        withAnimation(Self.closeAnimation) {
            expanded = false
        } completion: { [weak self] in
            guard let self, closingID == id, presentation?.id == id else { return }
            presentation = nil
            closingID = nil
            flightArtwork = nil
            flightActive = false
            showsHeroArtwork = true
        }
    }

    private func openIfReady(_ id: UUID) {
        if !artworkPending, !contentPending { open(id) }
    }

    fileprivate func open(_ id: UUID) {
        guard presentation?.id == id, closingID == nil, openedID != id else { return }
        openedID = id
        // Without its artwork the flight cannot stand in for the hero: let the sheet show its own.
        if flightArtwork == nil {
            showsHeroArtwork = true
            flightActive = false
        }
        withAnimation(Self.openAnimation, completionCriteria: .removed) {
            expanded = true
        } completion: { [weak self] in
            // Fully settled (not just perceptually done): the hero lands exactly on the flight.
            guard let self, presentation?.id == id, closingID == nil, !showsHeroArtwork else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                showsHeroArtwork = true
            } completion: { [weak self] in
                // The hero covers it now; retire it so scrolling never reveals it.
                guard let self, presentation?.id == id, closingID == nil else { return }
                flightActive = false
            }
        }
    }
}

extension EnvironmentValues {
    /// Set by `LibraryShell`; pages present the playback sheet through it when available.
    @Entry var playbackOverlay: PlaybackOverlayModel? = nil
    /// The overlay hosting the current view (the playback sheet), if any — used to close it.
    @Entry var hostingPlaybackOverlay: PlaybackOverlayModel? = nil
}

/// Dim layer + transitioning sheet, laid over the whole split view.
struct PlaybackOverlayHost: View {
    let model: PlaybackOverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            if let presentation = model.presentation {
                let origin = proxy.frame(in: .global).origin
                let size = TitlePlaybackSheet.size(for: proxy.size)
                let target = CGRect(
                    x: ((proxy.size.width - size.width) / 2).rounded(),
                    y: ((proxy.size.height - size.height) / 2).rounded(),
                    width: size.width, height: size.height
                )
                ZStack(alignment: .topLeading) {
                    Color.black
                        .opacity(model.expanded ? 0.42 : 0)
                        .contentShape(.rect)
                        .onTapGesture { model.dismiss() }
                        .accessibilityHidden(true)
                    presentation.content(proxy.size)
                        .environment(\.hostingPlaybackOverlay, model)
                        .modifier(SheetTransition(
                            progress: model.expanded ? 1 : 0,
                            card: presentation.source?.offsetBy(dx: -origin.x, dy: -origin.y),
                            cardScale: model.sourceScale,
                            cardView: presentation.sourceView,
                            target: target,
                            heroHeight: TitlePlaybackSheet.heroHeight(for: size),
                            artwork: model.flightActive ? model.flightArtwork : nil,
                            pixelScale: displayScale,
                            fadeOnly: reduceMotion
                        ))
                        .accessibilityAddTraits(.isModal)
                }
                .id(presentation.id)
                .task(id: presentation.id) {
                    model.prepareFlight(
                        presentation.id,
                        heroPixelSize: RemoteImage.pixelSize(
                            forPointSize: CGSize(width: size.width, height: TitlePlaybackSheet.heroHeight(for: size)), scale: displayScale
                        )
                    )
                    try? await Task.sleep(for: PlaybackOverlayModel.preparationBudget)
                    if !Task.isCancelled { model.open(presentation.id) }
                }
            }
        }
        .allowsHitTesting(model.isPresented)
    }
}

/// Draws, for one `progress` value (so every part stays in sync and the animation reverses):
/// 1. a panel growing from the card to the sheet frame, its colour going from the card's dark
///    fill to the page background, over a pre-rendered shadow scaled with it;
/// 2. the card artwork flying from the card's image area into the hero band, with the card's
///    bottom fade at first and the hero's leading scrim at the end;
/// 3. the copy of the card, scaled with the panel and fading out early: at progress 0 the
///    overlay is pixel-for-pixel the card;
/// 4. the sheet itself, laid out once at its final position, revealed inside the panel and
///    faded in once the artwork is almost in place (same picture, so no double image).
///
/// Built for 120 Hz and a clean landing:
/// - moving and growing pieces use transforms (drawn at exact sub-pixel positions), never
///   `.offset` or layout sizes, which are drawn on whole pixels and made slow moves step;
/// - crop edges are snapped to device pixels, so the sheet always sits on whole pixels: it is
///   never resampled mid-flight and does not sharpen ("settle") on the last frame;
/// - every crop is a layout frame plus a rounded-rect clip (no offscreen mask pass), the sheet is
///   never scaled, and the shadow is blurred once.
private struct SheetTransition: ViewModifier, Animatable {
    var progress: CGFloat
    /// The card's layout frame, in the overlay's coordinates.
    let card: CGRect?
    /// The card's visual scale around its centre (hover lift) where the transition leaves it.
    let cardScale: CGFloat
    let cardView: AnyView?
    let target: CGRect
    let heroHeight: CGFloat
    let artwork: CGImage?
    /// Device pixels per point, for snapping crop edges.
    let pixelScale: CGFloat
    /// Reduce Motion: no zoom, only a cross-fade.
    let fadeOnly: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private static let sheetRadius: CGFloat = 26
    private static let cardFill = Color(white: 0.10)
    private static let shadowBleed: CGFloat = 64
    /// The episode card's image is its 16:9 area plus this much, fading into the caption.
    private static let cardImageExtra: CGFloat = 31

    func body(content: Content) -> some View {
        let p = min(max(progress, 0), 1)
        let card = fadeOnly ? nil : card
        let visibleCard = card.map { rect in
            rect.insetBy(dx: rect.width * (1 - cardScale) / 2, dy: rect.height * (1 - cardScale) / 2)
        }
        let start = fadeOnly ? target : visibleCard ?? target.insetBy(dx: target.width * 0.025, dy: target.height * 0.025)
        let exactPanel = Self.lerp(start, target, p)
        let panel = snapped(exactPanel)
        let radius = Self.lerp(card == nil ? Self.sheetRadius : PrismMetrics.wideRadius * cardScale, Self.sheetRadius, p)
        let flies = visibleCard != nil && artwork != nil
        // From a card the panel is there from the first frame and the sheet fades in over it;
        // from nowhere everything fades in together.
        let panelOpacity = card == nil ? p : 1
        // While the flight stands in for the hero, the sheet has no artwork to double: its text
        // and sections can fade in as soon as the panel is large enough.
        let reveal = card == nil ? p : Self.smoothstep(flies ? 0.3 : 0.2, flies ? 0.8 : 0.7, p)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack(alignment: .topLeading) {
            // Rasterised once at the final size, then only scaled to follow the panel: a
            // transform, instead of re-blurring a resizing shape on every frame. The plate sits
            // under the opaque panel, so only the shadow shows.
            RoundedRectangle(cornerRadius: Self.sheetRadius, style: .continuous)
                .fill(PrismColors.pageBackground)
                .frame(width: target.width - 8, height: target.height - 8)
                .shadow(color: .black.opacity(0.32), radius: 30, y: 14)
                .padding(Self.shadowBleed)
                .drawingGroup()
                .padding(-Self.shadowBleed)
                .transformEffect(Self.transform(
                    scaleX: exactPanel.width / target.width, y: exactPanel.height / target.height,
                    to: CGPoint(x: exactPanel.minX + 4 * exactPanel.width / target.width, y: exactPanel.minY + 4 * exactPanel.height / target.height)
                ))
                .opacity(Self.smoothstep(0.05, 0.6, p))
                .allowsHitTesting(false)

            ZStack {
                PrismColors.pageBackground
                if card != nil {
                    Self.cardFill.opacity(1 - Self.smoothstep(0.1, 0.6, p))
                }
            }
            .frame(width: panel.width, height: panel.height)
            .clipShape(shape)
            .offset(x: panel.minX, y: panel.minY)
            .opacity(panelOpacity)
            .allowsHitTesting(false)

            if let card, let visibleCard, let artwork {
                flight(artwork, card: card, visibleCard: visibleCard, progress: p, reveal: reveal, radius: radius)
            }

            if let card, let cardView {
                // The card copy keeps its aspect and is cropped by the panel as that widens. It
                // stays in the tree at opacity 0 so closing never inserts it mid-animation.
                let copyScale = exactPanel.width / card.width
                cardView
                    .frame(width: card.width, height: card.height)
                    .transformEffect(Self.transform(
                        scaleX: copyScale, y: copyScale,
                        to: CGPoint(x: exactPanel.minX - panel.minX, y: exactPanel.minY - panel.minY)
                    ))
                    .frame(width: panel.width, height: panel.height, alignment: .topLeading)
                    .clipShape(shape)
                    // The hover lift's shadow, which the hidden card was casting.
                    .shadow(color: PrismColors.hoverShadow.opacity(cardScale > 1 ? 1 - Self.smoothstep(0, 0.2, p) : 0), radius: 18, y: 10)
                    .offset(x: panel.minX, y: panel.minY)
                    .opacity(1 - Self.smoothstep(0, 0.24, p))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            content
                .frame(width: target.width, height: target.height, alignment: .topLeading)
                .offset(x: target.minX - panel.minX, y: target.minY - panel.minY)
                .frame(width: panel.width, height: panel.height, alignment: .topLeading)
                .clipShape(shape)
                .offset(x: panel.minX, y: panel.minY)
                .opacity(reveal)
        }
    }

    /// The card artwork, aspect-filled and top-aligned like the card and `HeroBackdrop`. It
    /// starts as the card's image area (16:9 plus the strip fading into the caption) and ends as
    /// the hero band, with the hero's leading scrim faded in.
    ///
    /// The image keeps one layout size (its size at the end) and is scaled by a transform, so it
    /// grows continuously; only the crop follows the pixel-snapped rect.
    private func flight(
        _ artwork: CGImage, card: CGRect, visibleCard: CGRect, progress p: CGFloat, reveal: CGFloat, radius: CGFloat
    ) -> some View {
        let scale = visibleCard.width / max(card.width, 1)
        let imageHeight = min(card.height, (card.width / PrismMetrics.wideAspectRatio).rounded() + Self.cardImageExtra)
        let from = CGRect(x: visibleCard.minX, y: visibleCard.minY, width: visibleCard.width, height: imageHeight * scale)
        let to = CGRect(x: target.minX, y: target.minY, width: target.width, height: heroHeight)
        let exact = Self.lerp(from, to, p)
        // As the sheet fades in, the crop's bottom is pulled up to the hero band's, so the
        // picture never shows under the sheet's sections (it still grows underneath the crop).
        let overflow = max(0, exact.maxY - to.maxY) * reveal
        let crop = snapped(CGRect(x: exact.minX, y: exact.minY, width: exact.width, height: exact.height - overflow))
        let aspect = CGFloat(artwork.width) / CGFloat(max(artwork.height, 1))
        let finalWidth = max(to.width, to.height * aspect)
        let width = max(exact.width, exact.height * aspect)
        return Color.clear
            .frame(width: crop.width, height: crop.height)
            .overlay(alignment: .topLeading) {
                Image(decorative: artwork, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: finalWidth, height: finalWidth / aspect)
                    .transformEffect(Self.transform(
                        scaleX: width / finalWidth, y: width / finalWidth,
                        to: CGPoint(x: exact.midX - width / 2 - crop.minX, y: exact.minY - crop.minY)
                    ))
            }
            .overlay {
                // The card's fade into its caption, as a colour overlay rather than a mask.
                LinearGradient(
                    stops: [.init(color: Self.cardFill.opacity(0), location: 0.48), .init(color: Self.cardFill, location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
                .opacity(1 - Self.smoothstep(0.1, 0.55, p))
            }
            .overlay {
                // `HeroBackdrop`'s scrims (leading 0.75, dark bottom), so that at rest the flight
                // is drawn exactly like the hero it stands in for.
                ZStack {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.75), location: 0),
                            .init(color: .black.opacity(0.75 * 0.42), location: 0.33),
                            .init(color: .clear, location: 0.64),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0.42),
                        .init(color: .black.opacity(0.30), location: 0.76),
                        .init(color: .black.opacity(0.70), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
                .opacity(Self.smoothstep(0.15, 0.85, p))
            }
            // Uniform radius: a plain layer corner radius, not a mask pass. The bottom corners end
            // under the opaque sheet, so they never need to square off.
            .clipShape(.rect(cornerRadius: radius, style: .continuous))
            .offset(x: crop.minX, y: crop.minY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Scale about the top-leading corner, then move it to `origin`. Unlike `.offset`, which is
    /// drawn at whole pixels (a slow move then advances in visible one-pixel jumps), a transform
    /// is drawn at its exact sub-pixel position.
    private static func transform(scaleX: CGFloat, y scaleY: CGFloat, to origin: CGPoint) -> CGAffineTransform {
        CGAffineTransform(a: scaleX, b: 0, c: 0, d: scaleY, tx: origin.x, ty: origin.y)
    }

    /// `rect` with its edges on device pixels.
    private func snapped(_ rect: CGRect) -> CGRect {
        let scale = max(pixelScale, 1)
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let minX = snap(rect.minX), minY = snap(rect.minY)
        return CGRect(x: minX, y: minY, width: snap(rect.maxX) - minX, height: snap(rect.maxY) - minY)
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    private static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t),
            width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t)
        )
    }

    private static func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
