import Foundation
import Synchronization

/// Serves canned responses keyed by host + `action` query item (each test uses its own host).
final class StubURLProtocol: URLProtocol {
    struct Response: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
    }

    private static let routes = Mutex<[String: Response]>([:])
    private static let requests = Mutex<[URLRequest]>([])

    /// Xtream style route: `action` query item (nil = plain `player_api.php`).
    static func register(host: String, action: String?, status: Int = 200, body: Data, headers: [String: String] = [:]) {
        routes.withLock { $0[key(host: host, route: action ?? "/player_api.php")] = Response(status: status, body: body, headers: headers) }
    }

    /// Path route (TMDB style).
    static func register(host: String, path: String, status: Int = 200, body: Data, headers: [String: String] = [:]) {
        routes.withLock { $0[key(host: host, route: path)] = Response(status: status, body: body, headers: headers) }
    }

    static func recordedRequests(host: String) -> [URLRequest] {
        requests.withLock { $0.filter { $0.url?.host() == host } }
    }

    static func key(host: String, route: String) -> String { "\(host)|\(route)" }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        Self.requests.withLock { $0.append(request) }
        let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "action" }?.value
        let route = Self.routes.withLock { $0[Self.key(host: url.host() ?? "", route: action ?? url.path())] }
        guard let route else {
            client.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: route.headers)!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: route.body)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
