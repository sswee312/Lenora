import Foundation

struct LenoraBackendClient: GenerationProvider {
    static let maxTransientFailures = 5
    private static let defaultRetry = 2
    private static let retryRange = 1...30
    private static let requestTimeout: TimeInterval = 30
    private static let uploadTimeout: TimeInterval = 300

    let configuration: LenoraBackendConfiguration
    let transport: any HTTPTransport
    let sleep: @Sendable (Duration) async throws -> Void

    init(
        configuration: LenoraBackendConfiguration,
        transport: any HTTPTransport = URLSessionTransport(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.sleep = sleep
    }

    static func retryDelay(fromHeader header: String?) -> Duration {
        guard let header, let seconds = Int(header.trimmingCharacters(in: .whitespaces)) else {
            return .seconds(defaultRetry)
        }
        return .seconds(min(max(seconds, retryRange.lowerBound), retryRange.upperBound))
    }

    @concurrent
    func health(recheckAddons: Bool) async throws -> BackendHealth {
        let query = recheckAddons ? [URLQueryItem(name: "recheck", value: "addons")] : []
        return try await decode(BackendHealth.self, request("GET", "v1", "health", query: query)).0
    }

    @concurrent
    func capabilities() async throws -> BackendCapabilities {
        try await decode(BackendCapabilities.self, request("GET", "v1", "capabilities")).0
    }

    @concurrent
    func createUpload(model: String, contentType: String, byteCount: Int64, filename: String) async throws -> UploadTicket {
        struct Body: Encodable { let model, contentType: String; let byteCount: Int64; let filename: String }
        let body = Body(model: model, contentType: contentType, byteCount: byteCount, filename: filename)
        return try await decode(UploadTicket.self, request("POST", "v1", "uploads", body: body)).0
    }

    @concurrent
    func submit(_ job: JobRequest, idempotencyKey: String) async throws -> SubmittedJob {
        let submission = try request("POST", "v1", "jobs", body: job, headers: ["Idempotency-Key": idempotencyKey])
        return try await decode(SubmittedJob.self, submission).0
    }

    @concurrent
    func cancel(jobId: String) async throws -> JobState {
        try await decode(JobState.self, request("DELETE", "v1", "jobs", jobId)).0
    }

    @concurrent
    func deleteAsset(model: String, assetRef: String) async throws {
        let query = [URLQueryItem(name: "model", value: model)]
        _ = try await send(request("DELETE", "v1", "assets", trailingPath: assetRef, query: query))
    }

    @concurrent
    func upload(_ fileURL: URL, ticket: UploadTicket) async throws {
        var request = URLRequest(url: ticket.ticket.url, timeoutInterval: Self.uploadTimeout)
        request.httpMethod = ticket.ticket.method
        for (name, value) in ticket.ticket.headers { request.setValue(value, forHTTPHeaderField: name) }
        let bodyURL: URL
        let stagedBody: URL?
        if ticket.ticket.method == "POST", let fileField = ticket.ticket.fileField {
            let boundary = "lenora-\(UUID().uuidString)"
            bodyURL = try Self.writeMultipartBody(fields: ticket.ticket.fields, fileField: fileField, fileURL: fileURL, boundary: boundary)
            stagedBody = bodyURL
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        } else {
            bodyURL = fileURL
            stagedBody = nil
        }
        defer { if let stagedBody { try? FileManager.default.removeItem(at: stagedBody) } }
        let response: HTTPURLResponse
        do {
            response = try await transport.upload(for: request, fromFile: bodyURL).1
        } catch let error as URLError {
            throw transportFailure(error, otherwise: .uploadUnreachable)
        }
        guard (200..<300).contains(response.statusCode) else { throw BackendError.uploadFailed(status: response.statusCode) }
    }

    func jobUpdates(jobId: String) -> AsyncThrowingStream<JobState, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached { [self] in
                var failures = 0
                do {
                    while true {
                        try Task.checkCancellation()
                        do {
                            let (state, response) = try await decode(JobState.self, request("GET", "v1", "jobs", jobId))
                            failures = 0
                            continuation.yield(state)
                            if state.status.isTerminal { break }
                            try await sleep(Self.retryDelay(fromHeader: response.value(forHTTPHeaderField: "Retry-After")))
                        } catch let error as BackendError where error.isTransient && failures < Self.maxTransientFailures {
                            failures += 1
                            try await sleep(.seconds(min(1 << failures, Self.retryRange.upperBound)))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Plumbing

    // `trailingPath` keeps its slashes, for asset refs that are provider paths.
    private func request(
        _ method: String, _ path: String..., trailingPath: String? = nil, query: [URLQueryItem] = [],
        body: (any Encodable)? = nil, headers: [String: String] = [:]
    ) throws -> URLRequest {
        var url = path.reduce(configuration.baseURL) { $0.appending(component: $1) }
        if let trailingPath { url.append(path: trailingPath) }
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = configuration.token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.httpBody = try BackendCoding.encoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func transportFailure(_ error: URLError, otherwise failure: BackendError) -> any Error {
        error.code == .cancelled || Task.isCancelled ? CancellationError() : failure
    }

    private func decode<T: Decodable>(_ type: T.Type, _ request: URLRequest) async throws -> (T, HTTPURLResponse) {
        let (data, response) = try await send(request)
        do {
            return (try BackendCoding.decoder().decode(T.self, from: data), response)
        } catch is DecodingError {
            throw BackendError.invalidResponse(status: response.statusCode)
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as URLError {
            throw transportFailure(error, otherwise: .unreachable(configuration.baseURL))
        }
        switch response.statusCode {
        case 200..<300:
            return (data, response)
        case 401:
            throw BackendError.unauthorized
        default:
            if let problem = try? BackendCoding.decoder().decode(BackendProblem.self, from: data) {
                throw BackendError.problem(problem)
            }
            throw BackendError.invalidResponse(status: response.statusCode)
        }
    }

    private static func writeMultipartBody(fields: [String: String], fileField: String, fileURL: URL, boundary: String) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory.appending(path: "lenora-upload-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let out = try FileHandle(forWritingTo: bodyURL)
            defer { try? out.close() }
            func write(_ string: String) throws { try out.write(contentsOf: Data(string.utf8)) }
            for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
                try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
            }
            let filename = fileURL.lastPathComponent.replacingOccurrences(of: "\"", with: "%22")
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
            let input = try FileHandle(forReadingFrom: fileURL)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { try out.write(contentsOf: chunk) }
            try write("\r\n--\(boundary)--\r\n")
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }
        return bodyURL
    }
}
