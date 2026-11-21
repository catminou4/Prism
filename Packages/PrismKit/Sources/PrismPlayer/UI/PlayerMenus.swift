import SwiftUI

/// One playable variant/source offered in the source menu (`rectangle.stack`) and on the error card.
public struct PlayerSourceOption: Identifiable {
    public let id: String
    /// "Source A", "Fournisseur 2".
    public var label: String
    /// "4K · VF · MKV".
    public var detail: String?
    public var isCurrent: Bool
    public var action: () -> Void

    public init(
        id: String = UUID().uuidString, label: String, detail: String? = nil, isCurrent: Bool = false,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.label = label
        self.detail = detail
        self.isCurrent = isCurrent
        self.action = action
    }

    var menuTitle: String {
        guard let detail, !detail.isEmpty else { return label }
        return "\(label) — \(detail)"
    }
}

/// Native macOS menus of the bottom-right capsule (styled like the Apple TV player menus).
struct PlayerMenuButton<Content: View>: View {
    let systemImage: String
    let help: String
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: systemImage)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(PlayerCapsuleButtonStyle(width: PlayerMetrics.menuButtonWidth))
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Subtitles: `Sous-titres` (Activés (langue) / Non), `Langue ▸`, `Style ▸`.
struct SubtitlesMenuContent: View {
    let controller: PlayerController

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { controller.selectedSubtitleID != nil },
            set: { enabled in
                if enabled {
                    let preferred = TrackAutoSelector.bestTrack(
                        in: controller.subtitleTracks,
                        preferredLanguage: controller.preferences.preferredSubtitleLanguage)
                    controller.select(subtitle: (preferred ?? controller.subtitleTracks.first)?.id)
                } else {
                    controller.select(subtitle: nil)
                }
            })
    }

    private var trackBinding: Binding<MediaTrack.ID?> {
        Binding(
            get: { controller.selectedSubtitleID },
            set: { controller.select(subtitle: $0) })
    }

    private var styleBinding: Binding<SubtitleStyle> {
        Binding(get: { controller.subtitleStyle }, set: { controller.setSubtitleStyle($0) })
    }

    private var enabledTitle: String {
        let selected = controller.subtitleTracks.first { $0.id == controller.selectedSubtitleID }
        let fallback =
            TrackAutoSelector.bestTrack(
                in: controller.subtitleTracks,
                preferredLanguage: controller.preferences.preferredSubtitleLanguage)
            ?? controller.subtitleTracks.first
        guard let name = (selected ?? fallback)?.name else { return "Activés" }
        return "Activés (\(name))"
    }

    var body: some View {
        Section("Sous-titres") {
            if controller.subtitleTracks.isEmpty {
                Text("Aucun sous-titre disponible")
            } else {
                Picker("Sous-titres", selection: enabledBinding) {
                    Text(enabledTitle).tag(true)
                    Text("Non").tag(false)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        Divider()
        Menu("Langue") {
            Picker("Langue", selection: trackBinding) {
                Text("Non").tag(MediaTrack.ID?.none)
                ForEach(controller.subtitleTracks) { track in
                    Text(track.name).tag(MediaTrack.ID?.some(track.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .disabled(controller.subtitleTracks.isEmpty)
        Menu("Style") {
            Picker("Style", selection: styleBinding) {
                ForEach(SubtitleStyle.allCases, id: \.self) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

/// Audio: `Audio` track list.
struct AudioMenuContent: View {
    let controller: PlayerController

    private var trackBinding: Binding<MediaTrack.ID?> {
        Binding(get: { controller.selectedAudioID }, set: { controller.select(audio: $0) })
    }

    var body: some View {
        Section("Audio") {
            if controller.audioTracks.isEmpty {
                Text("Piste par défaut")
            } else {
                Picker("Audio", selection: trackBinding) {
                    ForEach(controller.audioTracks) { track in
                        Text(track.name).tag(MediaTrack.ID?.some(track.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
    }
}

/// Speed + picture format: `Vitesse` 0,5×…2×, `Format` Ajuster/Remplir/Étirer (+ VLC aspect ratio).
struct SpeedMenuContent: View {
    let controller: PlayerController
    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    private var rateBinding: Binding<Float> {
        Binding(get: { controller.rate }, set: { controller.setRate($0) })
    }

    private var gravityBinding: Binding<VideoGravity> {
        Binding(get: { controller.videoGravity }, set: { controller.setVideoGravity($0) })
    }

    private var aspectBinding: Binding<VideoAspectRatio> {
        Binding(get: { controller.aspectRatio }, set: { controller.setAspectRatio($0) })
    }

    var body: some View {
        if !controller.isLive {
            Section("Vitesse") {
                Picker("Vitesse", selection: rateBinding) {
                    ForEach(Self.rates, id: \.self) { rate in
                        Text(rate == 1 ? "Normale" : PlayerFormat.rateLabel(rate)).tag(rate)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        Section("Format") {
            Picker("Format", selection: gravityBinding) {
                ForEach(VideoGravity.allCases, id: \.self) { gravity in
                    Text(gravity.label).tag(gravity)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        if controller.supportsAspectRatioOverride {
            Menu("Rapport d’image") {
                Picker("Rapport d’image", selection: aspectBinding) {
                    ForEach(VideoAspectRatio.allCases, id: \.self) { ratio in
                        Text(ratio.label).tag(ratio)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
    }
}

/// Sources: one checkable row per variant.
struct SourceMenuContent: View {
    let options: [PlayerSourceOption]

    var body: some View {
        Section("Sources") {
            ForEach(options) { option in
                Toggle(
                    option.menuTitle,
                    isOn: Binding(get: { option.isCurrent }, set: { _ in option.action() }))
            }
        }
    }
}
