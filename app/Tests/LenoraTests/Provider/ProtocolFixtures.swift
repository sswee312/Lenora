import Foundation

enum ProtocolFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // Provider
        .deletingLastPathComponent()      // LenoraTests
        .deletingLastPathComponent()      // Tests
        .deletingLastPathComponent()      // app
        .deletingLastPathComponent()      // repo root
        .appending(path: "protocol/fixtures")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appending(path: "\(name).json"))
    }
}
