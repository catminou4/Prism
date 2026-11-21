import Foundation

public enum XtreamStreamFormat: String, Sendable {
    case ts, m3u8
}

/// Builds Xtream Codes stream / API URLs. Username, password and IDs are percent-encoded.
public enum XtreamURLBuilder {
    /// `{server}/live/{u}/{p}/{id}.{ext}`
    public static func live(_ c: XtreamCredentials, streamID: String, format: XtreamStreamFormat) -> URL {
        stream(c, kind: "live", id: streamID, ext: format.rawValue)
    }

    /// `{server}/movie/{u}/{p}/{id}.{ext ?? "mp4"}`
    public static func movie(_ c: XtreamCredentials, streamID: String, ext: String?) -> URL {
        stream(c, kind: "movie", id: streamID, ext: cleanExtension(ext))
    }

    /// `{server}/series/{u}/{p}/{id}.{ext ?? "mp4"}`
    public static func episode(_ c: XtreamCredentials, episodeID: String, ext: String?) -> URL {
        stream(c, kind: "series", id: episodeID, ext: cleanExtension(ext))
    }

    /// `{server}/timeshift/{u}/{p}/{duration}/{yyyy-MM-dd:HH-mm}/{id}.ts` — `start` expressed in the
    /// server time zone.
    public static func timeshift(_ c: XtreamCredentials, streamID: String, start: Date, durationMinutes: Int, timeZone: TimeZone) -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        func pad(_ value: Int?, _ width: Int = 2) -> String {
            let string = String(value ?? 0)
            return string.count >= width ? string : String(repeating: "0", count: width - string.count) + string
        }
        let stamp = "\(pad(parts.year, 4))-\(pad(parts.month))-\(pad(parts.day)):\(pad(parts.hour))-\(pad(parts.minute))"
        let path = "/timeshift/\(segment(c.username))/\(segment(c.password))/\(max(durationMinutes, 1))/\(stamp)/\(segment(streamID)).ts"
        return url(base(c) + path, fallback: c.server)
    }

    /// `{server}/xmltv.php?username=&password=`
    public static func xmltv(_ c: XtreamCredentials) -> URL {
        url(base(c) + "/xmltv.php?username=\(query(c.username))&password=\(query(c.password))", fallback: c.server)
    }

    /// `{server}/get.php?username=&password=&type=m3u_plus&output=ts`
    public static func m3u(_ c: XtreamCredentials, output: XtreamStreamFormat = .ts) -> URL {
        url(base(c) + "/get.php?username=\(query(c.username))&password=\(query(c.password))&type=m3u_plus&output=\(output.rawValue)", fallback: c.server)
    }

    /// `{server}/player_api.php?username&password&action`
    public static func api(_ c: XtreamCredentials, action: String?, extra: [URLQueryItem] = []) -> URL {
        var string = base(c) + "/player_api.php?username=\(query(c.username))&password=\(query(c.password))"
        if let action, !action.isEmpty { string += "&action=\(query(action))" }
        for item in extra {
            string += "&\(query(item.name))=\(query(item.value ?? ""))"
        }
        return url(string, fallback: c.server)
    }

    // MARK: - Helpers

    static func base(_ c: XtreamCredentials) -> String {
        var string = c.server.absoluteString
        while string.hasSuffix("/") { string.removeLast() }
        return string
    }

    private static func stream(_ c: XtreamCredentials, kind: String, id: String, ext: String) -> URL {
        url(base(c) + "/\(kind)/\(segment(c.username))/\(segment(c.password))/\(segment(id)).\(ext)", fallback: c.server)
    }

    private static func cleanExtension(_ ext: String?) -> String {
        let trimmed = (ext ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        guard !trimmed.isEmpty, trimmed.count <= 5, trimmed.allSatisfy({ $0.isLetter || $0.isNumber }) else { return "mp4" }
        return trimmed
    }

    private static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~!$&'()*+,=:@")
        return set
    }()

    private static let queryAllowed: CharacterSet = {
        var set = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? value
    }

    /// Strict query encoding: `+`, `&`, `=` … are escaped (panels decode `+` as a space).
    static func query(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? value
    }

    private static func url(_ string: String, fallback: URL) -> URL {
        URL(string: string) ?? fallback
    }
}
