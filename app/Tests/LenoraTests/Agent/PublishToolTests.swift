import Foundation
import MCP
import Testing
@testable import Lenora

@MainActor
struct PublishToolTests {
    private func fixture(_ provider: FakeProvider = FakeProvider(states: [])) async throws -> EditorTestFixture {
        try await EditorTestFixture.withImage(provider: provider, catalog: EditorTestFixture.connectedCatalog("Capabilities.cloudinaryFull"))
    }

    private func json(_ result: ToolResult) throws -> [String: Any] {
        guard case .text(let text) = try #require(result.content.first) else { throw ToolError("expected text") }
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func receipt(_ result: ToolResult) throws -> [String: Any] {
        #expect(!result.isError)
        return try json(result)
    }

    private func refusal(_ result: ToolResult) throws -> (code: String?, field: String?) {
        #expect(result.isError)
        let error = try #require(try json(result)["error"] as? [String: Any])
        #expect(error["message"] is String)
        return (error["code"] as? String, error["field"] as? String)
    }

    private func run(_ fixture: EditorTestFixture, _ tool: String, _ args: [String: Any]) async -> ToolResult {
        await fixture.executor.execute(name: tool, args: args, source: "mcp")
    }

    @Test func toolsAreListedOnlyWhenABackendPublishes() throws {
        let names: (ModelCatalog) -> Set<ToolName> = { Set(ToolDefinitions.available(ToolDefinitions.mcpServer, catalog: $0).map(\.name)) }
        #expect(names(try EditorTestFixture.connectedCatalog()).isDisjoint(with: [.publishExport, .managePublications]))
        #expect(names(try EditorTestFixture.connectedCatalog("Capabilities.cloudinaryFull")).isSuperset(of: [.publishExport, .managePublications]))
    }

    @Test func mcpToolListIncludesThePublishToolsWithTheirSchemas() async throws {
        let catalog = try EditorTestFixture.connectedCatalog("Capabilities.cloudinaryFull")
        let tools = ToolDefinitions.available(ToolDefinitions.mcpServer, catalog: catalog)
            .map { Tool(name: $0.name.rawValue, description: $0.description, inputSchema: $0.mcpSchemaValue) }
        let publish = try #require(tools.first { $0.name == "publish_export" })
        let manage = try #require(tools.first { $0.name == "manage_publications" })
        let properties = try #require(publish.inputSchema.objectValue?["properties"]?.objectValue)
        #expect(Set(properties.keys) == ["exportJobId", "publicationId", "confirmPublic", "vertical", "teaserSeconds"])
        #expect(manage.inputSchema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue) == ["action"])
    }

    @Test func unavailableBackendRefusesBothTools() async throws {
        let fixture = try await EditorTestFixture.withImage(catalog: EditorTestFixture.connectedCatalog())
        defer { fixture.cleanup() }
        #expect(try refusal(await run(fixture, "publish_export", ["confirmPublic": true])).code == "unavailable")
        #expect(try refusal(await run(fixture, "manage_publications", ["action": "list"])).code == "unavailable")
    }

    @Test(arguments: [false, "true"] as [any Sendable])
    func confirmPublicMustBeTrue(_ confirm: any Sendable) async throws {
        let provider = FakeProvider(states: [])
        let fixture = try await fixture(provider)
        defer { fixture.cleanup() }
        let result = try refusal(await run(fixture, "publish_export", ["exportJobId": UUID().uuidString, "confirmPublic": confirm]))
        #expect(result.code == "invalid_request")
        #expect(fixture.editor.publishService.publications.isEmpty)
        #expect(await provider.uploads.isEmpty)
    }

    @Test func teaserSecondsAsAStringIsRefused() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        let args: [String: Any] = ["exportJobId": UUID().uuidString, "confirmPublic": true, "teaserSeconds": "5"]
        #expect(try refusal(await run(fixture, "publish_export", args)).code == "invalid_request")
    }

    @Test func backendErrorsKeepTheirCode() async throws {
        let provider = FakeProvider(states: [])
        await provider.setDeleteResult(.failure(.problem(BackendProblem(code: "rate_limited", detail: "Slow down.", status: 429, retryable: true))))
        let fixture = try await fixture(provider)
        defer { fixture.cleanup() }
        let record = PublishFixtures.readyRecord()
        fixture.editor.publishService.restore([record])
        let result = try refusal(await run(fixture, "manage_publications", ["action": "unpublish", "publicationId": record.id.uuidString]))
        #expect(result.code == "rate_limited")
        #expect(await provider.deletedAssets == ["a"])
    }

