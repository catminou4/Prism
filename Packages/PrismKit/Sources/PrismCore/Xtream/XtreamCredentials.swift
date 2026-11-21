import Foundation

public struct XtreamCredentials: Sendable, Hashable {
    public var server: URL
    public var username: String
    public var password: String

    public init(server: URL, username: String, password: String) {
        self.server = server
        self.username = username
        self.password = password
    }

    /// Accepts "host:port", "http://host:port/", "https://host/player_api.php?…", "http://host:port/c/" …
    /// → "scheme://host[:port]" (+ path prefix if the panel lives under a sub-path, without
    /// player_api.php / get.php). Defaults to http. Returns nil when unusable.
    public static func normalizeServer(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else { return nil }
        if text.hasPrefix("//") { text = "http:" + text }
        if !text.contains("://") { text = "http://" + text }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard isValidHost(host) else { return nil }
        if let port = components.port, !(1...65_535).contains(port) { return nil }

        var path = components.percentEncodedPath
        let lower = path.lowercased()
        let markers = ["/player_api.php", "/get.php", "/xmltv.php", "/panel_api.php", "/portal.php", "/server/load.php",
                       "/live/", "/movie/", "/series/", "/timeshift/", "/streaming/", "/c/", "/stalker_portal/"]
        var cut = lower.endIndex
        for marker in markers {
            if let range = lower.range(of: marker), range.lowerBound < cut { cut = range.lowerBound }
        }
        if lower.hasSuffix("/c") {
            let candidate = lower.index(lower.endIndex, offsetBy: -2)
            if candidate < cut { cut = candidate }
        }
        let offset = lower.distance(from: lower.startIndex, to: cut)
        path = String(path.prefix(offset))
        while path.hasSuffix("/") { path.removeLast() }

        var result = "\(scheme)://"
        result += host.contains(":") ? "[\(host)]" : host
        if let port = components.port { result += ":\(port)" }
        result += path
        return URL(string: result)
    }

    private static func isValidHost(_ host: String) -> Bool {
        if host.contains(":") { // IPv6
            return host.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        guard !host.hasPrefix("."), !host.hasPrefix("-"), !host.contains("..") else { return false }
        return host.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == "_"
        }
    }

    /// Parses an Xtream "get.php?username=…&password=…&type=m3u_plus" URL into credentials.
    public static func fromM3UURL(_ url: URL) -> XtreamCredentials? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.path.lowercased()
        guard path.hasSuffix("get.php") || path.hasSuffix("player_api.php") || path.hasSuffix("xmltv.php") || path.hasSuffix("panel_api.php") else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value?.trimmingCharacters(in: .whitespaces)
        }
        guard let username = value("username"), !username.isEmpty,
              let password = value("password"), !password.isEmpty,
              let server = normalizeServer(url.absoluteString) else { return nil }
        return XtreamCredentials(server: server, username: username, password: password)
    }
}
