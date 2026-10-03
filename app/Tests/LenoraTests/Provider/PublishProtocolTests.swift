import Foundation
import Testing
@testable import Lenora

struct PublishProtocolTests {
    @Test func partialPublishStateDecodesRolesAndFailedOutputs() throws {
        let state = try BackendCoding.decoder().decode(JobState.self, from: ProtocolFixtures.data("JobState.publishPartial"))
        #expect(state.results?.map(\.role) == ["stream", "download", "poster", "vertical"])
        #expect(state.failedOutputs == [FailedOutput(role: "teaser", code: "provider_error", message: "Timed out after 15 minutes.")])
    }

    @Test func publishModelIsDeletable() throws {
        let caps = try BackendCoding.decoder().decode(BackendCapabilities.self, from: ProtocolFixtures.data("Capabilities.cloudinaryFull"))
        let model = try #require(caps.models.first { $0.kind == "video.publish" })
        #expect(model.deletable == true)
        #expect(caps.models.filter { $0.kind != "video.publish" }.allSatisfy { $0.deletable != true })
    }

    @Test func publishParamsEncodeLikeTheFixture() throws {
        let params = VideoPublishParams(outputs: .init(vertical: "9:16", teaserSeconds: 15))
        let request = JobRequest(kind: "video.publish", model: "cloudinary/publish",
                                 inputs: [.assetRef("video/upload/lenora/6f1c2b9e-3d4a-4f5b-8c7d-9e0f1a2b3c4d")], params: params)
        let encoded = try JSONSerialization.jsonObject(with: BackendCoding.encoder().encode(request)) as? NSDictionary
        let fixture = try JSONSerialization.jsonObject(with: ProtocolFixtures.data("JobRequest.videoPublish")) as? NSDictionary
        #expect(encoded == fixture)
    }

    @Test func emptyOutputsEncodeAsAnEmptyObject() throws {
        let data = try BackendCoding.encoder().encode(VideoPublishParams(outputs: .init()))
        #expect(String(decoding: data, as: UTF8.self) == #"{"outputs":{}}"#)
    }
}