    @Test func nonBackendFailuresAreInternalErrors() throws {
        let error = try #require(try json(ToolExecutor.publishError(CocoaError(.fileReadUnknown)))["error"] as? [String: Any])
        #expect(error["code"] as? String == "internal_error")
    }

    @Test func listIsNewestFirstByCreationTime() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        let newer = PublishFixtures.readyRecord(createdAt: Date(timeIntervalSince1970: 100))
        let older = PublishFixtures.readyRecord()
        fixture.editor.publishService.restore([newer, older])
        let list = try receipt(await run(fixture, "manage_publications", ["action": "list"]))["publications"] as? [[String: Any]]
        #expect(list?.map { $0["publicationId"] as? String } == [newer.id.uuidString, older.id.uuidString])
    }

    @Test func mcpToolListSignatureChangesWhenPublishingAppears() throws {
        let without = MCPService.toolListSignature(catalog: try EditorTestFixture.connectedCatalog())
        let with = MCPService.toolListSignature(catalog: try EditorTestFixture.connectedCatalog("Capabilities.cloudinaryFull"))
        #expect(!without.contains("publish_export") && with.contains("publish_export") && with.contains("manage_publications"))
    }

    @Test func publishRequiresConfirmationBeforeAnythingElse() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        let result = try refusal(await run(fixture, "publish_export", ["exportJobId": UUID().uuidString]))
        #expect(result.code == "invalid_request" && result.field == "confirmPublic")
        #expect(fixture.editor.publishService.publications.isEmpty)
    }

    @Test(arguments: [
        [:],
        ["exportJobId": UUID().uuidString, "publicationId": UUID().uuidString],
        ["exportJobId": "not-a-uuid"],
        ["exportJobId": UUID().uuidString, "teaserSeconds": 7.5],
        ["exportJobId": UUID().uuidString, "extra": true],
    ] as [[String: any Sendable]])
    func malformedRequestsAreRefused(_ args: [String: any Sendable]) async throws {
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        var full: [String: Any] = args
        full["confirmPublic"] = true
        #expect(try refusal(await run(fixture, "publish_export", full)).code == "invalid_request")
        #expect(fixture.editor.publishService.publications.isEmpty)
    }

    @Test func unknownExportIsRefusedWithoutUploading() async throws {
        let provider = FakeProvider(states: [])
        let fixture = try await fixture(provider)
        defer { fixture.cleanup() }
        let result = try refusal(await run(fixture, "publish_export", ["exportJobId": UUID().uuidString, "confirmPublic": true]))
        #expect(result.code == "invalid_request" && result.field == "exportJobId")
        #expect(await provider.uploads.isEmpty)
    }

    @Test func invalidOptionsNameTheirArgument() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        let record = PublishFixtures.readyRecord()
        fixture.editor.publishService.restore([record])
        let id = record.id.uuidString
        let teaser = try refusal(await run(fixture, "publish_export", ["publicationId": id, "confirmPublic": true, "teaserSeconds": 99]))
        #expect(teaser.code == "invalid_request" && teaser.field == "teaserSeconds")
        let vertical = try refusal(await run(fixture, "publish_export", ["publicationId": id, "confirmPublic": true, "vertical": "2:1"]))
        #expect(vertical.field == "vertical")
    }

    @Test func addingNothingNewReturnsANoopReceipt() async throws {
        let provider = FakeProvider(states: [])
        let fixture = try await fixture(provider)
        defer { fixture.cleanup() }
        let record = PublishFixtures.readyRecord()
        fixture.editor.publishService.restore([record])
        let receipt = try receipt(await run(fixture, "publish_export", ["publicationId": record.id.uuidString, "confirmPublic": true]))
        #expect(receipt["noop"] as? Bool == true && receipt["status"] as? String == "ready")
        #expect(await provider.submitted.isEmpty)
    }

    @Test func publicationThatNeverUploadedRefusesNewOutputs() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        var record = Publication(id: UUID(), exportFilename: "cut.mp4", createdAt: Date(), model: "cloudinary/publish",
                                 durationSeconds: 20, options: PublishOptions(), status: .failed, outputs: [])
        record.request(PublishOptions().roles, options: PublishOptions())
        record.markFailed(.uploadInterrupted)
        fixture.editor.publishService.restore([record])
        let result = try refusal(await run(fixture, "publish_export", ["publicationId": record.id.uuidString, "confirmPublic": true, "vertical": "9:16"]))
        #expect(result.code == "invalid_request" && result.field == "publicationId")
    }

    @Test func listGetAndRepeatedUnpublish() async throws {
        let provider = FakeProvider(states: [])
        let fixture = try await fixture(provider)
        defer { fixture.cleanup() }
        let record = PublishFixtures.readyRecord()
        fixture.editor.publishService.restore([record])
        let id = record.id.uuidString

        let list = try receipt(await run(fixture, "manage_publications", ["action": "list"]))["publications"] as? [[String: Any]]
        #expect(list?.map { $0["publicationId"] as? String } == [id])
        let got = try receipt(await run(fixture, "manage_publications", ["action": "get", "publicationId": id]))
        let outputs = try #require(got["outputs"] as? [[String: Any]])
        #expect(outputs.map { $0["role"] as? String } == ["stream", "download", "poster"])
        #expect(outputs.allSatisfy { $0["url"] is String })

        let first = try receipt(await run(fixture, "manage_publications", ["action": "unpublish", "publicationId": id]))
        #expect(first["noop"] as? Bool == false && first["status"] as? String == "unpublished")
        #expect(try receipt(await run(fixture, "manage_publications", ["action": "unpublish", "publicationId": id]))["noop"] as? Bool == true)
        #expect(await provider.deletedAssets == ["a"])
        #expect(fixture.editor.publishService.publications.first?.status == .unpublished)
    }

    @Test func unknownPublicationAndBadActionAreRefused() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        let unknown = try refusal(await run(fixture, "manage_publications", ["action": "get", "publicationId": UUID().uuidString]))
        #expect(unknown.code == "not_found" && unknown.field == "publicationId")
        let missing = try refusal(await run(fixture, "manage_publications", ["action": "unpublish"]))
        #expect(missing.code == "invalid_request" && missing.field == "publicationId")
        #expect(try refusal(await run(fixture, "manage_publications", ["action": "purge"])).field == "action")
    }

    @Test func closedServiceReportsCancelled() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        let record = PublishFixtures.readyRecord()
        fixture.editor.publishService.restore([record])
        fixture.editor.publishService.stopMonitoring()
        let result = try refusal(await run(fixture, "manage_publications", ["action": "unpublish", "publicationId": record.id.uuidString]))
        #expect(result.code == "cancelled")
    }
}

