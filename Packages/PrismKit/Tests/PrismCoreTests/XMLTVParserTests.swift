import Foundation
import Testing
@testable import PrismCore

@Suite("XMLTVParser")
struct XMLTVParserTests {
    func date(_ iso: String) -> Date {
        // Independent reference implementation for assertions.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    @Test func parsesFixture() throws {
        let document = try XMLTVParser.parse(try Fixture.data("epg", "xml"))
        #expect(document.channels.count == 2)
        let tf1 = try #require(document.channels.first)
        #expect(tf1.id == "tf1.fr")
        #expect(tf1.displayNames == ["TF1", "TF1 HD"])
        #expect(tf1.iconURL?.absoluteString == "http://logos.example.com/tf1.png")

        #expect(document.programs.count == 6)
        let news = document.programs[0]
        #expect(news.channelID == "tf1.fr")
        #expect(news.title == "Le Journal")
        #expect(news.subtitle == "Édition de 13h")
        #expect(news.summary == "Toute l'actualité & la météo.")
        #expect(news.category == "Information")
        #expect(news.iconURL?.absoluteString == "http://img.example.com/journal.jpg")
        #expect(news.episodeLabel == "S2 E5")
        #expect(news.rating == "16")
        #expect(news.isNew)
        #expect(news.start == date("2025-01-01T11:00:00Z"))
        #expect(news.end == date("2025-01-01T12:00:00Z"))

        let film = document.programs[1]
        #expect(film.start == date("2025-01-01T12:00:00Z"))
        #expect(film.episodeLabel == "Épisode spécial")
        #expect(!film.isNew)
        #expect(film.rating == nil)

        let cuisine = document.programs[2]
        #expect(cuisine.title == "Cuisine & Co")
        #expect(cuisine.start == date("2025-01-01T14:00:00Z"))

        #expect(document.programs[3].start == date("2025-01-03T01:00:00Z"))
        // Missing stop → next programme start on the same channel.
        let noStop = document.programs[4]
        #expect(noStop.title == "No Stop Show")
        #expect(noStop.end == date("2025-01-03T00:00:00Z"))
    }

    @Test func gzipIsTransparent() throws {
        let plain = try XMLTVParser.parse(try Fixture.data("epg", "xml"))
        let compressed = try Fixture.data("epg.xml", "gz")
        #expect(Gzip.isCompressed(compressed))
        let gz = try XMLTVParser.parse(compressed)
        #expect(gz.programs == plain.programs)
        #expect(gz.channels == plain.channels)
    }

