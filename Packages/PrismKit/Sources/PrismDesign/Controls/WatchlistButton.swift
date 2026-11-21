import SwiftUI

/// Hero secondary circle: `plus` ↔ `checkmark` with a symbol replace transition.
public struct WatchlistButton: View {
    private let isAdded: Bool
    private let size: CGFloat
    private let action: () -> Void

    public init(isAdded: Bool, size: CGFloat = PrismMetrics.circleButtonSize, action: @escaping () -> Void) {
        self.isAdded = isAdded
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: isAdded ? "checkmark" : "plus")
                .font(.system(size: (size * 0.42).rounded(), weight: .medium))
                .contentTransition(.symbolEffect(.replace.downUp))
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(GlassCircleStyle(style: .dark))
        .animation(PrismMotion.standard, value: isAdded)
        .accessibilityLabel(isAdded ? "Retirer de Ma liste" : "Ajouter à Ma liste")
        .accessibilityAddTraits(isAdded ? .isSelected : [])
    }
}

#Preview("WatchlistButton") {
    @Previewable @State var added = false
    HStack(spacing: 12) {
        PrimaryCapsuleButton("Lecture", systemImage: "play.fill") {}
        WatchlistButton(isAdded: added) { added.toggle() }
    }
    .padding(40)
    .background(.black)
}
