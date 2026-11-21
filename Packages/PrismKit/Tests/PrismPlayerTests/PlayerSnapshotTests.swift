import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PrismPlayer

/// Renders the player overlay offscreen into `Tools/output/player/*.png` for visual review.
/// Opt-in: `PRISM_SNAPSHOTS=1 swift test --filter PlayerSnapshotTests`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PRISM_SNAPSHOTS"] != nil))
struct PlayerSnapshotTests {
    static let size = CGSize(width: 1220, height: 511)

    static let vodItem = PlaybackItem(
        id: "vod", url: URL(string: "https://example.com/v/master.m3u8")!,
        title: "Welcome Back: Season 2", subtitle: "S2, É4 · Ce que vous avez fait")

    static let subtitles = [
        MediaTrack(id: "s0", name: "Français", language: "fr"),
        MediaTrack(id: "s1", name: "English (SDH)", language: "en", isAccessibility: true),
    ]

    @Test func vodPlaying() throws {
        let controller = PlayerController.preview(
            item: Self.vodItem, currentTime: 27, duration: 156, subtitleTracks: Self.subtitles)
        try PlayerSnapshotRenderer.write(
            PlayerView(controller: controller, configuresWindow: true, onShare: {}),
            size: Self.size, name: "vod_playing")
    }

    @Test func vodPausedSkipFeedback() throws {
        let controller = PlayerController.preview(
            item: Self.vodItem, phase: .paused, currentTime: 2_710, duration: 5_400, feedback: .skip(10))
        try PlayerSnapshotRenderer.write(
            PlayerView(controller: controller, onShare: {}), size: Self.size, name: "vod_paused_skip")
    }

    @Test func volumeHUD() throws {
        let controller = PlayerController.preview(
            item: Self.vodItem, currentTime: 60, duration: 156, volume: 0.6, feedback: .volume(0.6, muted: false))
        try PlayerSnapshotRenderer.write(
            PlayerView(controller: controller), size: Self.size, name: "vod_volume_hud")
    }

    @Test func liveWithPanel() throws {
        let start = Date().addingTimeInterval(-1_500)
        let item = PlaybackItem(
            id: "live", url: URL(string: "http://host/live/u/p/42.ts")!, title: "France 2 HD",
            subtitle: "Source A · FHD", isLive: true)
        let controller = PlayerController.preview(
            item: item, currentTime: 0, duration: nil,
            liveProgramme: LiveProgramme(title: "Journal de 20 heures", start: start, end: start.addingTimeInterval(2_700)))
        let view = PlayerView(
            controller: controller,
            sourceOptions: [
                PlayerSourceOption(label: "Source A", detail: "FHD", isCurrent: true) {},
                PlayerSourceOption(label: "Source B", detail: "HD") {},
            ],
            onChannelUp: {}, onChannelDown: {},
            infoAccessory: { SnapshotProgrammeCard() },
            sidePanel: { SnapshotChannelList() })
        try PlayerSnapshotRenderer.write(view, size: Self.size, name: "live_controls")
        try PlayerSnapshotRenderer.write(view.previewing(sidePanelOpen: true), size: Self.size, name: "live_side_panel")
    }

    @Test func liveTimeshiftBehindEdge() throws {
        let item = PlaybackItem(
            id: "live", url: URL(string: "https://h/live/master.m3u8")!, title: "Canal Info", isLive: true,
            supportsTimeshift: true)
        let controller = PlayerController.preview(
            item: item, phase: .paused, currentTime: 2_400, duration: nil, timeshiftWindow: 0...3_600)
        try PlayerSnapshotRenderer.write(PlayerView(controller: controller), size: Self.size, name: "live_timeshift")
    }

    @Test func infoOverlayInPlayer() throws {
        let controller = PlayerController.preview(
            item: Self.vodItem,
            techInfo: StreamTechSnapshot(
                engineName: "AVFoundation", videoCodec: "H.264", audioCodec: "AAC",
                resolution: CGSize(width: 1920, height: 1080), framesPerSecond: 23.976,
                indicatedBitrate: 6_500_000, observedBitrate: 22_000_000, droppedFrames: 0,
                url: URL(string: "https://cdn.example.com/master.m3u8")))
        try PlayerSnapshotRenderer.write(
            PlayerView(controller: controller).previewing(infoVisible: true), size: Self.size, name: "vod_info_overlay")
    }

