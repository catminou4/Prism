import SwiftUI

/// Transient glass capsule message (`Ajouté à Ma liste`, `Source actualisée`).
public struct ToastView: View {
    private let message: String
    private let systemImage: String?
    private let tint: Color

    public init(_ message: String, systemImage: String? = nil, tint: Color = .accentColor) {
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .symbolEffect(.bounce, options: .nonRepeating)
            }
            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 36)
        .prismGlass(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// A toast message with identity (so repeated messages re-trigger the transition).
nonisolated public struct ToastMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public var systemImage: String?

    public init(_ text: String, systemImage: String? = nil) {
        id = UUID()
        self.text = text
        self.systemImage = systemImage
    }
}

extension View {
    /// Presents `message` as a toast at the bottom, auto-dismissed after `duration` seconds.
    public func toast(_ message: Binding<ToastMessage?>, duration: Double = 2.4) -> some View {
        modifier(ToastModifier(message: message, duration: duration))
    }
}

private struct ToastModifier: ViewModifier {
    @Binding var message: ToastMessage?
    let duration: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            ZStack {
                if let message {
                    ToastView(message.text, systemImage: message.systemImage)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.92)))
                        .id(message.id)
                        .task(id: message.id) {
                            try? await Task.sleep(for: .seconds(duration))
                            guard !Task.isCancelled else { return }
                            withAnimation(PrismMotion.standard) { self.message = nil }
                        }
                }
            }
            .padding(.bottom, 28)
            .animation(PrismMotion.standard, value: message)
        }
    }
}

#Preview("ToastView") {
    VStack(spacing: 16) {
        ToastView("Ajouté à Ma liste", systemImage: "checkmark.circle.fill")
        ToastView("Source actualisée · 12 453 chaînes", systemImage: "arrow.clockwise")
    }
    .padding(40)
}
