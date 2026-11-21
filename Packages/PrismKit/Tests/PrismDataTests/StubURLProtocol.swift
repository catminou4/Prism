import Foundation
import Synchronization

/// URLProtocol stub keyed by host so that parallel tests don't interfere. Each test registers a
/// unique host and uses `StubURLProtocol.session()`.
final class StubURLProtocol: URLProtocol {
    struct Response: Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()
        /// Body delivered in this many chunks (exercises streaming progress).
        var chunks: Int = 1

        static func text(_ text: String, status: Int = 200, contentLength: Bool = true, chunks: Int = 1) -> Response {
            let body = Data(text.utf8)
            var headers = ["Content-Type": "text/plain; charset=utf-8"]
            if contentLength { headers["Content-Length"] = String(body.count) }
            return Response(status: status, headers: headers, body: body, chunks: chunks)
        }

        static func json(_ text: String) -> Response {
            let body = Data(text.utf8)
            return Response(status: 200, headers: ["Content-Type": "application/json", "Content-Length": String(body.count)], body: body)
        }
    }

    typealias Handler = @Sendable (URLRequest) -> Response

    private static let handlers = Mutex<[String: Handler]>([:])
    private static let counters = Mutex<[String: Int]>([:])

    static func register(host: String, handler: @escaping Handler) {
        handlers.withLock { $0[host] = handler }
        counters.withLock { $0[host] = 0 }
    }

    static func unregister(host: String) {
        handlers.withLock { $0[host] = nil }
    }

    static func requestCount(host: String) -> Int {
        counters.withLock { $0[host] ?? 0 }
    }

    static func uniqueHost(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.lowercased().prefix(8)).stub.test"
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return handlers.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let handler = Self.handlers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        Self.counters.withLock { $0[host, default: 0] += 1 }
        let response = handler(request)
        guard let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        let chunks = max(1, response.chunks)
        let size = max(1, (response.body.count + chunks - 1) / chunks)
        var offset = 0
        while offset < response.body.count {
            let end = min(offset + size, response.body.count)
            client?.urlProtocol(self, didLoad: response.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLRequest {
    func queryValue(_ name: String) -> String? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == name }?.value
    }
}
