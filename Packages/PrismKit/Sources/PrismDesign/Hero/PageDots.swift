import SwiftUI

/// Apple-style page indicator: 6 pt dots, active white, inactive white 35 %; with more pages
/// than `maxVisible`, the dots at the window edges shrink to hint at more content.
public struct PageDots: View {
    private let count: Int
    private let index: Int
    private let maxVisible: Int
    private let dotSize: CGFloat
    private let spacing: CGFloat
    private let onSelect: ((Int) -> Void)?

    public init(count: Int, index: Int, maxVisible: Int = 8, dotSize: CGFloat = 6, spacing: CGFloat = 10, onSelect: ((Int) -> Void)? = nil) {
        self.count = max(count, 0)
        self.index = min(max(index, 0), max(count - 1, 0))
        self.maxVisible = max(maxVisible, 3)
        self.dotSize = dotSize
        self.spacing = spacing
        self.onSelect = onSelect
    }

    /// First visible page, keeping the active dot away from the shrinking edges when possible.
    private var windowStart: Int {
        guard count > maxVisible else { return 0 }
        return min(max(index - (maxVisible - 3), 0), count - maxVisible)
    }

    public var body: some View {
        let start = windowStart
        let visible = min(count, maxVisible)
        let pitch = dotSize + spacing
        HStack(spacing: spacing) {
            ForEach(0..<count, id: \.self) { page in
                Circle()
                    .fill(.white)
                    .opacity(page == index ? 1 : 0.35)
                    .frame(width: dotSize, height: dotSize)
                    .scaleEffect(scale(for: page, start: start))
                    .contentShape(.circle.inset(by: -4))
                    .onTapGesture { onSelect?(page) }
            }
        }
        .offset(x: -CGFloat(start) * pitch)
        .frame(width: CGFloat(visible) * pitch - spacing, alignment: .leading)
        .clipped()
        .animation(PrismMotion.standard, value: index)
        .accessibilityElement()
        .accessibilityLabel("Page \(index + 1) sur \(count)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSelect?(min(index + 1, count - 1))
            case .decrement: onSelect?(max(index - 1, 0))
            @unknown default: break
            }
        }
    }

    private func scale(for page: Int, start: Int) -> CGFloat {
        guard count > maxVisible else { return 1 }
        let end = start + maxVisible - 1
        if page < start || page > end { return 0.4 }
        let hasBefore = start > 0, hasAfter = end < count - 1
        if hasAfter && page == end { return 0.55 }
        if hasAfter && page == end - 1 { return 0.8 }
        if hasBefore && page == start { return 0.55 }
        if hasBefore && page == start + 1 { return 0.8 }
        return 1
    }
}

#Preview("PageDots") {
    VStack(spacing: 16) {
        PageDots(count: 5, index: 1)
        PageDots(count: 12, index: 1)
        PageDots(count: 12, index: 6)
        PageDots(count: 12, index: 11)
    }
    .padding(30)
    .background(.black)
}
