import Foundation
@testable import Lenora

actor FakeProvider: GenerationProvider {
    var uploads: [String] = []
    var submitted: [(JobRequest, String)] = []
    var cancelResult: Result<JobState, BackendError> = .failure(.problem(BackendProblem(code: "not_cancellable", detail: nil, status: 409, retryable: false)))
    private var states: [JobState]
    private let failure: BackendError?
    private var stream: AsyncThrowingStream<JobState, Error>.Continuation?
    private(set) var pollers = 0

    init(states: [JobState], failure: BackendError? = nil) {
        self.states = states
        self.failure = failure
    }

    nonisolated func health() async throws -> BackendHealth { BackendHealth(status: "ok", protocolVersion: "1", backendVersion: "t", adapters: []) }
    nonisolated func capabilities() async throws -> BackendCapabilities { .empty }

    func createUpload(model: String, contentType: String, byteCount: Int64, filename: String) async throws -> UploadTicket {
        let json = #"{"assetRef":"ref-\#(filename)","ticket":{"method":"PUT","url":"https://u.example/x","headers":{},"fields":{},"fileField":null,"expiresAt":"2030-01-01T00:00:00Z"}}"#
        return try BackendCoding.decoder().decode(UploadTicket.self, from: Data(json.utf8))
    }

    func upload(_ fileURL: URL, ticket: UploadTicket) async throws { uploads.append(ticket.assetRef) }

    func submit(_ job: JobRequest, idempotencyKey: String) async throws -> SubmittedJob {
        submitted.append((job, idempotencyKey))
        return try BackendCoding.decoder().decode(SubmittedJob.self, from: Data(#"{"jobId":"fake:1","status":"queued"}"#.utf8))
    }

    nonisolated func jobUpdates(jobId: String) -> AsyncThrowingStream<JobState, Error> {
        AsyncThrowingStream { continuation in
            Task { await self.attach(continuation) }
        }
    }

    func cancel(jobId: String) async throws -> JobState { try cancelResult.get() }

    private func attach(_ continuation: AsyncThrowingStream<JobState, Error>.Continuation) {
        pollers += 1
        stream = continuation
        for state in states { continuation.yield(state) }
        if let failure { continuation.finish(throwing: failure) }
        else if states.last?.status.isTerminal == true { continuation.finish() }
    }

    func setCancelResult(_ result: Result<JobState, BackendError>) { cancelResult = result }
}

func jobState(_ status: JobStatus, results: [JobResult]? = nil) -> JobState {
    let resultsJSON = results.map { r in
        "[" + r.map { #"{"url":"\#($0.url.absoluteString)","contentType":"\#($0.contentType)","fileExtension":"\#($0.fileExtension)"}"# }.joined(separator: ",") + "]"
    } ?? "null"
    let json = #"{"jobId":"fake:1","status":"\#(status.rawValue)","results":\#(resultsJSON)}"#
    return try! BackendCoding.decoder().decode(JobState.self, from: Data(json.utf8))
}
