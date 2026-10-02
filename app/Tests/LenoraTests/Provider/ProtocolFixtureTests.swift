import Foundation
import Testing
@testable import Lenora

struct ProtocolFixtureTests {
    private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try BackendCoding.decoder().decode(T.self, from: ProtocolFixtures.data(name))
    }

    @Test func decodesCapabilities() throws {
        let caps = try decode(BackendCapabilities.self, "Capabilities.cloudinary")
        let model = try #require(caps.models.first)
        #expect(model.id == "cloudinary/background-removal")
        #expect(model.kind == "image.removeBackground")
        #expect(model.inputs.maxBytes == 10_485_760)
        #expect(model.estimate == BackendEstimate(amount: 0.075, unit: "cloudinary_credits"))
        #expect(!model.cancellable)
    }

    @Test func decodesBothHealthShapes() throws {
        #expect(try decode(BackendHealth.self, "Health.public").adapters == nil)
        let full = try decode(BackendHealth.self, "Health.authorized")
        #expect(full.adapters?.map(\.enabled) == [true, false])
        #expect(full.adapters?.last?.reason == "missing or invalid: LENORA_OPENAI_API_KEY")
    }

    @Test func decodesUploadTicket() throws {
        let ticket = try decode(UploadTicket.self, "UploadTicket.cloudinary")
        #expect(ticket.ticket.method == "POST")
        #expect(ticket.ticket.fileField == "file")
        #expect(ticket.ticket.fields["public_id"]?.hasPrefix("lenora/") == true)
    }

    @Test(arguments: ["JobState.running", "JobState.succeeded", "JobState.failed"])
    func decodesJobStates(name: String) throws {
        let state = try decode(JobState.self, name)
        #expect(state.jobId.hasPrefix("cloudinary:"))
        #expect(state.status.isTerminal == (name != "JobState.running"))
    }

    @Test func succeededStateNamesItsExtension() throws {
        let state = try decode(JobState.self, "JobState.succeeded")
        #expect(state.results?.first?.fileExtension == "png")
    }

    @Test func decodesProblem() throws {
        let problem = try decode(BackendProblem.self, "Problem.not_cancellable")
        #expect(problem == BackendProblem(code: "not_cancellable", detail: problem.detail, status: 409, retryable: false))
    }

    @Test func encodesJobRequestLikeTheFixture() throws {
        let request = JobRequest(
            kind: "image.removeBackground",
            model: "cloudinary/background-removal",
            inputs: [.assetRef("image/upload/lenora/6f1c2b9e-3d4a-4f5b-8c7d-9e0f1a2b3c4d")],
            params: EmptyParams()
        )
        let encoded = try JSONSerialization.jsonObject(with: BackendCoding.encoder().encode(request)) as? NSDictionary
        let fixture = try JSONSerialization.jsonObject(with: ProtocolFixtures.data("JobRequest.removeBackground")) as? NSDictionary
        #expect(encoded == fixture)
    }

    @Test func ignoresUnknownFields() throws {
        let json = #"{"jobId":"a:b","status":"running","future":{"x":1}}"#
        #expect(try BackendCoding.decoder().decode(JobState.self, from: Data(json.utf8)).status == .running)
    }
}
