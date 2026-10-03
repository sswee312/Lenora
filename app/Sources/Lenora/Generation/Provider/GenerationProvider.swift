import Foundation

protocol GenerationProvider: Sendable {
    func health(recheckAddons: Bool) async throws -> BackendHealth
    func capabilities() async throws -> BackendCapabilities
    func createUpload(model: String, contentType: String, byteCount: Int64, filename: String) async throws -> UploadTicket
    func upload(_ fileURL: URL, ticket: UploadTicket) async throws
    func submit(_ job: JobRequest, idempotencyKey: String) async throws -> SubmittedJob
    func jobUpdates(jobId: String) -> AsyncThrowingStream<JobState, Error>
    func cancel(jobId: String) async throws -> JobState
}

extension GenerationProvider {
    /// Requests a ticket, uploads the file directly to the provider, and returns the asset ref.
    @concurrent
    func uploadFile(_ fileURL: URL, contentType: String, model: String) async throws -> String {
        guard let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: fileURL])
        }
        let ticket = try await createUpload(
            model: model, contentType: contentType, byteCount: Int64(size), filename: fileURL.lastPathComponent
        )
        try await upload(fileURL, ticket: ticket)
        return ticket.assetRef
    }
}

enum BackendError: Error, Sendable, Equatable, LocalizedError {
    case unreachable(URL)
    case unauthorized
    case problem(BackendProblem)
    case invalidResponse(status: Int)
    case uploadFailed(status: Int)
    case uploadUnreachable

    var isTransient: Bool {
        switch self {
        case .unreachable: true
        case .problem(let problem): problem.retryable
        case .invalidResponse(let status): status >= 500
        case .unauthorized, .uploadFailed, .uploadUnreachable: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .unreachable(let url):
            "Can't reach the backend at \(url.absoluteString)."
        case .unauthorized:
            "The backend rejected the token."
        case .problem(let problem):
            problem.detail ?? problem.code
        case .invalidResponse(let status):
            "The backend returned an unexpected response (HTTP \(status))."
        case .uploadUnreachable:
            "Couldn't reach the provider to upload the file."
        case .uploadFailed(let status):
            "The upload to the provider failed (HTTP \(status))."
        }
    }
}