    @Test func switchingStream() throws {
        let item = PlaybackItem(id: "live", url: URL(string: "http://h/live/u/p/1.ts")!, title: "TF1 HD", isLive: true)
        let controller = PlayerController.preview(
            item: item, phase: .loading, duration: nil, isSwitchingStream: true, statusMessage: "Reconnexion…")
        try PlayerSnapshotRenderer.write(PlayerView(controller: controller), size: Self.size, name: "live_reconnecting")
    }

    @Test func loading() throws {
        let controller = PlayerController.preview(
            item: Self.vodItem, phase: .loading, currentTime: 0, duration: nil, statusMessage: "Nouvelle tentative…")
        try PlayerSnapshotRenderer.write(PlayerView(controller: controller), size: Self.size, name: "loading")
    }

    @Test func failed() throws {
        let controller = PlayerController.preview(
            item: Self.vodItem, phase: .failed("Le serveur a refusé la connexion (403)."), currentTime: 0,
            duration: nil)
        let view = PlayerView(
            controller: controller,
            sourceOptions: [
                PlayerSourceOption(label: "Source A", isCurrent: true) {},
                PlayerSourceOption(label: "Source B") {},
            ])
        try PlayerSnapshotRenderer.write(view, size: Self.size, name: "failed")
    }

    @Test func upNext() throws {
        let controller = PlayerController.preview(item: Self.vodItem, currentTime: 2_590, duration: 2_610)
        let view = PlayerView(
            controller: controller,
            sidePanel: { SnapshotChannelList() },
            upNext: {
                PlayerUpNextCard(
                    title: "Épisode 5 · La rentrée", subtitle: "Welcome Back · Saison 2",
                    remaining: controller.remainingTime ?? 0, onPlay: {}, onDismiss: {})
            })
        try PlayerSnapshotRenderer.write(view, size: Self.size, name: "vod_up_next")
    }

    @Test func controlsHidden() throws {
        let controller = PlayerController.preview(item: Self.vodItem, controlsVisible: false)
        try PlayerSnapshotRenderer.write(PlayerView(controller: controller), size: Self.size, name: "controls_hidden")
    }

    @Test func streamInfoCard() throws {
        let controller = PlayerController.preview(
            item: Self.vodItem,
            techInfo: StreamTechSnapshot(
                engineName: "VLC", videoCodec: "HEVC", audioCodec: "Dolby Digital Plus",
                resolution: CGSize(width: 3840, height: 2160), framesPerSecond: 25,
                indicatedBitrate: 15_200_000, observedBitrate: 48_000_000, droppedFrames: 3,
                url: URL(string: "http://provider.example.com:8080/movie/u/p/1.mkv")))
        let view = ZStack {
            Color.black
            PlayerStreamInfoCard(controller: controller) {}
        }
        try PlayerSnapshotRenderer.write(view, size: CGSize(width: 360, height: 320), name: "stream_info")
    }
}

private struct SnapshotProgrammeCard: View {
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MAINTENANT").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                Text("Journal de 20 heures").font(.system(size: 13, weight: .semibold))
            }
            Divider().frame(height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("À SUIVRE · 20:45").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                Text("Météo").font(.system(size: 13, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .playerGlass(RoundedRectangle(cornerRadius: 14))
    }
}

private struct SnapshotChannelList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chaînes").font(.system(size: 15, weight: .bold)).padding(16)
            ForEach(1..<9) { index in
                HStack {
                    Text("\(index)").font(.system(size: 12, weight: .semibold)).frame(width: 24)
                    Text("Chaîne \(index)").font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background(index == 2 ? Color.white.opacity(0.12) : .clear)
            }
            Spacer()
        }
        .foregroundStyle(.white)
    }
}
