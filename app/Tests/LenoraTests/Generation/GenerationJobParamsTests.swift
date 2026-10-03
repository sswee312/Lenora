import Testing
@testable import Lenora

struct GenerationJobParamsTests {
    @Test func videoFramesAndReferencesCarryRoles() throws {
        let params = GenerationJobParams.video(VideoGenerationParams(
            prompt: "waves", duration: 8, aspectRatio: "16:9", resolution: "1080p",
            startFrameURL: "image/upload/lenora/a", endFrameURL: "image/upload/lenora/b",
            referenceImageURLs: ["image/upload/lenora/c"], generateAudio: false))
        let parts = try params.jobParts(uploaded: [])
        #expect(parts.inputs == [.assetRef("image/upload/lenora/a", role: .startFrame),
                                 .assetRef("image/upload/lenora/b", role: .endFrame),
                                 .assetRef("image/upload/lenora/c", role: .reference)])
        #expect(parts.params as? VideoGenerateParams == VideoGenerateParams(prompt: "waves", duration: 8, resolution: "1080p", aspectRatio: "16:9", generateAudio: false))
    }

    @Test func promptOnlyVideoHasNoInputs() throws {
        let parts = try GenerationJobParams.video(VideoGenerationParams(prompt: "a boat", duration: 4, aspectRatio: "", resolution: nil))
            .jobParts(uploaded: [])
        #expect(parts.inputs.isEmpty)
        #expect((parts.params as? VideoGenerateParams)?.aspectRatio == nil)
    }

    @Test func videoReferencesTheProtocolCannotCarryAreRefused() {
        let params = GenerationJobParams.video(VideoGenerationParams(prompt: "x", duration: 4, aspectRatio: "16:9", resolution: nil,
                                                                     referenceVideoURLs: ["video/upload/lenora/v"]))
        #expect(throws: GenerationError.self) { try params.jobParts(uploaded: []) }
    }

    @Test func imageReferencesAndCount() throws {
        let parts = try GenerationJobParams.image(ImageGenerationParams(
            prompt: "a lighthouse", aspectRatio: "1:1", resolution: nil, quality: nil,
            imageURLs: ["image/upload/lenora/r"], numImages: 3, seed: 7)).jobParts(uploaded: [])
        #expect(parts.inputs == [.assetRef("image/upload/lenora/r", role: .reference)])
        #expect(parts.params as? ImageGenerateParams == ImageGenerateParams(prompt: "a lighthouse", aspectRatio: "1:1", count: 3, seed: 7))
    }

    @MainActor @Test func requiresFirstFrameDefaultsToFalse() throws {
        let caps = try BackendCoding.decoder().decode(BackendCapabilities.self, from: ProtocolFixtures.data("Capabilities.cloudinaryFull"))
        let entry = try #require(caps.models.first { $0.kind == "video.generate" }.flatMap { try CatalogEntry(model: $0) })
        guard case .video(let videoCaps) = entry.uiCapabilities else { Issue.record("expected video caps"); return }
        #expect(videoCaps.requiresFirstFrame == false)
    }
}
