import Foundation
import Testing
@testable import Lenora

@MainActor
struct TransformMediaToolTests {
    private func run(_ fixture: EditorTestFixture, operation: String, source: String = "mcp") async -> ToolResult {
        await fixture.executor.execute(
            name: "transform_media",
            args: ["mediaRef": fixture.image.id, "operation": operation],
            source: source
        )
    }

    @Test func rejectsUnknownOperation() async throws {
        let fixture = try await EditorTestFixture.withImage(catalog: EditorTestFixture.connectedCatalog())
        defer { fixture.cleanup() }
        let result = await run(fixture, operation: "sharpen")
        #expect(result.isError)
        #expect(fixture.editor.mediaAssets.count == 1)
    }

    @Test func refusesWithoutBackendAndCreatesNothing() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let result = await run(fixture, operation: "removeBackground", source: "in-app")
        #expect(result.isError)
        #expect(fixture.editor.mediaAssets.count == 1)
        #expect(!fixture.undoManager.canUndo)
    }

    @Test func refusesOversizedImageBeforeUpload() async throws {
        let provider = FakeProvider(states: [])
        let fixture = try await EditorTestFixture.withImage(
            byteCount: 10_485_761, provider: provider, catalog: EditorTestFixture.connectedCatalog()
        )
        defer { fixture.cleanup() }
        let outcome = await EditSubmitter.submitEdit(.removeBackground, asset: fixture.image, editor: fixture.editor)
        #expect(outcome == .refused(.tooLarge(maxBytes: 10_485_760)))
        #expect(fixture.editor.mediaAssets.count == 1)
        #expect(await provider.uploads.isEmpty)
    }

    @Test func refusesUnsupportedType() async throws {
        let fixture = try await EditorTestFixture.withImage(fileExtension: "gif", catalog: EditorTestFixture.connectedCatalog())
        defer { fixture.cleanup() }
        let outcome = await EditSubmitter.submitEdit(.removeBackground, asset: fixture.image, editor: fixture.editor)
        #expect(outcome == .refused(.unsupportedType("image/gif")))
        #expect(fixture.editor.mediaAssets.count == 1)
    }

    @Test func refusesNonImage() async throws {
        let fixture = try await EditorTestFixture.withVideo(catalog: EditorTestFixture.connectedCatalog())
        defer { fixture.cleanup() }
        let video = try #require(fixture.video)
        #expect(await EditSubmitter.submitEdit(.removeBackground, asset: video, editor: fixture.editor) == .refused(.wrongMediaType(.image)))
    }

    @Test func refusesWhenBackendLacksTheOperation() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        #expect(await EditSubmitter.submitEdit(.removeBackground, asset: fixture.image, editor: fixture.editor) == .refused(.unavailable(kind: "image.removeBackground")))
    }

    @Test func startReturnsStructuredReceipt() async throws {
        let fixture = try await EditorTestFixture.withImage(
            provider: FakeProvider(states: [jobState(.running)]), catalog: EditorTestFixture.connectedCatalog()
        )
        defer { fixture.cleanup() }
        let result = await run(fixture, operation: "removeBackground")
        guard case .text(let text) = try #require(result.content.first) else { Issue.record("expected text"); return }
        let receipt = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(receipt["status"] as? String == "generating")
        #expect((receipt["sourceMediaRef"] as? String).map(fixture.image.id.hasPrefix) == true)
        #expect((receipt["estimate"] as? [String: Any])?["unit"] as? String == "cloudinary_credits")
        let shortId = try #require(receipt["mediaRef"] as? String)
        let placeholder = try #require(fixture.editor.mediaAssets.first { $0.id.hasPrefix(shortId) })
        try await fixture.waitUntil { placeholder.generationInput?.imageURLAssetIds != nil }
        #expect(placeholder.generationInput?.imageURLAssetIds == [fixture.image.id])
        #expect(placeholder.folderId == fixture.image.folderId)
        fixture.editor.generationService.stopMonitoring()
    }

    @Test func landedResultIsOneNamedUndoStep() async throws {
        let result = JobResult(url: EditorTestFixture.servedImageURL, contentType: "image/png", fileExtension: "png")
        let fixture = try await EditorTestFixture.withImage(
            provider: FakeProvider(states: [jobState(.succeeded, results: [result])]),
            catalog: EditorTestFixture.connectedCatalog()
        )
        defer { fixture.cleanup() }
        guard case .started(let id, _) = await EditSubmitter.submitEdit(.removeBackground, asset: fixture.image, editor: fixture.editor) else {
            Issue.record("expected the job to start"); return
        }
        let placeholder = try #require(fixture.editor.mediaAssets.first { $0.id == id })
        try await fixture.waitUntil { fixture.isFinalized(placeholder) }
        #expect(fixture.undoManager.undoActionName == "Remove Background")

        fixture.undoManager.undo()
        #expect(fixture.editor.mediaAssets.map(\.id) == [fixture.image.id])
        fixture.undoManager.redo()
        #expect(fixture.editor.mediaAssets.contains { $0.id == id })
    }

    @Test func failedDownloadRegistersNoUndo() async throws {
        let result = JobResult(url: EditorTestFixture.servedImageURL, contentType: "image/png", fileExtension: "png")
        let fixture = try await EditorTestFixture.withImage(
            provider: FakeProvider(states: [jobState(.succeeded, results: [result])]),
            catalog: EditorTestFixture.connectedCatalog()
        )
        defer { fixture.cleanup() }
        fixture.editor.remoteDownloadFetch = { _ in throw URLError(.notConnectedToInternet) }
        guard case .started(let id, _) = await EditSubmitter.submitEdit(.removeBackground, asset: fixture.image, editor: fixture.editor) else {
            Issue.record("expected the job to start"); return
        }
        let placeholder = try #require(fixture.editor.mediaAssets.first { $0.id == id })
        try await fixture.waitUntil { if case .failed = placeholder.generationStatus { true } else { false } }
        #expect(!fixture.undoManager.canUndo)
    }

    @Test func unadvertisedOpIsRefused() async throws {
        let fixture = try await EditorTestFixture.withImage(catalog: EditorTestFixture.connectedCatalog())
        defer { fixture.cleanup() }
        #expect(await EditSubmitter.submitEdit(.edit(.restore), asset: fixture.image, editor: fixture.editor) == .refused(.unavailable(kind: "image.edit")))
    }

    @Test func upscaleRefusesTooManyPixelsBeforeSubmitting() async throws {
        let fixture = try await EditorTestFixture.withImage(
            width: 2049, height: 2048, catalog: EditorTestFixture.connectedCatalog("Capabilities.cloudinaryFull")
        )
        defer { fixture.cleanup() }
        let refusal = await EditSubmitter.upscaleRefusal(asset: fixture.image, modelId: "cloudinary/upscale", editor: fixture.editor)
        #expect(refusal == .tooManyPixels(maxPixels: 4_194_304))
        #expect(fixture.editor.mediaAssets.count == 1)
        #expect(!fixture.undoManager.canUndo)
    }

    @Test func upscaleToolReturnsStructuredRefusalForOversizedImage() async throws {
        let fixture = try await EditorTestFixture.withImage(
            width: 2049, height: 2048, catalog: EditorTestFixture.connectedCatalog("Capabilities.cloudinaryFull")
        )
        defer { fixture.cleanup() }
        let result = await fixture.executor.execute(name: "upscale_media", args: ["mediaRef": fixture.image.id], source: "mcp")
        #expect(result.isError)
        guard case .text(let text) = try #require(result.content.first) else { Issue.record("expected text"); return }
        let error = try #require((try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["error"] as? [String: Any])
        #expect(error["code"] as? String == "input_too_large")
        #expect(fixture.editor.mediaAssets.count == 1)
        #expect(!fixture.undoManager.canUndo)
    }

    @Test func landedUpscaleIsOneNamedUndoStep() async throws {
        let result = JobResult(url: EditorTestFixture.servedImageURL, contentType: "image/png", fileExtension: "png")
        let fixture = try await EditorTestFixture.withImage(
            provider: FakeProvider(states: [jobState(.succeeded, results: [result])]),
            catalog: EditorTestFixture.connectedCatalog("Capabilities.cloudinaryFull")
        )
        defer { fixture.cleanup() }
        let model = try #require(UpscaleModelConfig.models(for: .image, in: fixture.editor.generationService.catalog).first { $0.id == "cloudinary/upscale" })
        let id = try #require(EditSubmitter.submitUpscale(asset: fixture.image, model: model, editor: fixture.editor))
        let placeholder = try #require(fixture.editor.mediaAssets.first { $0.id == id })
        try await fixture.waitUntil { fixture.isFinalized(placeholder) }
        #expect(fixture.undoManager.undoActionName == "Upscale")

        fixture.undoManager.undo()
        #expect(fixture.editor.mediaAssets.map(\.id) == [fixture.image.id])
    }

    @Test func upscaleAcceptsTheLargestImage() async throws {
        let fixture = try await EditorTestFixture.withImage(
            width: 2048, height: 2048, catalog: EditorTestFixture.connectedCatalog("Capabilities.cloudinaryFull")
        )
        defer { fixture.cleanup() }
        #expect(await EditSubmitter.upscaleRefusal(asset: fixture.image, modelId: "cloudinary/upscale", editor: fixture.editor) == nil)
    }

    @Test func listModelsDescribesBackgroundRemovalModel() throws {
        let model = try #require(EditorTestFixture.connectedCatalog().models(ofKind: "image.removeBackground").first)
        let info = ToolExecutor.transformModelInfo(model)
        #expect(info["type"] as? String == "transform")
        #expect(info["operations"] as? [String] == ["removeBackground"])
        #expect(info["maxBytes"] as? Int64 == 10_485_760)
    }

    @Test func schemaListsOnlySupportedOperations() throws {
        #expect(ToolDefinitions.transformOperations(catalog: try EditorTestFixture.connectedCatalog()) == ["removeBackground"])
        #expect(ToolDefinitions.transformOperations(catalog: try EditorTestFixture.connectedCatalog("Capabilities.cloudinaryFull")) ==
                ["removeBackground", "generativeFill", "replace", "remove", "recolor", "backgroundReplace", "restore", "reframe"])
    }

    @Test func listedSchemaEnumFollowsTheCatalog() throws {
        let tool = try #require(ToolDefinitions.available(ToolDefinitions.mcpServer, catalog: try EditorTestFixture.connectedCatalog()).first { $0.name == .transformMedia })
        let operation = (tool.inputSchema["properties"] as? [String: Any])?["operation"] as? [String: Any]
        #expect(operation?["enum"] as? [String] == ["removeBackground"])
    }

    @Test(arguments: [
        (["operation": "remove", "prompt": "the cat, left"], "prompt"),
        (["operation": "recolor", "prompt": "jacket", "color": "blue"], "color"),
        (["operation": "generativeFill", "aspectRatio": "2:1"], "aspectRatio"),
        (["operation": "replace", "from": "cup"], "to"),
    ] as [([String: String], String)])
    func invalidFieldsAreNamed(args: [String: String], field: String) async throws {
        let fixture = try await EditorTestFixture.withImage(catalog: EditorTestFixture.connectedCatalog("Capabilities.cloudinaryFull"))
        defer { fixture.cleanup() }
        let result = await fixture.executor.execute(name: "transform_media", args: args.merging(["mediaRef": fixture.image.id]) { a, _ in a }, source: "mcp")
        guard case .text(let text) = try #require(result.content.first) else { Issue.record("expected text"); return }
        let error = try #require((try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["error"] as? [String: Any])
        #expect(result.isError && error["code"] as? String == "invalid_request" && error["field"] as? String == field)
        #expect(fixture.editor.mediaAssets.count == 1 && !fixture.undoManager.canUndo)
    }

    @Test func reframeReceiptNamesTheOperation() async throws {
        let fixture = try await EditorTestFixture.withVideo(
            provider: FakeProvider(states: [jobState(.running)]), catalog: EditorTestFixture.connectedCatalog("Capabilities.cloudinaryFull")
        )
        defer { fixture.cleanup() }
        let video = try #require(fixture.video)
        let result = await fixture.executor.execute(name: "transform_media", args: ["mediaRef": video.id, "operation": "reframe", "aspectRatio": "9:16"], source: "mcp")
        guard case .text(let text) = try #require(result.content.first) else { Issue.record("expected text"); return }
        let receipt = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(receipt["operation"] as? String == "reframe" && receipt["status"] as? String == "generating")
        fixture.editor.generationService.stopMonitoring()
    }
}
