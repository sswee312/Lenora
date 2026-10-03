import Foundation
import MCP

/// A job request persisted before submit so a resume can re-send it under the same idempotency key.
struct PendingSubmission: Codable, Sendable, Equatable {
    let kind: String
    let model: String
    let inputs: [JobInput]
    let params: Value

    init(_ job: JobRequest) throws {
        kind = job.kind
        model = job.model
        inputs = job.inputs
        params = try BackendCoding.decoder().decode(Value.self, from: BackendCoding.encoder().encode(job.params))
    }

    var request: JobRequest {
        JobRequest(kind: kind, model: model, inputs: inputs, params: params)
    }
}

extension GenerationInput {
    var canResubmit: Bool {
        submission != nil && idempotencyKey != nil && (jobId ?? "").isEmpty
    }
}
