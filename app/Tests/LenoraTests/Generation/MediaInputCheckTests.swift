import Foundation
import Testing
@testable import Lenora

struct MediaInputCheckTests {
    private let limits = BackendInputLimits(types: ["image/png"], maxBytes: 100, maxPixels: 4_194_304)

    private func file(_ ext: String, bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(ext)")
        try Data(count: bytes).write(to: url)
        return url
    }

    @Test(arguments: [(2048, 2048, true), (2049, 2048, false)])
    func pixelLimit(width: Int, height: Int, ok: Bool) async throws {
        let url = try file("png", bytes: 10); defer { try? FileManager.default.removeItem(at: url) }
        let refusal = await MediaInputCheck.refusal(for: .init(url: url, width: width, height: height), limits: limits)
        #expect(refusal == (ok ? nil : .tooManyPixels(maxPixels: 4_194_304)))
    }

    @Test func unknownDimensionsAreRefusedWhenPixelsAreLimited() async throws {
        let url = try file("png", bytes: 10); defer { try? FileManager.default.removeItem(at: url) }
        #expect(await MediaInputCheck.refusal(for: .init(url: url, width: nil, height: nil), limits: limits) == .dimensionsUnknown)
    }

    @Test func bytesAndType() async throws {
        let big = try file("png", bytes: 101); defer { try? FileManager.default.removeItem(at: big) }
        #expect(await MediaInputCheck.refusal(for: .init(url: big, width: 1, height: 1), limits: limits) == .tooLarge(maxBytes: 100))
        let gif = try file("gif", bytes: 1); defer { try? FileManager.default.removeItem(at: gif) }
        #expect(await MediaInputCheck.refusal(for: .init(url: gif, width: 1, height: 1), limits: limits) == .unsupportedType("image/gif"))
    }

    @Test func missingFile() async {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
        #expect(await MediaInputCheck.refusal(for: .init(url: url, width: 1, height: 1), limits: limits) == .sourceMissing)
    }
}
