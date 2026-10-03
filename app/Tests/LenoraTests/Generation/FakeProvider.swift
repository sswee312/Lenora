import Foundation
@testable import Lenora

actor FakeProvider: GenerationProvider {
    var uploads: [String] = []
    var submitted: [(JobRequest, String)] = []
    var cancelResult: Result<JobState, BackendError> = .failure(.problem(BackendProblem(code: "not_cancellable", detail: nil, status: 409, retryable: false)))
    private var states: [JobState]
    private var failure: BackendError?
    private var stream: AsyncThrowingStream<JobState, Error>.Continuation?
    private(set) var deletedAssets: [String] = []
    private var deleteResult: Result<Void, BackendError> = .success(())
    private(set) var pollers = 0
    private(set) var terminations = 0
    private let hangsOnSubmit: Bool
    private let hangsOnUpload: Bool
    private let uploadFailure: BackendError?
    private let submitError: BackendError?
    private let healthFailure: BackendError?
    private var capabilitiesResult: BackendCapabilities = .empty

    init(
        states: [JobState] = [], failure: BackendError? = nil, hangsOnSubmit: Bool = false, hangsOnUpload: Bool = false,
        uploadFailure: BackendError? = nil, submitError: BackendError? = nil, healthFailure: BackendError? = nil
    ) {
        self.states = states
        self.healthFailure = healthFailure
        self.submitError = submitError
        self.failure = failure
        self.hangsOnSubmit = hangsOnSubmit
        self.hangsOnUpload = hangsOnUpload
        self.uploadFailure = uploadFailure
    }

    func health(recheckAddons: Bool) async throws -> BackendHealth {
        if let healthFailure { throw healthFailure }
        return BackendHealth(status: "ok", protocolVersion: "1", backendVersion: "t", adapters: [])
    }

    func capabilities() async throws -> BackendCapabilities {
        await arrive(.capabilities)
        return capabilitiesResult
    }

    func setCapabilities(_ capabilities: BackendCapabilities) { capabilitiesResult = capabilities }

    func createUpload(model: String, contentType: String, byteCount: Int64, filename: String) async throws -> UploadTicket {
        await arrive(.createUpload)
        let json = #"{"assetRef":"ref-\#(filename)","ticket":{"method":"PUT","url":"https://u.example/x","headers":{},"fields":{},"fileField":null,"expiresAt":"2030-01-01T00:00:00Z"}}"#
        return try BackendCoding.decoder().decode(UploadTicket.self, from: Data(json.utf8))
    }

    func upload(_ fileURL: URL, ticket: UploadTicket) async throws {
        uploads.append(ticket.assetRef)
        await arrive(.upload)
        if let uploadFailure { throw uploadFailure }
        if hangsOnUpload { try await Task.sleep(for: .seconds(3600)) }
    }

    func submit(_ job: JobRequest, idempotencyKey: String) async throws -> SubmittedJob {
        submitted.append((job, idempotencyKey))
        if let submitError { throw submitError }
        if hangsOnSubmit { try await Task.sleep(for: .seconds(3600)) }
        return try BackendCoding.decoder().decode(SubmittedJob.self, from: Data(#"{"jobId":"fake:1","status":"queued","estimate":{"amount":0.05,"unit":"cloudinary_credits"}}"#.utf8))
    }

    nonisolated func jobUpdates(jobId: String) -> AsyncThrowingStream<JobState, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in Task { await self.noteTermination() } }
            Task { await self.attach(continuation) }
        }
    }

    func cancel(jobId: String) async throws -> JobState { try cancelResult.get() }

    func deleteAsset(model: String, assetRef: String) async throws {
        deletedAssets.append(assetRef)
        await arrive(.deleteAsset)
        try deleteResult.get()
    }

    func setDeleteResult(_ result: Result<Void, BackendError>) { deleteResult = result }

    func emit(_ state: JobState) { stream?.yield(state) }

    /// Later `jobUpdates` streams replay `states` and finish without failing.
    func recover(states: [JobState]) {
        self.states = states
        failure = nil
    }

    private var pollerWaiters: [CheckedContinuation<Void, Never>] = []

    enum Call: Hashable, Sendable { case createUpload, upload, deleteAsset, capabilities }

    private var heldCalls: Set<Call> = []
    private var parkedCalls: [Call: [CheckedContinuation<Void, Never>]] = [:]
    private var arrivals: [Call: Int] = [:]
    private var arrivalWaiters: [(call: Call, count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var cancelledCalls: Set<Call> = []
    private var cancellationWaiters: [(call: Call, continuation: CheckedContinuation<Void, Never>)] = []

    /// Parks every later `call` until `release(_:)`; parked calls ignore cancellation.
    func hold(_ call: Call) { heldCalls.insert(call) }

    func release(_ call: Call) {
        heldCalls.remove(call)
        parkedCalls.removeValue(forKey: call)?.forEach { $0.resume() }
    }

    /// Returns once `call` has been made `count` times, or when the waiting test is cancelled.
    func waitForCalls(_ call: Call, count: Int = 1) async {
        if arrivals[call, default: 0] >= count { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { arrivalWaiters.append((call, count, $0)) }
        } onCancel: {
            Task { await self.resumeArrivalWaiters() }
        }
    }

    private func resumeArrivalWaiters() {
        arrivalWaiters.forEach { $0.continuation.resume() }
        arrivalWaiters.removeAll()
    }

    private func arrive(_ call: Call) async {
        arrivals[call, default: 0] += 1
        let total = arrivals[call, default: 0]
        arrivalWaiters.filter { $0.call == call && $0.count <= total }.forEach { $0.continuation.resume() }
        arrivalWaiters.removeAll { $0.call == call && $0.count <= total }
        guard heldCalls.contains(call) else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { parkedCalls[call, default: []].append($0) }
        } onCancel: {
            Task { await self.noteCancelled(call) }
        }
    }

    /// Returns once a parked `call` has been cancelled by its caller.
    func waitForCancellation(_ call: Call) async {
        if cancelledCalls.contains(call) { return }
        await withCheckedContinuation { cancellationWaiters.append((call, $0)) }
    }

    private func noteCancelled(_ call: Call) {
        cancelledCalls.insert(call)
        cancellationWaiters.filter { $0.call == call }.forEach { $0.continuation.resume() }
        cancellationWaiters.removeAll { $0.call == call }
    }

    /// Returns once a consumer has attached to `jobUpdates`.
    func waitForPoller() async {
        if pollers > 0 { return }
        await withCheckedContinuation { pollerWaiters.append($0) }
    }

    private func noteTermination() { terminations += 1 }

    private func attach(_ continuation: AsyncThrowingStream<JobState, Error>.Continuation) {
        pollers += 1
        stream = continuation
        for state in states { continuation.yield(state) }
        if let failure { continuation.finish(throwing: failure) }
        else if states.last?.status.isTerminal == true { continuation.finish() }
        pollerWaiters.forEach { $0.resume() }
        pollerWaiters.removeAll()
    }

    func setCancelResult(_ result: Result<JobState, BackendError>) { cancelResult = result }
}

func jobState(_ status: JobStatus, results: [JobResult]? = nil, error: JobFailure? = nil) -> JobState {
    let resultsJSON = results.map { r in
        "[" + r.map { #"{"url":"\#($0.url.absoluteString)","contentType":"\#($0.contentType)","fileExtension":"\#($0.fileExtension)"}"# }.joined(separator: ",") + "]"
    } ?? "null"
    let errorJSON = error.map { #"{"code":"\#($0.code)","message":"\#($0.message)","retryable":\#($0.retryable)}"# } ?? "null"
    let json = #"{"jobId":"fake:1","status":"\#(status.rawValue)","results":\#(resultsJSON),"error":\#(errorJSON)}"#
    return try! BackendCoding.decoder().decode(JobState.self, from: Data(json.utf8))
}
