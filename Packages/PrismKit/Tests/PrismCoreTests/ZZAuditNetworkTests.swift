import Foundation
import Testing
@testable import PrismCore

/// Temporary network audit probes — NOT part of the suite. Run with:
///   swift test --filter ZZAuditNetwork --scratch-path .build/agent-audit-network
@Suite("ZZ network audit", .disabled(if: ProcessInfo.processInfo.environment["ZZAUDIT"] == nil))
struct ZZAuditNetworkTests {

    /// What Accept-Encoding does PrismURLSession/HTTPClient actually put on the wire?
    /// Requires the local echo server on 127.0.0.1:8799 (see /tmp/echo_server.py).
    @Test func requestHeadersProbe() async throws {
        let url = try #require(URL(string: "http://127.0.0.1:8799/probe"))
        let http = HTTPClient(session: PrismURLSession.shared, userAgent: nil)
        let (data, response) = try await http.data(for: url, timeout: 10, retries: 0)
        #expect(response.statusCode == 200)
        let echoed = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        for key in echoed.keys.sorted() {
            print("ZZHDR \(key): \(echoed[key] ?? "")")
        }
    }

    /// Credentials come from env only — never hardcode a real panel here:
    /// PRISM_SOURCE_SERVER, PRISM_SOURCE_USERNAME, PRISM_SOURCE_PASSWORD (never printed).
    private func credentials() -> XtreamCredentials? {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["PRISM_SOURCE_SERVER"], let serverURL = URL(string: server),
              let username = env["PRISM_SOURCE_USERNAME"],
              let password = env["PRISM_SOURCE_PASSWORD"], !password.isEmpty else {
            print("ZZSKIP missing PRISM_SOURCE_* env")
            return nil
        }
        return XtreamCredentials(server: serverURL, username: username, password: password)
    }

    /// Times the real get_vod_streams through the production HTTPClient + shared session.
    @Test func vodStreamTiming() async throws {
        guard let credentials = credentials() else { return }
        let url = XtreamURLBuilder.api(credentials, action: "get_vod_streams")
        let http = HTTPClient(session: PrismURLSession.shared, userAgent: nil)
        let clock = ContinuousClock()
        let start = clock.now
        let (data, response) = try await http.data(for: url, timeout: 30, retries: 0)
        let elapsed = start.duration(to: clock.now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("ZZVOD http=\(response.statusCode) bytes=\(data.count) elapsed=\(String(format: "%.2f", seconds))s")
        for (key, value) in response.allHeaderFields {
            print("ZZVOD-HDR \(key): \(value)")
        }
        #expect(response.statusCode == 200)
    }

    /// Small endpoint — check whether Content-Encoding survives on tiny payloads.
    @Test func categoriesTiming() async throws {
        guard let credentials = credentials() else { return }
        let url = XtreamURLBuilder.api(credentials, action: "get_vod_categories")
        let http = HTTPClient(session: PrismURLSession.shared, userAgent: nil)
        let clock = ContinuousClock()
        let start = clock.now
        let (data, response) = try await http.data(for: url, timeout: 30, retries: 0)
        let elapsed = start.duration(to: clock.now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("ZZCAT http=\(response.statusCode) bytes=\(data.count) elapsed=\(String(format: "%.2f", seconds))s")
        for (key, value) in response.allHeaderFields {
            print("ZZCAT-HDR \(key): \(value)")
        }
        #expect(response.statusCode == 200)
    }
}
