import SwiftUI

/// Centered native spinner over a dimmed last frame (+ "Reconnexion…" status).
struct PlayerLoadingOverlay: View {
    let message: String?

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.extraLarge)
                .tint(.white)
            if let message {
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message ?? "Chargement")
    }
}

/// Error card: `exclamationmark.triangle`, message, `Réessayer`, optional `Changer de source`.
struct PlayerErrorCard: View {
    let message: String
    let sourceOptions: [PlayerSourceOption]
    let onRetry: () -> Void
    let onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30, weight: .medium))
                .symbolRenderingMode(.multicolor)
            Text("Lecture impossible")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Réessayer", action: onRetry)
                    .buttonStyle(PlayerPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                if sourceOptions.count > 1 {
                    Menu {
                        SourceMenuContent(options: sourceOptions)
                    } label: {
                        Text("Changer de source")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(PlayerSecondaryButtonStyle())
                    .fixedSize()
                }
                if let onClose {
                    Button("Fermer", action: onClose)
                        .buttonStyle(PlayerSecondaryButtonStyle())
                }
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(width: 400)
        .playerGlass(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// "−10 s" / "+10 s" bubble shown above the matching skip button.
struct PlayerSkipBubble: View {
    let seconds: Int

    var body: some View {
        Text(PlayerFormat.skipLabel(seconds))
            .font(.system(size: 13, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .playerGlass(Capsule())
    }
}

/// Volume / mode HUD (keyboard changes).
struct PlayerHUD: View {
    let kind: PlayerFeedback.Kind

    var body: some View {
        HStack(spacing: 10) {
            switch kind {
            case .volume(let volume, let muted):
                Image(systemName: muted || volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    variableValue: Double(volume))
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 22)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white)
                        .frame(width: max(4, CGFloat(muted ? 0 : volume) * 120))
                }
                .frame(width: 120, height: 4)
                Text(muted ? "Muet" : "\(Int((volume * 100).rounded())) %")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            case .message(let text, let symbol):
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                Text(text)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            case .skip(let seconds):
                Text(PlayerFormat.skipLabel(seconds))
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 36)
        .playerGlass(Capsule())
    }
}

/// Stream information overlay (`I`), refreshed every second.
struct PlayerStreamInfoCard: View {
    let controller: PlayerController
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Informations sur le flux")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(PlayerCapsuleButtonStyle(width: 24))
                .frame(height: 24)
                .help("Fermer (I)")
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                ForEach(Array(controller.techInfo.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(row.value)
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .playerGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task {
            while !Task.isCancelled {
                controller.refreshTechInfo()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// "Épisode suivant" card with a countdown ring (VOD, last 30 s). Use it in the `upNext` slot.
public struct PlayerUpNextCard<Artwork: View>: View {
    let title: String
    let subtitle: String?
    let remaining: TimeInterval
    let countdown: TimeInterval
    let onPlay: () -> Void
    let onDismiss: (() -> Void)?
    let artwork: Artwork

    /// - Parameters:
    ///   - remaining: seconds left in the current item (`controller.remainingTime`).
    ///   - countdown: length of the countdown ring (30 s by default).
    public init(
        title: String, subtitle: String? = nil, remaining: TimeInterval, countdown: TimeInterval = 30,
        onPlay: @escaping () -> Void, onDismiss: (() -> Void)? = nil, @ViewBuilder artwork: () -> Artwork
    ) {
        self.title = title
        self.subtitle = subtitle
        self.remaining = remaining
        self.countdown = countdown
        self.onPlay = onPlay
        self.onDismiss = onDismiss
        self.artwork = artwork()
    }

    private var progress: Double {
        guard countdown > 0 else { return 1 }
        return min(1, max(0, 1 - remaining / countdown))
    }

    public var body: some View {
        HStack(spacing: 12) {
            artwork
                .frame(width: 112, height: 63)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("ÉPISODE SUIVANT")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button(action: onPlay) {
                ZStack {
                    Circle().stroke(.white.opacity(0.25), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                }
                .frame(width: 36, height: 36)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Lire maintenant")
            .accessibilityLabel("Lire l’épisode suivant")
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(width: 380)
        .playerGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.black.opacity(0.6)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityLabel("Masquer")
            }
        }
    }
}

extension PlayerUpNextCard where Artwork == Color {
    /// Card without artwork (neutral placeholder).
    public init(
        title: String, subtitle: String? = nil, remaining: TimeInterval, countdown: TimeInterval = 30,
        onPlay: @escaping () -> Void, onDismiss: (() -> Void)? = nil
    ) {
        self.init(
            title: title, subtitle: subtitle, remaining: remaining, countdown: countdown, onPlay: onPlay,
            onDismiss: onDismiss
        ) {
            Color.white.opacity(0.12)
        }
    }
}
