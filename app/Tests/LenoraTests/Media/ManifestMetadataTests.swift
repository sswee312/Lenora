import Foundation
import Testing
@testable import Lenora
@MainActor struct ManifestMetadataTests {
    private func asset(_ id: String) -> MediaAsset {
        MediaAsset(id: id, url: URL(fileURLWithPath: "/tmp/\(id).mp4"), type: .video, name: id, duration: 1)
    }
    @Test func largeBatchUpdatesInPlace() {
        let editor = EditorViewModel()
        let assets = (0..<1_000).map { asset("asset-\($0)") }
        editor.updateManifestMetadata(for: assets)
        for (index, asset) in assets.enumerated() { asset.duration = Double(index) }
        editor.updateManifestMetadata(for: Array(assets.reversed()))
        #expect(editor.mediaManifest.entries[731].duration == 731)
    }
    @Test func queuedFlushUsesLatestLiveAssets() async {
        let editor = EditorViewModel()
        let renamed = asset("renamed")
        let deleted = asset("deleted")
        editor.mediaAssets = [renamed, deleted]
        editor.updateManifestMetadata(for: [renamed, deleted])
        editor.queueManifestMetadataUpdate(for: renamed)
        editor.queueManifestMetadataUpdate(for: deleted)
        renamed.name = "Latest"
        editor.mediaAssets = [renamed]
        editor.mediaManifest.entries.removeAll { $0.id == deleted.id }
        await editor.pendingManifestMetadataFlushTask?.value
        #expect(editor.mediaManifest.entries.map(\.name) == ["Latest"])
    }
    @Test func draftGenerationSurvivesManifestRoundTrip() throws {
        let input = GenerationInput(
            prompt: "Draft", model: "flux-3", duration: 8,
            aspectRatio: "16:9", resolution: "720p", draft: true
        )
        let generated = MediaAsset(
            url: URL(fileURLWithPath: "/tmp/draft.mp4"),
            type: .video,
            name: "Draft",
            generationInput: input
        )
        let data = try JSONEncoder().encode(generated.toManifestEntry(projectURL: nil))
        let restored = try JSONDecoder().decode(MediaManifestEntry.self, from: data)
        #expect(restored.generationInput?.draft == true)
    }

    @Test func jobIdResultsAndEstimateSurviveManifestRoundTrip() throws {
        var input = GenerationInput(prompt: "", model: "cloudinary/background-removal", duration: 0, aspectRatio: "")
        input.jobId = "cloudinary:url:abc"
        input.results = [JobResult(url: URL(string: "https://res.cloudinary.com/demo/x.png")!, contentType: "image/png", fileExtension: "png")]
        input.estimate = BackendEstimate(amount: 0.075, unit: "cloudinary_credits")
        let generated = MediaAsset(url: URL(fileURLWithPath: "/tmp/out.png"), type: .image, name: "Out", generationInput: input)
        generated.generationStatus = .generating
        let data = try JSONEncoder().encode(generated.toManifestEntry(projectURL: nil))
        let asset = MediaAsset(
            entry: try JSONDecoder().decode(MediaManifestEntry.self, from: data),
            resolvedURL: generated.url
        )
        #expect(asset.generationInput == input)
        #expect(asset.canResumeGeneration)
        #expect(asset.isRecoveringGeneration)
    }
}
