import Foundation
import Testing
@testable import Lenora

@MainActor
private func cloudinaryCatalog() throws -> ModelCatalog {
    let catalog = ModelCatalog()
    catalog.apply(try BackendCoding.decoder().decode(BackendCapabilities.self, from: ProtocolFixtures.data("Capabilities.cloudinary")))
    return catalog
}

@MainActor
struct GenerationServiceProviderTests {
    private func start(_ service: GenerationService, editor: EditorViewModel, source: MediaAsset) -> String {
        var input = GenerationInput(prompt: "", model: "cloudinary/background-removal", duration: 0, aspectRatio: "")
        input.createdAt = Date()
        return service.generate(
            genInput: input, assetType: .image, placeholderDuration: 0, references: [source],
            name: "Remove Background", buildParams: { _ in .removeBackground },
            fileExtension: "png", projectURL: editor.projectURL, editor: editor
        )
    }

    private func placeholder(_ id: String, in editor: EditorViewModel) throws -> MediaAsset {
        try #require(editor.mediaAssets.first { $0.id == id })
    }

    @Test func submitsJobWithModelKindAndAssetRefsAndPersistsJobId() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let catalog = try cloudinaryCatalog()
        let provider = FakeProvider(states: [jobState(.running)])
        let service = GenerationService(provider: { provider }, catalog: catalog)
        let placeholder = try placeholder(start(service, editor: fixture.editor, source: fixture.image), in: fixture.editor)
        try await fixture.waitUntil { placeholder.generationInput?.jobId == "fake:1" }
        let (job, key) = try #require(await provider.submitted.first)
        #expect(job.kind == "image.removeBackground")
        #expect(job.model == "cloudinary/background-removal")
        #expect(job.inputs == [.assetRef(try #require(await provider.uploads.first))])
        #expect(!key.isEmpty)
        service.stopMonitoring()
    }

    @Test func unknownModelFailsPlaceholderWithoutSubmitting() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let provider = FakeProvider(states: [])
        let service = GenerationService(provider: { provider }, catalog: ModelCatalog())
        let placeholder = try placeholder(start(service, editor: fixture.editor, source: fixture.image), in: fixture.editor)
        try await fixture.waitUntil { if case .failed = placeholder.generationStatus { true } else { false } }
        #expect(await provider.submitted.isEmpty)
        #expect(await provider.uploads.isEmpty)
    }

    @Test func disconnectedBackendFailsPlaceholder() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let catalog = try cloudinaryCatalog()
        let service = GenerationService(provider: { nil }, catalog: catalog)
        let placeholder = try placeholder(start(service, editor: fixture.editor, source: fixture.image), in: fixture.editor)
        try await fixture.waitUntil { placeholder.generationStatus == .failed(GenerationError.backendUnavailable.localizedDescription) }
    }

    @Test func failedJobMarksPlaceholderFailedWithMessage() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let catalog = try cloudinaryCatalog()
        let failed = try BackendCoding.decoder().decode(JobState.self, from: ProtocolFixtures.data("JobState.failed"))
        let service = GenerationService(provider: { FakeProvider(states: [failed]) }, catalog: catalog)
        let placeholder = try placeholder(start(service, editor: fixture.editor, source: fixture.image), in: fixture.editor)
        try await fixture.waitUntil { placeholder.generationStatus == .failed("Resource not found") }
    }

    @Test func succeededJobLandsResultInProject() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let catalog = try cloudinaryCatalog()
        let result = JobResult(url: fixture.servedImageURL, contentType: "image/png", fileExtension: "png")
        let service = GenerationService(provider: { FakeProvider(states: [jobState(.succeeded, results: [result])]) }, catalog: catalog)
        let placeholder = try placeholder(start(service, editor: fixture.editor, source: fixture.image), in: fixture.editor)
        try await fixture.waitUntil { fixture.isFinalized(placeholder) }
        #expect(placeholder.generationInput?.results == [result])
    }

    @Test func rejectedResultDownloadKeepsRetryableFailure() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let catalog = try cloudinaryCatalog()
        fixture.editor.remoteDownloadFetch = { request in
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try Data().write(to: file)
            return (file, HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let result = JobResult(url: fixture.servedImageURL, contentType: "image/png", fileExtension: "png")
        let service = GenerationService(provider: { FakeProvider(states: [jobState(.succeeded, results: [result])]) }, catalog: catalog)
        let placeholder = try placeholder(start(service, editor: fixture.editor, source: fixture.image), in: fixture.editor)
        try await fixture.waitUntil { placeholder.generationStatus == .failed(RemoteDownloadError.badStatus(404).localizedDescription) }
        #expect(placeholder.pendingDownloadURL == fixture.servedImageURL)
    }

    @Test func retryDownloadLandsPersistedResult() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let result = JobResult(url: fixture.servedImageURL, contentType: "image/png", fileExtension: "png")
        let placeholder = fixture.addGeneratingPlaceholder(jobId: "fake:1", fileExtension: "png")
        placeholder.generationInput?.results = [result]
        placeholder.generationStatus = .failed("The download failed (HTTP 404).")
        placeholder.pendingDownloadURL = fixture.servedImageURL
        let service = GenerationService(provider: { nil }, catalog: ModelCatalog())
        service.retryDownload(asset: placeholder, editor: fixture.editor)
        try await fixture.waitUntil { fixture.isFinalized(placeholder) }
        #expect(placeholder.pendingDownloadURL == nil)
    }

    @Test func transientPollingFailureLeavesPlaceholderGenerating() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let catalog = try cloudinaryCatalog()
        let provider = FakeProvider(states: [jobState(.running)], failure: .unreachable(URL(string: "https://backend.example")!))
        let service = GenerationService(provider: { provider }, catalog: catalog)
        let placeholder = try placeholder(start(service, editor: fixture.editor, source: fixture.image), in: fixture.editor)
        try await fixture.waitUntil { placeholder.generationInput?.jobId != nil }
        try await fixture.waitUntil { service.monitoredJobIds.isEmpty }
        #expect(placeholder.generationStatus == .generating)
    }

    @Test func permanentPollingFailureFailsPlaceholder() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let catalog = try cloudinaryCatalog()
        let provider = FakeProvider(states: [], failure: .unauthorized)
        let service = GenerationService(provider: { provider }, catalog: catalog)
        let placeholder = try placeholder(start(service, editor: fixture.editor, source: fixture.image), in: fixture.editor)
        try await fixture.waitUntil { placeholder.generationStatus == .failed(BackendError.unauthorized.localizedDescription) }
    }

    @Test func notCancellableKeepsPlaceholder() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let catalog = try cloudinaryCatalog()
        let provider = FakeProvider(states: [jobState(.running)])
        let service = GenerationService(provider: { provider }, catalog: catalog)
        let id = start(service, editor: fixture.editor, source: fixture.image)
        let placeholder = try placeholder(id, in: fixture.editor)
        try await fixture.waitUntil { placeholder.generationInput?.jobId != nil }
        #expect(await service.cancelGeneration(placeholder, editor: fixture.editor) == .notCancellable)
        #expect(fixture.editor.mediaAssets.contains { $0.id == id })
        service.stopMonitoring()
    }

    @Test func cancelledJobRemovesPlaceholderWithoutUndoEntry() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let catalog = try cloudinaryCatalog()
        let undoManager = UndoManager()
        fixture.editor.undo.attach(undoManager)
        let provider = FakeProvider(states: [jobState(.running)])
        await provider.setCancelResult(.success(jobState(.cancelled)))
        let service = GenerationService(provider: { provider }, catalog: catalog)
        let id = start(service, editor: fixture.editor, source: fixture.image)
        let placeholder = try placeholder(id, in: fixture.editor)
        try await fixture.waitUntil { placeholder.generationInput?.jobId != nil }
        #expect(await service.cancelGeneration(placeholder, editor: fixture.editor) == .cancelled)
        #expect(!fixture.editor.mediaAssets.contains { $0.id == id })
        #expect(!fixture.editor.mediaManifest.entries.contains { $0.id == id })
        #expect(!undoManager.canUndo)
    }

    @Test func cancelFailureIsReported() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let placeholder = fixture.addGeneratingPlaceholder(jobId: "fake:1", fileExtension: "png")
        let provider = FakeProvider(states: [])
        await provider.setCancelResult(.failure(.unauthorized))
        let service = GenerationService(provider: { provider }, catalog: ModelCatalog())
        #expect(await service.cancelGeneration(placeholder, editor: fixture.editor) == .failed(BackendError.unauthorized.localizedDescription))
        #expect(fixture.editor.mediaAssets.contains { $0 === placeholder })
    }
}

