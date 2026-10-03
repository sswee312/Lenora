import Foundation
import Testing
@testable import Lenora

@MainActor
struct BundledSkillsTests {
    @Test func loadsBundledCatalogIncludingLenoraAITools() async throws {
        let catalog = SkillCatalog.shared
        #expect(await catalog.refresh())
        let entry = try #require(catalog.entry(id: "lenora-ai-tools"))
        let url = try #require(SkillCatalog.bodyURL(path: entry.path))
        #expect(url.isFileURL)
        let body = String(decoding: try await SkillCatalog.fetch(url), as: UTF8.self)
        #expect(body.contains("transform_media"))
    }

    @Test func overlappingRefreshesBothReportTheLoadedCatalog() async {
        let catalog = SkillCatalog.shared
        async let first = catalog.refresh()
        async let second = catalog.refresh()
        let results = await [first, second]
        #expect(results == [true, true])
        #expect(!catalog.entries.isEmpty)
    }

    @Test func everyCatalogEntryInstallsWithItsRecordedHash() async throws {
        let catalog = SkillCatalog.shared
        #expect(await catalog.refresh())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lenora-bundled-skills-\(UUID().uuidString)", isDirectory: true)
        let store = SkillStore(directory: directory)
        await store.reloadSkills()
        var installed: [String] = []
        for entry in catalog.entries where await store.install(entry) {
            installed.append(entry.id)
        }
        let skillIDs = store.skills.map(\.id).sorted()
        await Self.removeDirectory(directory)
        #expect(installed.sorted() == catalog.entries.map(\.id).sorted())
        #expect(skillIDs == installed.sorted())
    }

    @concurrent private static func removeDirectory(_ url: URL) async {
        try? FileManager.default.removeItem(at: url)
    }
}
