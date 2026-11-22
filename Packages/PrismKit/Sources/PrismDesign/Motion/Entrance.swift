import SwiftUI

extension PrismMotion {
    /// Rows and cards arriving from below while the page scrolls.
    public static let entrance: Animation = .smooth(duration: 0.5)
    /// Hero copy settling after its artwork.
    public static let reveal: Animation = .smooth(duration: 0.55)
    /// Delay between consecutive elements of a staggered reveal.
    public static let revealStep: Double = 0.055
}

extension View {
    /// Fades and lifts the view in when it scrolls into a vertical page from the bottom edge, like
    /// rows on Apple TV and the big streaming services. Content above the viewport is left alone,
    /// so scrolling back up never flickers. Only opacity and transforms animate.
    public func rowEntrance() -> some View {
        modifier(RowEntrance())
    }

    /// Fades and lifts the view in `order` steps after `isPresented` becomes true. Used for hero
    /// copy: the label, the title, the facts and the buttons arrive one after the other.
    public func staggeredReveal(_ isPresented: Bool, order: Int, distance: CGFloat = 14) -> some View {
        modifier(StaggeredReveal(isPresented: isPresented, order: order, distance: distance))
    }
}

private struct RowEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.prismSnapshotRendering) private var isSnapshot

    func body(content: Content) -> some View {
        if isSnapshot {
            content
        } else {
            let moves = !reduceMotion
            content.scrollTransition(.animated(PrismMotion.entrance).threshold(.visible(0.08)), axis: .vertical) { view, phase in
                view
                    .opacity(phase.value > 0 ? 0 : 1)
                    .scaleEffect(phase.value > 0 && moves ? 0.97 : 1, anchor: .top)
                    .offset(y: phase.value > 0 && moves ? 28 : 0)
            }
        }
    }
}

private struct StaggeredReveal: ViewModifier {
    let isPresented: Bool
    let order: Int
    let distance: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.prismSnapshotRendering) private var isSnapshot

    func body(content: Content) -> some View {
        let shown = isPresented || isSnapshot
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : distance)
            .animation(
                reduceMotion ? .easeOut(duration: 0.2) : PrismMotion.reveal.delay(Double(order) * PrismMotion.revealStep),
                value: isPresented
            )
    }
}