@MainActor
struct PublishListModelsTests {
    private func models(_ catalog: ModelCatalog, _ args: [String: Any] = [:]) async throws -> [[String: Any]] {
        let fixture = try await EditorTestFixture.withImage(provider: FakeProvider(states: []), catalog: catalog)
        defer { fixture.cleanup() }
        let result = await fixture.executor.execute(name: "list_models", args: args, source: "mcp")
        guard case .text(let text) = try #require(result.content.first) else { throw ToolError("expected text") }
        let body = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return try #require(body["models"] as? [[String: Any]])
    }

    @Test func listsThePublishModelWithItsLimits() async throws {
        let all = try await models(EditorTestFixture.connectedCatalog("Capabilities.cloudinaryFull"))
        let publish = try #require(all.first { $0["type"] as? String == "publish" })
        #expect(publish["id"] is String && publish["maxBytes"] is Int)
        #expect(publish["verticalAspects"] is [String])
        let teaser = try #require(publish["teaserSeconds"] as? [String: Int])
        #expect(teaser["min"] != nil && teaser["max"] != nil)
        let filtered = try await models(EditorTestFixture.connectedCatalog("Capabilities.cloudinaryFull"), ["type": "publish"])
        #expect(filtered.count == 1)
    }

    @Test func omitsThePublishModelWithoutPublishSupport() async throws {
        let all = try await models(EditorTestFixture.connectedCatalog())
        #expect(!all.contains { $0["type"] as? String == "publish" })
    }
}
