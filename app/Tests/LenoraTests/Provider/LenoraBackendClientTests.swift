import Foundation
import Testing
@testable import Lenora

struct LenoraBackendClientTests {
    private let config = LenoraBackendConfiguration(baseURL: URL(string: "http://127.0.0.1:8787")!, token: "tok")

    private func client(_ transport: StubTransport, sleeps: SleepLog = SleepLog()) -> LenoraBackendClient {
        LenoraBackendClient(configuration: config, transport: transport, sleep: { await sleeps.record($0) })
    }

    private func state(_ status: String) -> StubTransport.Reply {
        .init(status: 200, body: #"{"jobId":"cloudinary:x","status":"\#(status)"}"#, headers: ["Retry-After": "7"])
    }

    @Test func recheckAddsTheQuery() async throws {
        let transport = StubTransport([.success(.init(status: 200, body: #"{"status":"ok","protocolVersion":"1"}"#))])
        _ = try await client(transport).health(recheckAddons: true)
        #expect(await transport.requests.first?.url?.query == "recheck=addons")
    }

    @Test func sendsBearerToken() async throws {
        let transport = StubTransport([.success(.init(status: 200, body: #"{"protocolVersion":"1","adapters":[],"models":[]}"#))])
        _ = try await client(transport).capabilities()
        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.url?.absoluteString == "http://127.0.0.1:8787/v1/capabilities")
    }

    @Test func decodesProblemJSON() async {
        let body = #"{"type":"urn:lenora:problem:unknown_model","title":"unknown_model","status":422,"detail":"x","code":"unknown_model","retryable":false}"#
        let transport = StubTransport([.success(.init(status: 422, body: body, headers: ["Content-Type": "application/problem+json"]))])
        await #expect(throws: BackendError.problem(BackendProblem(code: "unknown_model", detail: "x", status: 422, retryable: false))) {
            try await client(transport).capabilities()
        }
    }

    @Test func test401IsNotRetried() async {
        let transport = StubTransport([.success(.init(status: 401)), .success(state("running"))])
        let stream = client(transport).jobUpdates(jobId: "cloudinary:x")
        await #expect(throws: BackendError.unauthorized) { for try await _ in stream {} }
        #expect(await transport.requests.count == 1)
    }

    @Test func pollsUntilTerminalHonoringRetryAfter() async throws {
        let sleeps = SleepLog()
        let transport = StubTransport([.success(state("running")), .success(state("succeeded"))])
        var statuses: [JobStatus] = []
        for try await update in client(transport, sleeps: sleeps).jobUpdates(jobId: "cloudinary:x") {
            statuses.append(update.status)
        }
        #expect(statuses == [.running, .succeeded])
        #expect(await sleeps.durations == [.seconds(7)])
    }

    @Test(arguments: [(nil, 2), ("0", 1), ("999", 30), ("abc", 2), ("5", 5)] as [(String?, Int)])
    func clampsRetryAfter(header: String?, seconds: Int) {
        #expect(LenoraBackendClient.retryDelay(fromHeader: header) == .seconds(seconds))
    }

    @Test func retriesTransientFailuresThenRecovers() async throws {
        let transport = StubTransport([.failure(URLError(.timedOut)), .success(.init(status: 503, body: "{}")), .success(state("succeeded"))])
        var last: JobState?
        for try await update in client(transport).jobUpdates(jobId: "cloudinary:x") { last = update }
        #expect(last?.status == .succeeded)
    }

    @Test func givesUpAfterMaxTransientFailures() async {
        let failures = Array(repeating: Result<StubTransport.Reply, URLError>.failure(URLError(.cannotConnectToHost)),
                             count: LenoraBackendClient.maxTransientFailures + 1)
        let transport = StubTransport(failures)
        await #expect(throws: BackendError.self) { for try await _ in client(transport).jobUpdates(jobId: "cloudinary:x") {} }
        #expect(await transport.requests.count == LenoraBackendClient.maxTransientFailures + 1)
    }

    @Test(.timeLimit(.minutes(1))) func cancellingTheConsumerStopsPolling() async throws {
        let transport = StubTransport(Array(repeating: .success(state("running")), count: 50))
        let (sleeping, sleepStarted) = AsyncStream<Void>.makeStream()
        let blocking = LenoraBackendClient(configuration: config, transport: transport, sleep: { _ in
            sleepStarted.yield()
            try await Task.sleep(for: .seconds(3600))
        })
        let consumer = Task { for try await _ in blocking.jobUpdates(jobId: "cloudinary:x") {} }
        for await _ in sleeping { break }
        consumer.cancel()
        _ = await consumer.result
        #expect(await transport.requests.count == 1)
    }

    @Test func cancelledTransportIsCancellationNotUnreachable() async {
        let transport = StubTransport([.failure(URLError(.cancelled))])
        await #expect(throws: CancellationError.self) { try await client(transport).capabilities() }
    }

    @Test func jobIdIsASinglePathComponent() async throws {
        let transport = StubTransport([.success(state("cancelled"))])
        _ = try await client(transport).cancel(jobId: "cloudinary:a/b?c")
        #expect(await transport.requests.first?.url?.absoluteString == "http://127.0.0.1:8787/v1/jobs/cloudinary:a%2Fb%3Fc")
    }

    @Test(arguments: ["2030-01-01T00:00:00Z", "2030-01-01T00:00:00.123456Z", "2030-01-01T05:30:00.5+05:30"])
    func decodesBackendDates(_ text: String) throws {
        struct Stamp: Decodable { let at: Date }
        let stamp = try BackendCoding.decoder().decode(Stamp.self, from: Data(#"{"at":"\#(text)"}"#.utf8))
        #expect(abs(stamp.at.timeIntervalSince1970 - 1_893_456_000) < 1)
    }

    @Test func uploadFileRefusesAFileWithoutASize() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = StubTransport([])
        await #expect(throws: CocoaError.self) {
            try await client(transport).uploadFile(directory, contentType: "image/png", model: "cloudinary/background-removal")
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func multipartUploadSendsFieldsThenFile() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
        try Data("PNGDATA".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let ticket = try BackendCoding.decoder().decode(UploadTicket.self, from: ProtocolFixtures.data("UploadTicket.cloudinary"))
        let transport = StubTransport([.success(.init(status: 200))])
        try await client(transport).upload(file, ticket: ticket)
        let request = try #require(await transport.requests.first)
        let body = String(decoding: try #require(await transport.uploadedFiles.first), as: UTF8.self)
        #expect(request.url == ticket.ticket.url)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        #expect(body.contains(#"name="public_id""#) && body.contains("PNGDATA"))
        #expect(body.range(of: #"name="file""#)!.lowerBound > body.range(of: #"name="signature""#)!.lowerBound)
    }

    @Test func failedUploadThrows() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let ticket = try BackendCoding.decoder().decode(UploadTicket.self, from: ProtocolFixtures.data("UploadTicket.cloudinary"))
        await #expect(throws: BackendError.uploadFailed(status: 400)) {
            try await client(StubTransport([.success(.init(status: 400))])).upload(file, ticket: ticket)
        }
    }

    @Test func submitSendsIdempotencyKey() async throws {
        let transport = StubTransport([.success(.init(status: 202, body: #"{"jobId":"cloudinary:x","status":"queued"}"#))])
        let job = JobRequest(kind: "image.removeBackground", model: "cloudinary/background-removal", inputs: [.assetRef("a")], params: EmptyParams())
        _ = try await client(transport).submit(job, idempotencyKey: "key-1")
        #expect(await transport.requests.first?.value(forHTTPHeaderField: "Idempotency-Key") == "key-1")
    }
}

actor SleepLog {
    private(set) var durations: [Duration] = []
    func record(_ duration: Duration) { durations.append(duration) }
}
