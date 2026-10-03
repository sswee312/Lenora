import Foundation
import MCP
import Testing

@testable import Lenora

struct MCPHTTPServerAuthTests {
    private static let token = "tok"

    private func withServer(_ body: (URL) async throws -> Void) async throws {
        let port = UInt16.random(in: 40_000...49_999)
        let server = MCPHTTPServer(port: port, token: Self.token) {
            let server = Server(name: "test", version: "1.0.0", capabilities: .init(tools: .init(listChanged: true)))
            await server.withMethodHandler(ListTools.self) { _ in .init(tools: []) }
            return server
        }
        try await server.start()
        do {
            try await body(URL(string: "http://127.0.0.1:\(port)/mcp")!)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    private func initialize(_ url: URL, authorization: String?) async throws -> HTTPURLResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        request.httpBody = Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#
                .utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        return try #require(response as? HTTPURLResponse)
    }

    @Test func rejectsRequestWithoutAuthorization() async throws {
        try await withServer { url in
            let response = try await initialize(url, authorization: nil)
            #expect(response.statusCode == 401)
            #expect(response.value(forHTTPHeaderField: "WWW-Authenticate") == "Bearer")
        }
    }

    @Test func rejectsWrongToken() async throws {
        try await withServer { url in
            let response = try await initialize(url, authorization: "Bearer nope")
            #expect(response.statusCode == 401)
        }
    }

    @Test func acceptsCorrectToken() async throws {
        try await withServer { url in
            let response = try await initialize(url, authorization: "Bearer \(Self.token)")
            #expect(response.statusCode == 200)
        }
    }
}
