import Foundation

/// Builds replay streams for finished programmes and respects the provider's advertised archive window.
public enum CatchupURL {
    public static func isInArchive(_ program: EPGProgram, catchup: Catchup, at date: Date) -> Bool {
        catchup.days > 0 && program.start < program.end && program.end <= date
            && date.timeIntervalSince(program.start) <= Double(catchup.days) * 86_400
    }

    public static func make(
        channel: Channel, program: EPGProgram, now: Date = .now,
        correctingGuideBy offset: TimeInterval = 0,
        xtream: XtreamCredentials? = nil, timeZone: TimeZone = .current
    ) -> URL? {
        guard let catchup = channel.catchup, isInArchive(program, catchup: catchup, at: now),
              offset.isFinite,
              let duration = Int(exactly: program.end.timeIntervalSince(program.start).rounded(.up)), duration > 0 else {
            return nil
        }
        let start = program.start.addingTimeInterval(offset)
        let end = program.end.addingTimeInterval(offset)
        if catchup.mode == .xtream, let xtream {
            return XtreamURLBuilder.timeshift(
                xtream, streamID: channel.nativeID, start: start,
                durationMinutes: (duration - 1) / 60 + 1, timeZone: timeZone
            )
        }

        // The M3U template specifiers follow Kodi IPTV Simple's documented conventions.
        // https://github.com/kodi-pvr/pvr.iptvsimple#catchup-format-specifiers
        let appendsQuery = catchup.mode == .append || catchup.mode == .shift
        let template = catchup.template ?? (catchup.mode == .shift ? "?utc={utc}&lutc={lutc}" : "")
        guard !template.isEmpty,
              let expanded = expand(template, start: start, end: end, now: now, duration: duration) else { return nil }
        let url: URL?
        if appendsQuery {
            url = append(expanded, to: channel.streamURL)
        } else {
            url = URL(string: expanded, relativeTo: channel.streamURL)?.absoluteURL
        }
        guard let url, url != channel.streamURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil else {
            return nil
        }
        return url
    }

    private static func expand(_ template: String, start: Date, end: Date, now: Date, duration: Int) -> String? {
        guard let startEpoch = Int(exactly: start.timeIntervalSince1970.rounded(.towardZero)),
              let endEpoch = Int(exactly: end.timeIntervalSince1970.rounded(.towardZero)),
              let nowEpoch = Int(exactly: now.timeIntervalSince1970.rounded(.towardZero)) else { return nil }
        let values = [
            "utc": startEpoch, "start": startEpoch, "utcend": endEpoch, "end": endEpoch,
            "lutc": nowEpoch, "now": nowEpoch, "timestamp": nowEpoch, "duration": duration,
        ]
        var expanded = template
        while let open = expanded.firstIndex(of: "{") {
            guard let close = expanded[open...].firstIndex(of: "}") else { return nil }
            let key = String(expanded[expanded.index(after: open)..<close])
            let first = open > expanded.startIndex && expanded[expanded.index(before: open)] == "$"
                ? expanded.index(before: open) : open
            let value: String
            if let number = values[key] {
                value = String(number)
            } else if key.hasPrefix("duration:"),
                      let divider = Int(key.dropFirst("duration:".count)), divider > 0 {
                value = String(duration / divider)
            } else if let component = dateComponents[key] {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = .gmt
                let number = String(calendar.component(component, from: start))
                value = String(repeating: "0", count: max(0, (component == .year ? 4 : 2) - number.count)) + number
            } else {
                return nil
            }
            expanded.replaceSubrange(first...close, with: value)
        }
        return expanded
    }

    private static let dateComponents: [String: Calendar.Component] = [
        "Y": .year, "m": .month, "d": .day, "H": .hour, "M": .minute, "S": .second,
    ]

    private static func append(_ expanded: String, to url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let fragment = components.percentEncodedFragment.map { "#" + $0 } ?? ""
        components.fragment = nil
        if components.percentEncodedQuery == "" { components.query = nil }
        guard let base = components.url?.absoluteString else { return nil }
        if expanded.hasPrefix("?") || expanded.hasPrefix("&") {
            let separator = components.percentEncodedQuery == nil ? "?" : "&"
            return URL(string: base + separator + expanded.dropFirst() + fragment)
        }
        return URL(string: base + expanded + fragment)
    }
}
