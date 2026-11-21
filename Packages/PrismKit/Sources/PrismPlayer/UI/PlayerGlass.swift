import SwiftUI

/// Player measurements in points.
public enum PlayerMetrics {
    /// Outer margin of every control group.
    public static let margin: CGFloat = 16
    /// Bottom margin of the scrubber.
    public static let bottomMargin: CGFloat = 14
    public static let panelRadius: CGFloat = 20
    public static let artworkRadius: CGFloat = 8
    /// Top inset below the traffic lights (windowed).
    public static let windowedTopInset: CGFloat = 30
    public static let capsuleHeight: CGFloat = 35
    public static let capsuleSymbolSize: CGFloat = 15.5
    public static let capsuleButtonWidth: CGFloat = 36.5
    /// Bottom-right menu buttons are packed slightly tighter.
    public static let menuButtonWidth: CGFloat = 35
    public static let capsulePadding: CGFloat = 3
    public static let skipDiameter: CGFloat = 40
    public static let playDiameter: CGFloat = 52
    public static let skipSymbolSize: CGFloat = 19
    public static let playSymbolSize: CGFloat = 24
    public static let centerSpacing: CGFloat = 14
    public static let scrubberHeight: CGFloat = 32
    public static let scrubberPadding: CGFloat = 16.5
    public static let trackHeight: CGFloat = 6
    public static let knobSize = CGSize(width: 20, height: 16)
    public static let timeFontSize: CGFloat = 10.5
    /// Volume slider width including the knob overhang.
    public static let volumeSliderWidth: CGFloat = 120
    public static let titleSize: CGFloat = 26
    public static let sidePanelWidth: CGFloat = 340
    public static let controlsFade: Double = 0.25
    /// Gap between the title row and the scrubber.
    public static let rowSpacing: CGFloat = 15
}

extension EnvironmentValues {
    /// Offscreen snapshot rendering: Liquid Glass cannot be captured by `CALayer.render(in:)`,
    /// so glass surfaces draw an opaque approximation instead.
    @Entry public var playerSnapshotRendering: Bool = false
}

/// Liquid Glass surface used by every player control (dark appearance, over video).
struct PlayerGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.playerSnapshotRendering) private var snapshot
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(white: 0.16), in: shape)
        } else if snapshot {
            content.background {
                shape.fill(Color(white: 0.125))
                    .overlay {
                        shape.fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.07), location: 0),
                                    .init(color: .clear, location: 0.3),
                                    .init(color: .clear, location: 0.75),
                                    .init(color: .white.opacity(0.06), location: 1),
                                ],
                                startPoint: .top, endPoint: .bottom))
                    }
                    .overlay {
                        shape.stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.42), .white.opacity(0.08), .white.opacity(0.26)],
                                startPoint: .top, endPoint: .bottom),
                            lineWidth: 1)
                    }
            }
        } else {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        }
    }
}

extension View {
    /// Applies the player glass after layout modifiers (Liquid Glass rule).
    func playerGlass(_ shape: some Shape = Capsule(), interactive: Bool = false) -> some View {
        modifier(PlayerGlassModifier(shape: shape, interactive: interactive))
    }
}

/// Icon button living inside a glass capsule: no own background, hover highlight circle.
struct PlayerCapsuleButtonStyle: ButtonStyle {
    var width: CGFloat = PlayerMetrics.capsuleButtonWidth

    func makeBody(configuration: Configuration) -> some View {
        PlayerCapsuleButtonBody(configuration: configuration, width: width)
    }
}

private struct PlayerCapsuleButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let width: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(.system(size: PlayerMetrics.capsuleSymbolSize, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: width, height: PlayerMetrics.capsuleHeight - 2 * PlayerMetrics.capsulePadding)
            .background {
                Capsule()
                    .fill(.white.opacity(configuration.isPressed ? 0.22 : (hovering ? 0.14 : 0)))
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: hovering)
            .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: configuration.isPressed)
    }
}

/// Individual glass actions for the transport cluster.
struct PlayerTransportButtonStyle: ButtonStyle {
    let diameter: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        PlayerTransportButtonBody(configuration: configuration, diameter: diameter)
    }
}

private struct PlayerTransportButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let diameter: CGFloat
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = Circle()
        configuration.label
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .contentShape(shape)
            .playerGlass(shape, interactive: true)
            .overlay { shape.fill(.white.opacity(hovering ? 0.10 : 0)).allowsHitTesting(false) }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .smooth(duration: 0.23), value: hovering)
            .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: configuration.isPressed)
    }
}

/// Glass capsule grouping capsule buttons (top-left, bottom-right).
struct PlayerGlassCapsule<Content: View>: View {
    var horizontalPadding: CGFloat = PlayerMetrics.capsulePadding
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .padding(.horizontal, horizontalPadding)
            .frame(height: PlayerMetrics.capsuleHeight)
            .playerGlass(Capsule())
    }
}

/// White primary capsule ("Réessayer").
struct PlayerPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(Capsule().fill(.white))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// Glass secondary capsule ("Changer de source").
struct PlayerSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 30)
            .contentShape(Capsule())
            .playerGlass(Capsule(), interactive: true)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// Red `EN DIRECT` capsule.
public struct PlayerLiveBadge: View {
    var dimmed: Bool

    public init(dimmed: Bool = false) {
        self.dimmed = dimmed
    }

    public var body: some View {
        Text("EN DIRECT")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(Color(red: 0.92, green: 0.16, blue: 0.18).opacity(dimmed ? 0.45 : 1)))
            .fixedSize()
            .accessibilityLabel("En direct")
    }
}
