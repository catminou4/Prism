import Foundation
import Observation
import SwiftUI
import PrismCore
import PrismData
import PrismPlayer
import PrismDesign

@Observable
final class PrismPlaybackSession {
    static let windowID = "playback"

    private(set) var controller: PlayerController?
    private(set) var target: HistoryEntry.Target?
    private(set) var contentID: ContentID?
    private(set) var seriesEditionID: ContentID?
    private var episodeInventory: DetailEpisodeInventory?
    private var dismissedNextFor: ContentID?
    private var recordedContent: ContentID?

    func open(
        _ item: PlaybackItem, target: HistoryEntry.Target, contentID: ContentID,
        app: AppModel, seriesEditionID: ContentID? = nil
    ) {
        let programme = item.isLive ? currentProgramme(for: target, app: app) : nil
        if let controller, controller.isLive == item.isLive {
            controller.replace(with: item, programme: programme)
        } else {
            controller?.stop()
            let newController = PlayerController(item: item)
            newController.liveProgramme = programme
            controller = newController
        }
        self.target = target
        self.contentID = contentID
        if self.seriesEditionID != seriesEditionID { episodeInventory = nil }
        self.seriesEditionID = seriesEditionID
        dismissedNextFor = nil
        recordedContent = nil
        let titleID: TitleID?
        if case .title(let id) = target {
            titleID = id
        } else {
            titleID = nil
        }
        controller?.onProgress = { [weak app] position, duration in
            guard let titleID, position.isFinite, duration.isFinite, duration > 0, position > 0 else { return }
            app?.library.updateProgress(.init(contentID: contentID, titleID: titleID, position: position, duration: duration))
        }
        controller?.onEnded = { [weak app] in
            if let titleID { app?.library.markWatched(contentID, titleID: titleID) }
        }
    }

    var nextEpisode: Episode? {
        guard let current = contentID, dismissedNextFor != current else { return nil }
        return episodeInventory?.nextAvailableEpisode(after: current)
    }

    func loadEpisodeInventory(app: AppModel) async {
        guard let editionID = seriesEditionID, episodeInventory == nil,
              case let .title(titleID) = target, let title = app.catalog.title(titleID),
              let variant = title.variants.first(where: { $0.id == editionID }), let series = variant.series,
              let source = app.source(variant.sourceID), source.isEnabled,
              let detail = await app.detailRepository.cachedSeriesDetail(series, source: source),
              !Task.isCancelled else { return }
        let edition = TitleEdition(variant: variant, source: source)
        let inventory = await DetailEpisodeInventory.build(edition: edition, detail: detail)
        guard !Task.isCancelled, editionID == seriesEditionID else { return }
        episodeInventory = inventory
    }

    func playNextEpisode(app: AppModel) {
        guard let episode = nextEpisode, let editionID = seriesEditionID,
              case let .title(titleID) = target, let title = app.catalog.title(titleID),
              let variant = title.variants.first(where: { $0.id == editionID }),
              let source = app.source(variant.sourceID), source.isEnabled,
              let option = TitlePlaybackOption(edition: TitleEdition(variant: variant, source: source), episode: episode)
        else { return }
        let position = option.resumePosition(exact: app.library.progress(for: option.contentID), equivalent: nil)
        open(option.playbackItem(for: title, position: position), target: .title(titleID),
             contentID: option.contentID, app: app, seriesEditionID: editionID)
    }

    func dismissNextEpisode() {
        dismissedNextFor = contentID
    }

    func playbackBegan(app: AppModel) {
        guard controller?.phase == .playing, let target, let contentID, recordedContent != contentID else { return }
        app.library.recordPlayback(target: target, contentID: contentID)
        if case .channel(let id) = target { app.library.lastChannelGroupID = id }
        recordedContent = contentID
    }

    func updateProgramme(app: AppModel) {
        guard let controller, controller.isLive, let target else { return }
        // The 25 s poll exists for programme *changes*; rewriting an identical
        // value would still republish `liveProgramme` and re-evaluate the whole
        // player body for nothing (programmes last tens of minutes).
        let programme = currentProgramme(for: target, app: app)
        if controller.liveProgramme != programme { controller.liveProgramme = programme }
    }

    func close() {
        controller?.stop()
        controller = nil
        target = nil
        contentID = nil
        seriesEditionID = nil
        episodeInventory = nil
        dismissedNextFor = nil
        recordedContent = nil
    }

