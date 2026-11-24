import PrismDesign
import SwiftUI

/// Window-level presenter for the playback sheet. Unlike `.sheet`, it can grow the sheet out of
/// the card that opened it (Apple TV zoom) and shrink it back into that card when closing.
@Observable
final class PlaybackOverlayModel {
    struct Presentation: Identifiable {
        let id = UUID()
        /// Frame of the originating card in global coordinates; `nil` zooms from the centre.
        let source: CGRect?
        let content: (CGSize) -> AnyView
    }

    private(set) var presentation: Presentation?
    /// Animated 0 → 1 once the overlay is inserted, back to 0 before removal.
    fileprivate(set) var expanded = false
    @ObservationIgnored private var closingID: UUID?

    static let openAnimation = Animation.smooth(duration: 0.5, extraBounce: 0.04)
    static let closeAnimation = Animation.smooth(duration: 0.38)

    var isPresented: Bool { presentation != nil }

    func present(from source: CGRect?, content: @escaping (CGSize) -> some View) {
        closingID = nil
        expanded = false
        presentation = Presentation(source: source) { AnyView(content($0)) }
    }

    func dismiss() {
        guard let id = presentation?.id, closingID != id else { return }
        closingID = id
        withAnimation(Self.closeAnimation) {
            expanded = false
        } completion: { [weak self] in
            guard let self, closingID == id, presentation?.id == id else { return }
            presentation = nil
            closingID = nil
        }
    }

    fileprivate func didAppear(_ id: UUID) {
        guard presentation?.id == id, closingID == nil else { return }
        withAnimation(Self.openAnimation) { expanded = true }
    }
}

extension EnvironmentValues {
    /// Set by `LibraryShell`; pages present the playback sheet through it when available.
    @Entry var playbackOverlay: PlaybackOverlayModel? = nil
    /// The overlay hosting the current view (the playback sheet), if any — used to close it.
    @Entry var hostingPlaybackOverlay: PlaybackOverlayModel? = nil
}

/// Dim layer + zooming sheet, laid over the whole split view.
struct PlaybackOverlayHost: View {
    let model: PlaybackOverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                let source = reduceMotion ? nil : presentation.source?.offsetBy(dx: -origin.x, dy: -origin.y)
                ZStack(alignment: .topLeading) {
                    Color.black
                        .opacity(model.expanded ? 0.42 : 0)
                        .contentShape(.rect)
                        .onTapGesture { model.dismiss() }
                        .accessibilityHidden(true)
                    presentation.content(proxy.size)
                        .environment(\.hostingPlaybackOverlay, model)
                        .modifier(ZoomFromSource(
                            progress: model.expanded ? 1 : 0, source: source, target: target, fadeOnly: reduceMotion
                        ))
                        .accessibilityAddTraits(.isModal)
                }
                .id(presentation.id)
                .onAppear { model.didAppear(presentation.id) }
            }
        }
        .allowsHitTesting(model.isPresented)
    }
}

/// Places a `target`-sized view so that at `progress` 0 it exactly covers `source` (scaled down,
/// cropped to the source's aspect from the top, with the card's corner radius) and at 1 fills
/// `target`. One animatable value drives frame, crop, radius and shadow so they stay in sync.
private struct ZoomFromSource: ViewModifier, Animatable {
    var progress: CGFloat
    let source: CGRect?
    let target: CGRect
    /// Reduce Motion: no zoom, only a cross-fade.
    let fadeOnly: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private static let sheetRadius: CGFloat = 26

    func body(content: Content) -> some View {
        let p = min(max(progress, 0), 1.2)
        let start = fadeOnly ? target : source ?? target.insetBy(dx: target.width * 0.03, dy: target.height * 0.03)
        let rect = CGRect(
            x: lerp(start.minX, target.minX, p), y: lerp(start.minY, target.minY, p),
            width: lerp(start.width, target.width, p), height: lerp(start.height, target.height, p)
        )
        // Fill the current rect, cropping the sheet around its horizontal centre and from the top
        // (the hero artwork), so the first frame covers the card exactly.
        let scale = max(rect.width / target.width, rect.height / target.height, 0.01)
        let cropped = CGSize(width: min(target.width, rect.width / scale), height: min(target.height, rect.height / scale))
        let inset = ((target.width - cropped.width) / 2).rounded()
        let visibleRadius = lerp(source == nil ? Self.sheetRadius : PrismMetrics.wideRadius, Self.sheetRadius, min(p, 1))
        let shape = RoundedRectangle(cornerRadius: visibleRadius / scale, style: .continuous)
        content
            .frame(width: target.width, height: target.height, alignment: .topLeading)
            .mask(alignment: .topLeading) {
                shape.frame(width: cropped.width, height: cropped.height).offset(x: inset)
            }
            .background(alignment: .topLeading) {
                shape
                    .fill(PrismColors.pageBackground)
                    .frame(width: cropped.width, height: cropped.height)
                    .shadow(color: .black.opacity(0.32 * min(p, 1)), radius: 40 / scale, y: 18 / scale)
                    .offset(x: inset)
            }
            .scaleEffect(scale, anchor: .topLeading)
            .offset(x: rect.minX - inset * scale, y: rect.minY)
            // From a card the artwork is already on screen; from nowhere, fade in with the scale.
            .opacity(source == nil ? min(p, 1) : min(1, 0.2 + p * 4))
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
}
