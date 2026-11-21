import Foundation
import Testing

enum Fixture {
    static func url(_ name: String, _ ext: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"), "missing fixture \(name).\(ext)")
    }

    static func data(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: url(name, ext))
    }
}