    private func currentProgramme(for target: HistoryEntry.Target, app: AppModel) -> LiveProgramme? {
        guard case .channel(let id) = target,
              let group = app.catalog.channelGroup(id),
              let epgID = app.guide.resolveEPGID(for: group),
              let programme = app.guide.nowAndNext(forEPGID: epgID, at: .now).now else { return nil }
        return LiveProgramme(title: programme.title, start: programme.start, end: programme.end)
    }
}

struct PrismPlaybackWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow
    let session: PrismPlaybackSession

    var body: some View {
        Group {
            if let controller = session.controller {
                if controller.isLive, case .channel(let id) = session.target {
                    PlayerView(
                        controller: controller,
                        sourceOptions: options(for: id),
                        onClose: close,
                        onChannelUp: { zap(from: id, forward: true) },
                        onChannelDown: { zap(from: id, forward: false) },
                        infoAccessory: {
                            if let programme = controller.liveProgramme {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(programme.title).font(.headline)
                                    Text("\(programme.start.formatted(date: .omitted, time: .shortened)) – \(programme.end.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(15)
                                .frame(maxWidth: 330, alignment: .leading)
                            }
                        },
                        sidePanel: {
                            channelPanel(current: id)
                        }
                    )
                } else {
                    PlayerView(
                        controller: controller, onClose: close,
                        sidePanel: { EmptyView() },
                        upNext: { nextEpisodeCard }
                    )
                }
            } else {
                Color.black
            }
        }
        .frame(minWidth: 520, minHeight: 292)
        .onChange(of: session.controller?.phase) { _, _ in session.playbackBegan(app: app) }
        .task(id: session.seriesEditionID) { await session.loadEpisodeInventory(app: app) }
        .task(id: session.controller?.isLive == true) {
            guard session.controller?.isLive == true else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled else { return }
                session.updateProgramme(app: app)
            }
        }
        .onDisappear { session.close() }
    }

    @ViewBuilder private var nextEpisodeCard: some View {
        if let episode = session.nextEpisode, app.source(episode.sourceID)?.isEnabled == true {
            PlayerUpNextCard(
                title: episode.title, subtitle: EpisodeCoordinate(episode).label,
                remaining: 0, countdown: 0,
                onPlay: { session.playNextEpisode(app: app) },
                onDismiss: { session.dismissNextEpisode() }
            ) {
                RemoteImage(
                    url: episode.stillURL, size: CGSize(width: 112, height: 63),
                    placeholderSeed: episode.title, placeholderStyle: .monogram
                )
            }
        }
    }

    private func options(for id: String) -> [PlayerSourceOption] {
        guard let group = app.catalog.channelGroup(id) else { return [] }
        return group.variants.map { channel in
            PlayerSourceOption(
                id: channel.id.rawValue,
                label: app.source(channel.sourceID)?.name ?? "Source IPTV",
                detail: channel.quality.badge,
                isCurrent: channel.id == session.contentID
            ) {
                app.library.setPreferredChannelVariant(channel.id, for: id)
                play(group, variant: channel)
            }
        }
    }

    private func channelPanel(current: String) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                Text("Chaînes").font(.title2.bold()).padding(.bottom, 10)
                ForEach(app.catalog.channels) { channel in
                    Button {
                        play(channel)
                    } label: {
                        HStack(spacing: 10) {
                            RemoteImage(url: channel.logoURL, size: CGSize(width: 36, height: 30), contentMode: .fit,
                                        placeholderSeed: channel.name, placeholderStyle: .monogram)
                                .clipShape(.rect(cornerRadius: 5))
                            Text(channel.name).lineLimit(1)
                            Spacer(minLength: 0)
                            if channel.id == current { Image(systemName: "speaker.wave.2.fill") }
                        }
                        .padding(6)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(channel.id == current ? .isSelected : [])
                }
            }
            .padding(16)
        }
        .frame(width: 250)
    }

    private func zap(from id: String, forward: Bool) {
        if let channel = app.catalog.adjacentChannel(to: id, forward: forward) { play(channel) }
    }

    private func play(_ group: ChannelGroup, variant: Channel? = nil) {
        let preferred = app.library.preferredChannelVariant(for: group.id)
        guard let channel = variant ?? group.variants.first(where: { $0.id == preferred }) ?? group.primary else { return }
        let item = LivePlayback.makeItem(group: group, variant: channel, program: nil)
        session.open(item, target: .channel(groupID: group.id), contentID: channel.id, app: app)
    }

    private func close() {
        session.close()
        dismissWindow(id: PrismPlaybackSession.windowID)
    }
}
