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
}
