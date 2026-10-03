import Foundation
import Testing
@testable import Lenora

@MainActor
struct RemoveBackgroundRetryTests {
    private final class ProviderBox {
        var current: FakeProvider
        init(_ provider: FakeProvider) { current = provider }
    }

    private static let unavailable = BackendError.problem(
        BackendProblem(code: "provider_unavailable", detail: nil, status: 503, retryable: true)
    )

    private func failedRemoval(
        box: ProviderBox,
        catalog: ModelCatalog
    ) async throws -> (EditorTestFixture, MediaAsset) {
        let editor = EditorViewModel(generationProvider: { box.current }, modelCatalog: catalog)
        let fixture = try await EditorTestFixture.withImage(editor: editor, catalog: catalog)
        guard case .started(let id, _) = await EditSubmitter.submitRemoveBackground(asset: fixture.image, editor: editor) else {
            throw EditorTestFixture.Timeout()
        }
        let placeholder = try #require(editor.mediaAssets.first { $0.id == id })
        try await fixture.waitUntil { if case .failed = placeholder.generationStatus { true } else { false } }
        return (fixture, placeholder)
    }

    @Test func failedUploadOffersRetryFromTheSource() async throws {
        let box = ProviderBox(FakeProvider(states: [], uploadFailure: Self.unavailable))
        let (fixture, placeholder) = try await failedRemoval(box: box, catalog: EditorTestFixture.connectedCatalog())
        defer { fixture.cleanup() }
        #expect(fixture.editor.removeBackgroundRetrySource(for: placeholder) === fixture.image)
    }

    @Test func retryReplacesTheFailedPlaceholderAndLandsAsOneUndoStep() async throws {
        let box = ProviderBox(FakeProvider(states: [], uploadFailure: Self.unavailable))
        let (fixture, failed) = try await failedRemoval(box: box, catalog: EditorTestFixture.connectedCatalog())
        defer { fixture.cleanup() }
        let editor = fixture.editor
        #expect(!fixture.undoManager.canUndo)

        let result = JobResult(url: EditorTestFixture.servedImageURL, contentType: "image/png", fileExtension: "png")
        box.current = FakeProvider(states: [jobState(.succeeded, results: [result])])
        guard case .started(let retriedId, _) = await editor.retryRemoveBackground(failed) else {
            Issue.record("expected the retry to start"); return
        }
        #expect(editor.mediaAssetsById[failed.id] == nil)
        let retried = try #require(editor.mediaAssets.first { $0.id == retriedId })
        try await fixture.waitUntil { fixture.isFinalized(retried) }
        #expect(editor.mediaAssets.map(\.id) == [fixture.image.id, retriedId])
        #expect(fixture.undoManager.undoActionName == "Remove Background")

        fixture.undoManager.undo()
        #expect(editor.mediaAssets.map(\.id) == [fixture.image.id])
        #expect(!fixture.undoManager.canUndo)
    }

    @Test func noRetryOnceTheSourceIsGone() async throws {
        let box = ProviderBox(FakeProvider(states: [], uploadFailure: Self.unavailable))
        let (fixture, placeholder) = try await failedRemoval(box: box, catalog: EditorTestFixture.connectedCatalog())
        defer { fixture.cleanup() }
        fixture.editor.removeGenerationPlaceholders([fixture.image])
        #expect(fixture.editor.removeBackgroundRetrySource(for: placeholder) == nil)
        #expect(await fixture.editor.retryRemoveBackground(placeholder) == nil)
        #expect(fixture.editor.mediaAssetsById[placeholder.id] === placeholder)
    }

    @Test func noRetryWhenTheBackendStopsOfferingTheTransform() async throws {
        let catalog = try EditorTestFixture.connectedCatalog()
        let box = ProviderBox(FakeProvider(states: [], uploadFailure: Self.unavailable))
        let (fixture, placeholder) = try await failedRemoval(box: box, catalog: catalog)
        defer { fixture.cleanup() }
        catalog.apply(.empty)
        #expect(fixture.editor.removeBackgroundRetrySource(for: placeholder) == nil)
    }

    @Test func noRetryWhileTheJobIsStillRunning() async throws {
        let provider = FakeProvider(states: [], hangsOnUpload: true)
        let fixture = try await EditorTestFixture.withImage(provider: provider, catalog: EditorTestFixture.connectedCatalog())
        defer { fixture.cleanup() }
        guard case .started(let id, _) = await EditSubmitter.submitRemoveBackground(asset: fixture.image, editor: fixture.editor) else {
            Issue.record("expected the job to start"); return
        }
        let placeholder = try #require(fixture.editor.mediaAssets.first { $0.id == id })
        #expect(fixture.editor.removeBackgroundRetrySource(for: placeholder) == nil)
        fixture.editor.generationService.stopMonitoring()
    }
}
