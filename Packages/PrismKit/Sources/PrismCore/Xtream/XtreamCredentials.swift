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

    /// Parses explicit Xtream fields or an Xtream endpoint shared by a provider.
    /// A valid result has one unambiguous server, username and password.
    public static func fromProviderMessage(_ text: String) -> XtreamCredentials? {
        guard text.utf8.count <= 16_384 else { return nil }
        var servers: Set<URL> = []
        var usernames: Set<String> = []
        var passwords: Set<String> = []

        func addURL(_ input: String, fromServerField: Bool) -> Bool {
            guard !input.isEmpty, !input.contains(where: \.isWhitespace) else { return !fromServerField }
            let address = if input.hasPrefix("//") { "http:\(input)" }
            else if input.contains("://") { input }
            else { "http://\(input)" }
            guard let components = URLComponents(string: address) else { return !fromServerField }
            let isEndpoint = components.percentEncodedPath.split(separator: "/").last.map {
                ["get.php", "player_api.php", "panel_api.php", "xmltv.php"].contains($0.lowercased())
            } ?? false
            guard fromServerField || isEndpoint else { return true }
            guard components.user == nil, components.password == nil,
                  let server = normalizeServer(address) else { return false }
            servers.insert(server)

            if isEndpoint {
                for item in components.queryItems ?? [] {
                    let key = item.name.lowercased()
                    guard key == "username" || key == "password" else { continue }
                    guard let value = item.value, isProviderCredential(value) else { return false }
                    if key == "username" { usernames.insert(value) }
                    else { passwords.insert(value) }
                }
            }
            return true
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let delimiter = line.firstIndex(where: { $0 == ":" || $0 == "=" }),
               let field = ProviderField(label: String(line[..<delimiter])) {
                let label = line[..<delimiter].trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "-•")))
                var value = line[line.index(after: delimiter)...].trimmingCharacters(in: .whitespaces)
                if label.hasPrefix("**"), !label.hasSuffix("**"), value.hasPrefix("**") {
                    value = value.dropFirst(2).trimmingCharacters(in: .whitespaces)
                }
                switch field {
                case .server:
                    if let opener = value.first, let closer = providerURLClosers[opener],
                       opener != "[", value.last == closer, value.count >= 2 {
                        value = String(value.dropFirst().dropLast())
                    }
                    guard addURL(value, fromServerField: true) else { return nil }
                case .username:
                    guard isProviderCredential(value) else { return nil }
                    usernames.insert(value)
                case .password:
                    guard isProviderCredential(value) else { return nil }
                    passwords.insert(value)
                }
            } else {
                let wholeLine = NSRange(line.startIndex..<line.endIndex, in: line)
                for match in providerURLPattern?.matches(in: line, range: wholeLine) ?? [] {
                    guard let range = Range(match.range, in: line) else { continue }
                    var candidate = line[range]
                    if range.lowerBound > line.startIndex {
                        let opener = line[line.index(before: range.lowerBound)]
                        if let closer = providerURLClosers[opener], let end = candidate.lastIndex(of: closer),
                           candidate[candidate.index(after: end)...].allSatisfy({ ".,;:!?".contains($0) }) {
                            candidate = candidate[..<end]
                        }
                    }
                    guard addURL(String(candidate), fromServerField: false) else { return nil }
                }
            }
        }

        guard servers.count == 1, usernames.count == 1, passwords.count == 1,
              let server = servers.first, let username = usernames.first, let password = passwords.first else { return nil }
        return XtreamCredentials(server: server, username: username, password: password)
    }

    private static let providerURLPattern = try? NSRegularExpression(
        pattern: #"https?://[^\s<>"`]+"#, options: .caseInsensitive
    )
    private static let providerURLClosers: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "<": ">", "'": "'", "\"": "\"", "`": "`"
    ]

    private static func isProviderCredential(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespaces).isEmpty &&
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private enum ProviderField {
        case server, username, password

        init?(label: String) {
            let decoration = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-*•"))
            let name = label.trimmingCharacters(in: decoration)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr"))
                .replacingOccurrences(of: "’", with: "'")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            switch name {
            case "serveur", "server", "url", "host", "hote", "adresse du serveur", "url du serveur", "server url":
                self = .server
            case "identifiant", "username", "nom d'utilisateur", "utilisateur", "user name":
                self = .username
            case "mot de passe", "password":
                self = .password
            default:
                return nil
            }
        }
    }
}
