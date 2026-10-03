import Foundation
import Testing
@testable import Lenora

@MainActor
struct AnalyzeMediaToolTests {
    @Test func analyzeMediaIsListedOnlyWhenTheBackendOffersIt() throws {
        #expect(!Set(ToolDefinitions.available(ToolDefinitions.mcpServer, catalog: ModelCatalog()).map(\.name)).contains(.analyzeMedia))
        let catalog = try analysisCatalog()
        let tools = ToolDefinitions.available(ToolDefinitions.mcpServer, catalog: catalog)
        let tool = try #require(tools.first { $0.name == .analyzeMedia })
        let ids = ((tool.inputSchema["properties"] as? [String: Any])?["model"] as? [String: Any])?["enum"] as? [String]
        #expect(ids == ["cloudinary/ai-vision", "cloudinary/google-tagging"])
    }

    @Test func listModelsReportsAnalyzeRequirements() async throws {
        let fixture = try await EditorTestFixture.withImage(catalog: analysisCatalog())
        defer { fixture.cleanup() }
        let result = await fixture.executor.execute(name: "list_models", args: ["type": "analyze"])
        let body = try jsonObject(result)
        let models = try #require(body["models"] as? [[String: Any]])
        let byId = Dictionary(uniqueKeysWithValues: models.map { ($0["id"] as! String, $0) })
        #expect(byId["cloudinary/google-tagging"]?["requires"] == nil)
        #expect(byId["cloudinary/google-tagging"]?["type"] as? String == "analyze")
        #expect(byId["cloudinary/ai-vision"]?["requires"] as? String == "prompt")
    }

    @Test func storesTagsOnTheExistingImage() async throws {
        let state = try BackendCoding.decoder().decode(JobState.self, from: Data("""
        {"jobId":"fake:1","status":"succeeded","results":null,"analysis":{"tags":[{"tag":"iris","confidence":0.9},{"tag":"eye","confidence":0.4}]}}
        """.utf8))
        let provider = FakeProvider(states: [state])
        let fixture = try await EditorTestFixture.withImage(provider: provider, catalog: analysisCatalog())
        defer { fixture.cleanup() }

        let result = await fixture.executor.execute(name: "analyze_media", args: ["mediaRef": fixture.image.id])
        let body = try jsonObject(result)
        #expect(body["tags"] as? [String] == ["iris", "eye"])
        #expect(body["model"] as? String == "cloudinary/google-tagging")
        #expect(fixture.editor.mediaAssets.count == 1)
        #expect(fixture.image.analysis?.tags == ["iris", "eye"])
        #expect(await provider.uploads.count == 1)

        let media = await fixture.executor.execute(name: "get_media", args: ["ids": [fixture.image.id]])
        let assets = try #require(try jsonObject(media)["assets"] as? [[String: Any]])
        #expect(assets.first?["tags"] as? [String] == ["iris", "eye"])
        #expect(assets.first?["analysisModel"] as? String == "cloudinary/google-tagging")
    }

    @Test func promptModelDoesNotUploadUntilThePromptIsPresent() async throws {
        let provider = FakeProvider(states: [])
        let fixture = try await EditorTestFixture.withImage(provider: provider, catalog: analysisCatalog())
        defer { fixture.cleanup() }
        let missing = await fixture.executor.execute(
            name: "analyze_media",
            args: ["mediaRef": fixture.image.id, "model": "cloudinary/ai-vision"]
        )
        let error = try #require(try jsonObject(missing)["error"] as? [String: Any])
        #expect(error["field"] as? String == "prompt")
        #expect(await provider.uploads.isEmpty)
        #expect(fixture.image.analysis == nil)
    }

    @Test func refusesAVideo() async throws {
        let provider = FakeProvider(states: [])
        let fixture = try await EditorTestFixture.withVideo(provider: provider, catalog: analysisCatalog())
        defer { fixture.cleanup() }
        let result = await fixture.executor.execute(name: "analyze_media", args: ["mediaRef": fixture.video!.id])
        let error = try #require(try jsonObject(result)["error"] as? [String: Any])
        #expect(error["field"] as? String == "mediaRef")
        #expect(await provider.uploads.isEmpty)
    }

    @Test func acceptsUntypedTagAndQuestionLists() throws {
        let params = try ToolExecutor.analyzeParams([
            "tags": [["name": "flower", "description": "a bloom"] as [String: Any]] as [Any],
            "questions": ["Is it a flower?"] as [Any],
        ], requires: "tags")
        #expect(params.tags?.map(\.name) == ["flower"])
        #expect(params.questions == ["Is it a flower?"])
    }

    @Test func readsCategorizationTagsAndANestedCaption() throws {
        let analysis = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"categorization":{"imagga_tagging":{"data":[{"tag":"sky"}]}},"data":{"caption":"A field"}}
        """.utf8))
        let summary = AnalysisSummary.tagsAndCaption(in: analysis)
        #expect(summary.tags == ["sky"])
        #expect(summary.caption == "A field")
    }

    private func analysisCatalog() throws -> ModelCatalog {
        let catalog = ModelCatalog()
        catalog.apply(BackendCapabilities(
            protocolVersion: "1", adapters: [],
            models: [
                try model("cloudinary/google-tagging", displayName: "Google Auto Tagging"),
                try model("cloudinary/ai-vision", displayName: "AI Vision", requires: "prompt"),
            ]
        ))
        return catalog
    }

    private func model(_ id: String, displayName: String, requires: String? = nil) throws -> BackendModel {
        var ui = #"{"providerName":"Cloudinary","responseShape":"analysis""#
        if let requires { ui += #","requires":"\#(requires)""# }
        ui += "}"
        let json = """
        {"id":"\(id)","kind":"image.analyze","displayName":"\(displayName)","inputs":{"types":["image/png","image/jpeg","image/webp"],"maxBytes":10485760},"cancellable":false,"ui":\(ui)}
        """
        return try BackendCoding.decoder().decode(BackendModel.self, from: Data(json.utf8))
    }

    private func jsonObject(_ result: ToolResult) throws -> [String: Any] {
        guard case .text(let text) = try #require(result.content.first) else { throw ToolError("expected text") }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
