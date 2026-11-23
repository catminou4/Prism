import Foundation
import Testing

@Test func appAllowsHTTPForIPTVProviders() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // PrismUITests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // PrismKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repository root
    let data = try Data(contentsOf: repository.appendingPathComponent("App/Info.plist"))
    let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    let ats = try #require(plist["NSAppTransportSecurity"] as? [String: Any])

    #expect(ats["NSAllowsArbitraryLoads"] as? Bool == true)
    // On modern macOS, the presence of any of these keys overrides the global exception.
    for key in ["NSAllowsArbitraryLoadsForMedia", "NSAllowsArbitraryLoadsInWebContent", "NSAllowsLocalNetworking"] {
        #expect(ats[key] == nil, "\(key) disables the HTTP exception used by IPTV providers")
    }
}
