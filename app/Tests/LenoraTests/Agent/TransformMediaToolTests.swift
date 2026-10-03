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
        let outcome = await EditSubmitter.submitRemoveBackground(asset: fixture.image, editor: fixture.editor)
        #expect(outcome == .refused(.tooLarge(maxBytes: 10_485_760)))
        #expect(fixture.editor.mediaAssets.count == 1)
        #expect(await provider.uploads.isEmpty)
    }

    @Test func refusesUnsupportedType() async throws {
        let fixture = try await EditorTestFixture.withImage(fileExtension: "gif", catalog: EditorTestFixture.connectedCatalog())
        defer { fixture.cleanup() }
        let outcome = await EditSubmitter.submitRemoveBackground(asset: fixture.image, editor: fixture.editor)
        #expect(outcome == .refused(.unsupportedType("image/gif")))
        #expect(fixture.editor.mediaAssets.count == 1)
    }

    @Test func acceptsHEIFBecauseItUploadsAsJPEG() async throws {
        let provider = FakeProvider(states: [], hangsOnUpload: true)
        let fixture = try await EditorTestFixture.withImage(
            fileExtension: "heif", provider: provider, catalog: EditorTestFixture.connectedCatalog()
        )
        defer { fixture.cleanup() }
        let outcome = await EditSubmitter.submitRemoveBackground(asset: fixture.image, editor: fixture.editor)
        guard case .started = outcome else { Issue.record("expected the job to start, got \(outcome)"); return }
        try await fixture.waitUntil { await !provider.uploads.isEmpty }
        #expect(await provider.uploads.allSatisfy { $0.hasSuffix(".jpg") })
        fixture.editor.generationService.stopMonitoring()
    }

    @Test func unknownTypeIsNamedByItsExtension() async throws {
        let fixture = try await EditorTestFixture.withImage(fileExtension: "qzx", catalog: EditorTestFixture.connectedCatalog())
        defer { fixture.cleanup() }
        let outcome = await EditSubmitter.submitRemoveBackground(asset: fixture.image, editor: fixture.editor)
        #expect(outcome == .refused(.unsupportedType("QZX")))
        #expect(fixture.editor.mediaAssets.count == 1)
    }

    @Test func refusesNonImage() async throws {
        let fixture = try await EditorTestFixture.withVideo(catalog: EditorTestFixture.connectedCatalog())
        defer { fixture.cleanup() }
        let video = try #require(fixture.video)
        #expect(await EditSubmitter.submitRemoveBackground(asset: video, editor: fixture.editor) == .refused(.notAnImage))
    }

    @Test func refusesWhenBackendLacksTheOperation() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        #expect(await EditSubmitter.submitRemoveBackground(asset: fixture.image, editor: fixture.editor) == .refused(.unavailable))
    }

    @Test func getMediaReportsResultAsPendingWhileUploading() async throws {
        let provider = FakeProvider(states: [], hangsOnUpload: true)
        let fixture = try await EditorTestFixture.withImage(provider: provider, catalog: EditorTestFixture.connectedCatalog())
        defer { fixture.cleanup() }
        let receipt = await run(fixture, operation: "removeBackground")
        guard case .text(let text) = try #require(receipt.content.first) else { Issue.record("expected text"); return }
        let shortId = try #require((try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["mediaRef"] as? String)
        try await fixture.waitUntil { await !provider.uploads.isEmpty }

        func assets(_ args: [String: Any]) async throws -> [[String: Any]] {
            let result = await fixture.executor.execute(name: "get_media", args: args, source: "mcp")
            guard case .text(let json) = try #require(result.content.first) else { return [] }
            return try #require((try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["assets"] as? [[String: Any]])
        }
        let listed = try #require(try await assets([:]).first { ($0["id"] as? String)?.hasPrefix(shortId) == true })
        #expect(listed["generationStatus"] as? String == "preparing")
        let pending = try await assets(["pending": true])
        #expect(pending.contains { ($0["id"] as? String)?.hasPrefix(shortId) == true })
        fixture.editor.generationService.stopMonitoring()
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
        guard case .started(let id, _) = await EditSubmitter.submitRemoveBackground(asset: fixture.image, editor: fixture.editor) else {
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
        guard case .started(let id, _) = await EditSubmitter.submitRemoveBackground(asset: fixture.image, editor: fixture.editor) else {
            Issue.record("expected the job to start"); return
        }
        let placeholder = try #require(fixture.editor.mediaAssets.first { $0.id == id })
        try await fixture.waitUntil { if case .failed = placeholder.generationStatus { true } else { false } }
        #expect(!fixture.undoManager.canUndo)
    }

    @Test func listModelsDescribesBackgroundRemovalModel() throws {
        let model = try #require(EditorTestFixture.connectedCatalog().models(ofKind: EditSubmitter.removeBackgroundKind).first)
        let info = ToolExecutor.transformModelInfo(model)
        #expect(info["type"] as? String == "transform")
        #expect(info["operation"] as? String == "removeBackground")
        #expect(info["maxBytes"] as? Int64 == 10_485_760)
    }
}
