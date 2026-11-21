import Foundation
import PrismCore
import PrismData
import PrismPlayer

enum LivePlayback {
    static func preferredVariant(in group: ChannelGroup, library: LibraryStore) -> Channel? {
        let preferred = library.preferredChannelVariant(for: group.id)
        return group.variants.first { $0.id == preferred } ?? group.primary
    }

    static func makeItem(group: ChannelGroup, variant: Channel, program: EPGProgram? = nil) -> PlaybackItem {
        var seen: Set<URL> = [variant.streamURL]
        var fallback: [URL] = []
        func add(_ url: URL?) {
            guard let url, permitsSharedHeaders(from: variant.streamURL, to: url, headers: variant.httpHeaders),
                  seen.insert(url).inserted else { return }
            fallback.append(url)
        }
        add(variant.alternateStreamURL)
        let headers = comparableHeaders(variant.httpHeaders)
        for other in group.variants where other.id != variant.id && comparableHeaders(other.httpHeaders) == headers {
            add(other.streamURL)
            add(other.alternateStreamURL)
        }
        return PlaybackItem(
            id: variant.id.rawValue, url: variant.streamURL, fallbackURLs: fallback,
            title: group.name, subtitle: program?.title, artworkURL: group.logoURL,
            isLive: true, httpHeaders: variant.httpHeaders
        )
    }

    static func replayItem(
        group: ChannelGroup, program: EPGProgram, at date: Date, model: AppModel
    ) -> (item: PlaybackItem, variant: Channel)? {
        guard let preferred = preferredVariant(in: group, library: model.library) else { return nil }
        let variants = [preferred] + group.variants.filter { $0.id != preferred.id }
        for variant in variants {
            guard let url = replayURL(variant, program: program, at: date, model: model) else { continue }
            let headers = permitsSharedHeaders(from: variant.streamURL, to: url, headers: variant.httpHeaders)
                ? variant.httpHeaders : variant.httpHeaders.filter { $0.key.lowercased() == "user-agent" }
            let item = PlaybackItem(
                id: "\(variant.id.rawValue):replay:\(program.id)", url: url,
                title: program.title, subtitle: group.name, artworkURL: program.iconURL ?? group.logoURL,
                httpHeaders: headers
            )
            return (item, variant)
        }
        return nil
    }

    private static func replayURL(_ channel: Channel, program: EPGProgram, at date: Date, model: AppModel) -> URL? {
        guard let catchup = channel.catchup, CatchupURL.isInArchive(program, catchup: catchup, at: date),
              let source = model.catalog.source(channel.sourceID) else { return nil }
        let credentials: XtreamCredentials?
        if catchup.mode == .xtream, source.kind == .xtream,
           let address = source.serverURL?.absoluteString, let server = XtreamCredentials.normalizeServer(address),
           let username = source.username, !username.isEmpty,
           let password = model.password(for: source.id), !password.isEmpty {
            credentials = XtreamCredentials(server: server, username: username, password: password)
        } else {
            credentials = nil
        }
        let timeZone = model.account(for: source.id)?.serverTimeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        return CatchupURL.make(
            channel: channel, program: program, now: date,
            correctingGuideBy: -source.epgTimeShiftHours * 3_600,
            xtream: credentials, timeZone: timeZone
        )
    }

    /// A PlaybackItem applies one header set to every attempt. Keep source-specific authentication
    /// pinned to its origin, and leave variants with different headers available for explicit selection.
    private static func permitsSharedHeaders(from source: URL, to target: URL, headers: [String: String]) -> Bool {
        if headers.keys.allSatisfy({ $0.lowercased() == "user-agent" }) { return true }
        guard let sourceHost = source.host()?.lowercased() else { return false }
        let sourceScheme = source.scheme?.lowercased()
        let targetScheme = target.scheme?.lowercased()
        return sourceScheme == targetScheme && sourceHost == target.host()?.lowercased()
            && (source.port ?? (sourceScheme == "https" ? 443 : 80)) == (target.port ?? (targetScheme == "https" ? 443 : 80))
    }

    private static func comparableHeaders(_ headers: [String: String]) -> [String: String] {
        Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }
}
