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

    private func speech(voice: String? = "nova", style: String? = "Warm.", videoURL: String? = nil, sourceURL: String? = nil,
                        referenceImageURL: String? = nil, referenceAudioURLs: [String]? = nil) -> GenerationJobParams {
        .audio(AudioGenerationParams(prompt: "Hello.", voice: voice, lyrics: nil, styleInstructions: style, instrumental: false,
                                     durationSeconds: nil, videoURL: videoURL, sourceURL: sourceURL,
                                     referenceImageURL: referenceImageURL, referenceAudioURLs: referenceAudioURLs))
    }

    @Test func speechCarriesOnlyScriptVoiceAndStyle() throws {
        let parts = try speech().jobParts(uploaded: [])
        #expect(parts.inputs.isEmpty)
        #expect(parts.params as? SpeechParams == SpeechParams(prompt: "Hello.", voice: "nova", styleInstructions: "Warm."))
    }

    @Test func emptySpeechOptionsAreOmitted() throws {
        let parts = try speech(voice: "", style: "").jobParts(uploaded: [])
        let data = try BackendCoding.encoder().encode(try #require(parts.params as? SpeechParams))
        #expect(String(decoding: data, as: UTF8.self) == #"{"prompt":"Hello."}"#)
    }

    @Test func speechRefusesMediaInputs() {
        let refused: [(GenerationJobParams, [String])] = [
            (speech(), ["ref"]), (speech(videoURL: "v"), []), (speech(sourceURL: "s"), []),
            (speech(referenceImageURL: "i"), []), (speech(referenceAudioURLs: ["a"]), []),
        ]
        for (params, uploaded) in refused {
            #expect(throws: GenerationError.self) { try params.jobParts(uploaded: uploaded) }
        }
    }
}
