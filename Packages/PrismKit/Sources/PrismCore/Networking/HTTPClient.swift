import Foundation

/// Shared URL session for API / playlist / EPG requests.
public enum PrismURLSession {
    /// No URL cache (catalogs are cached on disk by PrismData), 6 connections per host,
    /// 30 s request timeout, 10 min resource timeout for very large playlists / EPGs.
    public static let shared: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()
}

/// Minimal async HTTP helper: GET with User-Agent, timeout and retries with exponential backoff.
///
/// Returns the response for every HTTP status (callers map 4xx/5xx to their own errors);
/// throws `URLError` for transport failures and `CancellationError` when cancelled.
public struct HTTPClient: Sendable {
    public static let defaultUserAgent = "Prism/1.0 (Macintosh)"

    public let session: URLSession
    public let userAgent: String?

    public init(session: URLSession, userAgent: String?) {
        self.session = session
        let trimmed = userAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.userAgent = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    public func data(
        for url: URL,
        headers: [String: String] = [:],
        timeout: TimeInterval = 30,
        retries: Int = 2
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(userAgent ?? Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                if attempt < retries, Self.isRetryable(status: http.statusCode) {
                    attempt += 1
                    try await Self.backoff(attempt: attempt, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
                    continue
                }
                return (data, http)
            } catch let error as URLError where attempt < retries && Self.isRetryable(error) {
                attempt += 1
                try await Self.backoff(attempt: attempt, retryAfter: nil)
            }
        }
    }

    static func isRetryable(status: Int) -> Bool {
        status == 429 || status == 502 || status == 503 || status == 504 || status == 500 || status == 520 || status == 522 || status == 524
    }

    static func isRetryable(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed,
             .cannotFindHost, .badServerResponse:
            true
        default:
            false
        }
    }

    private static func backoff(attempt: Int, retryAfter: String?) async throws {
        var seconds = 0.5 * pow(2, Double(attempt - 1))
        if let retryAfter, let value = Double(retryAfter.trimmingCharacters(in: .whitespaces)) {
            // Honor Retry-After (429 rate limits ask for real delays), capped at ~30 s.
            seconds = min(max(value, seconds), 30)
        }
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }
}
