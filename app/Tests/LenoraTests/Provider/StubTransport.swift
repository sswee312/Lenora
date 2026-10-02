import Foundation
@testable import Lenora

actor StubTransport: HTTPTransport {
    struct Reply: Sendable {
        var status: Int
        var body: String = "{}"
        var headers: [String: String] = ["Content-Type": "application/json"]
    }

    private var queue: [Result<Reply, URLError>]
    private(set) var requests: [URLRequest] = []
    private(set) var uploadedFiles: [Data] = []

    init(_ replies: [Result<Reply, URLError>]) { queue = replies }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return try next(for: request)
    }

    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        uploadedFiles.append(try Data(contentsOf: fileURL))
        return try next(for: request)
    }

    private func next(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        guard !queue.isEmpty else { throw URLError(.cannotConnectToHost) }
        let reply = try queue.removeFirst().get()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (Data(reply.body.utf8), response)
    }
}