@MainActor
struct GenerationCancellationTests {
    @Test func stopMonitoringLeavesJobResumable() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let catalog = try cloudinaryCatalog()
        let service = GenerationService(provider: { FakeProvider(states: [jobState(.running)]) }, catalog: catalog)
        var input = GenerationInput(prompt: "", model: "cloudinary/background-removal", duration: 0, aspectRatio: "")
        input.createdAt = Date()
        let id = service.generate(
            genInput: input, assetType: .image, placeholderDuration: 0, references: [fixture.image],
            name: "Remove Background", buildParams: { _ in .removeBackground },
            fileExtension: "png", projectURL: fixture.editor.projectURL, editor: fixture.editor
        )
        let placeholder = try #require(fixture.editor.mediaAssets.first { $0.id == id })
        try await fixture.waitUntil { placeholder.generationInput?.jobId != nil }
        service.stopMonitoring()
        #expect(placeholder.generationStatus == .generating)
        #expect(placeholder.generationInput?.jobId == "fake:1")
    }
}

@MainActor
struct GenerationResumeTests {
    @Test func resumesPersistedJobAndFinalizes() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let placeholder = fixture.addGeneratingPlaceholder(jobId: "fake:1", fileExtension: "png")
        let result = JobResult(url: fixture.servedImageURL, contentType: "image/png", fileExtension: "png")
        let provider = FakeProvider(states: [jobState(.succeeded, results: [result])])
        let service = GenerationService(provider: { provider }, catalog: ModelCatalog())
        service.resumePendingGenerations(editor: fixture.editor)
        try await fixture.waitUntil { fixture.isFinalized(placeholder) }
        #expect(await provider.pollers == 1)
        #expect(placeholder.url.pathExtension == "png")
    }

    @Test func persistedResultsFinalizeWithoutPolling() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let result = JobResult(url: fixture.servedImageURL, contentType: "image/png", fileExtension: "png")
        let placeholder = fixture.addGeneratingPlaceholder(jobId: "fake:1", fileExtension: "png")
        placeholder.generationInput?.results = [result]
        placeholder.generationStatus = .downloading
        let provider = FakeProvider(states: [])
        let service = GenerationService(provider: { provider }, catalog: ModelCatalog())
        service.resumePendingGenerations(editor: fixture.editor)
        try await fixture.waitUntil { fixture.isFinalized(placeholder) }
        #expect(await provider.pollers == 0)
    }

    @Test func resumeWithoutBackendLeavesJobPending() async throws {
        let fixture = try await EditorTestFixture.withImage()
        defer { fixture.cleanup() }
        let placeholder = fixture.addGeneratingPlaceholder(jobId: "fake:1", fileExtension: "png")
        let service = GenerationService(provider: { nil }, catalog: ModelCatalog())
        service.resumePendingGenerations(editor: fixture.editor)
        #expect(service.monitoredJobIds.isEmpty)
        #expect(placeholder.generationStatus == .generating)
    }
}
