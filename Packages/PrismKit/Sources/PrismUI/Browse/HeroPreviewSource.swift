import Foundation
import PrismCore
import PrismData
import PrismPlayer

enum HeroPreviewSource {
    /// Only direct video files are playable here; hosted pages such as YouTube are not streams.
    static func directTrailer(_ candidates: [URL?]) -> URL? {
        let extensions: Set<String> = ["mp4", "m4v", "mov", "m3u8", "mkv", "webm"]
        return candidates.compactMap { $0 }.first { url in
            guard let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { return false }
            let host = url.host?.lowercased() ?? ""
            guard host != "youtube.com", !host.hasSuffix(".youtube.com"), host != "youtu.be",
                  host != "youtube-nocookie.com", !host.hasSuffix(".youtube-nocookie.com") else { return false }
            return extensions.contains(url.pathExtension.lowercased())
        }
    }

    @MainActor
    static func resolve(_ title: MediaTitle, app: AppModel) async -> PlaybackItem? {
        let entry = app.heroArtwork.entry(for: title.id)
        let trailerURLs = [entry?.providerDetail?.trailerURL, entry?.metadata?.trailerURL]
            + title.variants.prefix(12).map { $0.movie?.trailerURL ?? $0.series?.trailerURL }
        if let trailer = directTrailer(trailerURLs) {
            return PlaybackItem(id: "preview:\(title.id.rawValue)", url: trailer, title: title.title)
        }
        if title.kind == .movie, let option = QuickPlay.option(for: title, app: app) {
            return option.playbackItem(for: title, position: excerptStart(option.duration))
        }
        guard title.kind == .series else { return nil }
        for variant in title.variants.prefix(4) {
            guard !Task.isCancelled, let series = variant.series,
                  let source = app.source(variant.sourceID), source.isEnabled else { continue }
            let seasons: [Season]
            if let local = series.seasons, !local.isEmpty {
                seasons = local
            } else if let detail = try? await app.detailRepository.seriesDetail(series, source: source) {
                seasons = detail.seasons
            } else {
                continue
            }
            guard !Task.isCancelled,
                  let season = seasons.first(where: { $0.number > 0 && !$0.episodes.isEmpty }) ?? seasons.first(where: { !$0.episodes.isEmpty }),
                  let episode = season.episodes.first,
                  let option = TitlePlaybackOption(edition: TitleEdition(variant: variant, source: source), episode: episode)
            else { continue }
            return option.playbackItem(for: title, position: excerptStart(option.duration))
        }
        return nil
    }

    private static func excerptStart(_ duration: Int?) -> TimeInterval? {
        guard let duration, duration > 600 else { return nil }
        return min(45, Double(duration) * 0.02)
    }
}
