import Foundation
import Testing
@testable import Lenora

struct Spec2FixtureTests {
    private let ref = "image/upload/lenora/6f1c2b9e-3d4a-4f5b-8c7d-9e0f1a2b3c4d"

    private func matchesFixture(_ request: JobRequest, _ name: String) throws -> Bool {
        let encoded = try JSONSerialization.jsonObject(with: BackendCoding.encoder().encode(request)) as? NSDictionary
        let fixture = try JSONSerialization.jsonObject(with: ProtocolFixtures.data(name)) as? NSDictionary
        return encoded == fixture
    }

    @Test func decodesFullCapabilities() throws {
        let caps = try BackendCoding.decoder().decode(BackendCapabilities.self, from: ProtocolFixtures.data("Capabilities.cloudinaryFull"))
        let edit = try #require(caps.models.first { $0.kind == "image.edit" })
        #expect(edit.operations == ImageEditParams.operations)
        #expect(caps.models.first { $0.kind == "image.upscale" }?.inputs.maxPixels == 4_194_304)
        #expect(caps.models.first { $0.kind == "image.removeBackground" }?.inputs.maxPixels == nil)
    }

    @Test func decodesAddonAndBudgetDetails() throws {
        let health = try BackendCoding.decoder().decode(BackendHealth.self, from: ProtocolFixtures.data("Health.cloudinaryAddons"))
        let details = try #require(health.adapters?.first?.details)
        #expect(details.addons?.map(\.available) == [false, false])
        #expect(details.addons?.last?.reason == "turned off in settings")
        #expect(details.budget == BudgetStatus(limit: 5.0, used: 0.125, day: "2026-10-03"))
    }

    @Test func spec1HealthHasNoDetails() throws {
        let health = try BackendCoding.decoder().decode(BackendHealth.self, from: ProtocolFixtures.data("Health.authorized"))
        #expect(health.adapters?.allSatisfy { $0.details == nil } == true)
    }

    @Test func encodesImageGenerate() throws {
        let request = JobRequest(kind: "image.generate", model: "cloudinary/image-generation",
                                 inputs: [.assetRef(ref, role: .reference)],
                                 params: ImageGenerateParams(prompt: "A lighthouse at dusk, film grain", aspectRatio: "16:9", count: 2, seed: 42))
        #expect(try matchesFixture(request, "JobRequest.imageGenerate"))
    }

    @Test func encodesImageEditFlatWithOp() throws {
        let request = JobRequest(kind: "image.edit", model: "cloudinary/generative-edit", inputs: [.assetRef(ref)],
                                 params: ImageEditParams.recolor(prompt: "the jacket", color: "#1E90FF"))
        #expect(try matchesFixture(request, "JobRequest.imageEdit"))
    }

    @Test func encodesVideoGenerateWithStartFrame() throws {
        let request = JobRequest(kind: "video.generate", model: "cloudinary/image-to-video",
                                 inputs: [.assetRef(ref, role: .startFrame)],
                                 params: VideoGenerateParams(prompt: "Slow push-in, waves rolling", duration: 8, resolution: "1080p", aspectRatio: "16:9", generateAudio: false))
        #expect(try matchesFixture(request, "JobRequest.videoGenerate"))
    }

    @Test func encodesPromptOnlyVideoWithEmptyInputs() throws {
        let request = JobRequest(kind: "video.generate", model: "cloudinary/image-to-video", inputs: [],
                                 params: VideoGenerateParams(prompt: "A paper boat drifting down a rainy street", duration: 4, resolution: nil, aspectRatio: nil, generateAudio: nil))
        #expect(try matchesFixture(request, "JobRequest.videoGeneratePromptOnly"))
    }

    @Test func encodesReframe() throws {
        let request = JobRequest(kind: "video.reframe", model: "cloudinary/reframe",
                                 inputs: [.assetRef("video/upload/lenora/6f1c2b9e-3d4a-4f5b-8c7d-9e0f1a2b3c4d")],
                                 params: VideoReframeParams(aspectRatio: "9:16"))
        #expect(try matchesFixture(request, "JobRequest.videoReframe"))
    }

    @Test(arguments: [
        (ImageEditParams.fill(aspectRatio: "16:9"), #"{"aspectRatio":"16:9","op":"fill"}"#),
        (.replace(from: "the cup", to: "a mug"), #"{"from":"the cup","op":"replace","to":"a mug"}"#),
        (.remove(prompt: "the bee"), #"{"op":"remove","prompt":"the bee"}"#),
        (.backgroundReplace(prompt: nil), #"{"op":"backgroundReplace"}"#),
        (.restore, #"{"op":"restore"}"#),
    ])
    func encodesEachOp(params: ImageEditParams, json: String) throws {
        #expect(String(decoding: try BackendCoding.encoder().encode(params), as: UTF8.self) == json)
    }
}