    @Test func zlibIsTransparentAndRejectsOversizedOutput() throws {
        let compressed = try #require(Data(base64Encoded: "eJyzKSmzs0nOSMzLS81RyEyxVSpRsrNJySwuyEms1M1LzE21C0ktLrHRRxGy0YfqALKA+gE5Sxf6"))
        #expect(Gzip.isCompressed(compressed))
        #expect(try XMLTVParser.parse(compressed).channels.first?.id == "t")
        #expect(throws: XMLTVError.decompressionFailed) {
            try Gzip.decompress(compressed, maximumOutputSize: 10)
        }
    }

    @Test func namespacedProgrammesWithTheSameStartUseTheNextDistinctStart() throws {
        let document = try XMLTVParser.parse(Data("""
        <tv:tv xmlns:tv="urn:xmltv">
          <tv:channel id="t"><tv:display-name>Test</tv:display-name></tv:channel>
          <tv:programme channel="t" start="20250101123000"><tv:title>Suite</tv:title></tv:programme>
          <tv:programme channel="t" start="20250101120000"><tv:title>Journal</tv:title></tv:programme>
          <tv:programme channel="t" start="20250101120000"><tv:title>Actualités</tv:title></tv:programme>
        </tv:tv>
        """.utf8))
        #expect(document.channels.first?.displayNames == ["Test"])
        #expect(document.programs.map(\.title) == ["Suite", "Journal", "Actualités"])
        #expect(document.programs.map(\.end) == [
            date("2025-01-01T13:30:00Z"), date("2025-01-01T12:30:00Z"), date("2025-01-01T12:30:00Z")
        ])
    }

    @Test func retainsMultipleProgrammeCategories() throws {
        let input = Data("""
            <tv><programme channel="basket.example" start="20250101120000 +0000" stop="20250101140000 +0000">
              <title lang="fr">Lakers – Celtics</title>
              <category lang="en">Sports</category><category lang="fr">Sport</category><category lang="fr">Basket-ball</category>
            </programme></tv>
            """.utf8)
        let programme = try #require(XMLTVParser.parse(input).programs.first)
        #expect(programme.category == "Sport")
        #expect(programme.categoryLabels == ["Sports", "Sport", "Basket-ball"])
    }

    @Test func windowFilter() throws {
        let window = DateInterval(start: date("2025-01-01T12:30:00Z"), end: date("2025-01-02T00:00:00Z"))
        let document = try XMLTVParser.parse(try Fixture.data("epg", "xml"), window: window)
        #expect(document.programs.map(\.title) == ["Film", "Cuisine & Co"])
    }

    @Test func timeShift() throws {
        let document = try XMLTVParser.parse(try Fixture.data("epg", "xml"), timeShiftHours: 1.5)
        #expect(document.programs[0].start == date("2025-01-01T12:30:00Z"))
        #expect(document.programs[0].end == date("2025-01-01T13:30:00Z"))
    }

    @Test(arguments: [
        ("20250101120000 +0100", "2025-01-01T11:00:00Z"),
        ("20250101120000 -0230", "2025-01-01T14:30:00Z"),
        ("202501011200", "2025-01-01T12:00:00Z"),
        ("20250101120000", "2025-01-01T12:00:00Z"),
        ("20250101120000 Z", "2025-01-01T12:00:00Z"),
        ("20250101120000 +01:00", "2025-01-01T11:00:00Z"),
        ("20240229235959 +0000", "2024-02-29T23:59:59Z"),
        ("19991231230000 -0100", "2000-01-01T00:00:00Z"),
        ("20250101", "2025-01-01T00:00:00Z"),
    ])
    func timeFormats(_ raw: String, _ iso: String) {
        #expect(XMLTVParser.parseTime(raw) == date(iso))
    }

    @Test func invalidTimes() {
        #expect(XMLTVParser.parseTime("") == nil)
        #expect(XMLTVParser.parseTime("garbage") == nil)
        #expect(XMLTVParser.parseTime("20251301120000") == nil)
    }

    @Test(arguments: [
        ("1.4.0/1", "S2 E5"), ("0.0.", "S1 E1"), (".4.", "E5"), ("2..", "S3"), ("0/3.9/10.", "S1 E10"), ("..", nil),
    ] as [(String, String?)])
    func episodeNumbers(_ raw: String, _ expected: String?) {
        #expect(XMLTVParser.episodeLabel(xmltvNS: raw) == expected)
    }

    @Test func invalidData() {
        #expect(throws: XMLTVError.invalidData) { try XMLTVParser.parse(Data("not xml at all".utf8)) }
        #expect(throws: XMLTVError.invalidData) { try XMLTVParser.parse(Data()) }
        #expect(throws: XMLTVError.decompressionFailed) { try XMLTVParser.parse(Data([0x1F, 0x8B, 0x00, 0x01, 0x02, 0x03])) }
    }

    @Test func performance() throws {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><tv>"
        let channels = 200
        let perChannel = 250
        for c in 0..<channels { xml += "<channel id=\"c\(c).fr\"><display-name>Chaîne \(c)</display-name></channel>" }
        var start = 1_735_689_600
        for c in 0..<channels {
            start = 1_735_689_600
            for p in 0..<perChannel {
                let a = XMLTVTestTime.format(start), b = XMLTVTestTime.format(start + 1800)
                xml += "<programme start=\"\(a) +0100\" stop=\"\(b) +0100\" channel=\"c\(c).fr\"><title lang=\"fr\">Programme \(p)</title><desc lang=\"fr\">Description du programme \(p) sur la chaîne \(c).</desc><category lang=\"fr\">Divertissement</category></programme>"
                start += 1800
            }
        }
        xml += "</tv>"
        let data = Data(xml.utf8)
        let clock = ContinuousClock()
        var document = XMLTVDocument()
        let elapsed = try clock.measure { document = try XMLTVParser.parse(data) }
        print("XMLTVParser: \(document.programs.count) programmes (\(data.count / 1_000_000) MB) in \(elapsed)")
        #expect(document.programs.count == channels * perChannel)
        #expect(elapsed < .seconds(20))
    }

    @Test func truncatedDocumentKeepsParsedProgrammes() throws {
        let text = "<tv><programme start=\"20250101120000 +0000\" stop=\"20250101130000 +0000\" channel=\"a\"><title>One</title></programme><programme start=\"2025"
        let document = try XMLTVParser.parse(Data(text.utf8))
        #expect(document.programs.map(\.title) == ["One"])
    }
}

enum XMLTVTestTime {
    static func format(_ epoch: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: TimeInterval(epoch)))
        return String(format: "%04d%02d%02d%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
