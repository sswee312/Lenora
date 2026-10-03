import Foundation
import MCP
import Network
import os

/// HTTP server for MCP. Each client session gets its own `Server` + stateful transport
actor MCPHTTPServer {

    private let port: UInt16
    private let token: String
    private let makeServer: @Sendable () async -> Server
    private nonisolated(unsafe) var listener: NWListener?

    private struct Session {
        let server: Server
        let transport: StatefulHTTPServerTransport
        var lastUsed: ContinuousClock.Instant
        var toolListAnnounced = false
    }

    private var sessions: [String: Session] = [:]
    private var fallback: (server: Server, transport: StatelessHTTPServerTransport)?
    private static let sessionIdleLimit: Duration = .seconds(3600)
    private static let sessionCountLimit = 32

    init(
        port: UInt16,
        token: String,
        makeServer: @escaping @Sendable () async -> Server
    ) {
        self.port = port
        self.token = token
        self.makeServer = makeServer
    }

    func start() async throws {
        Log.mcp.info("listener start port=\(self.port)")
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            Log.mcp.fault("invalid port \(self.port)")
            throw MCPHTTPServerError.invalidPort(port)
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind to IPv4 loopback only so the server is never reachable from the LAN.
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        let listener = try NWListener(using: params)

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: .global(qos: .userInitiated))
            Task { await self.receive(on: connection) }
        }

        self.listener = listener
        do {
            try await Self.waitUntilReady(listener, port: port)
        } catch {
            listener.cancel()
            if self.listener === listener { self.listener = nil }
            throw error
        }
    }

    // Resolves on the first terminal state, so a bind failure is never silent.
    private static func waitUntilReady(_ listener: NWListener, port: UInt16) async throws {
        let settled = OSAllocatedUnfairLock(initialState: false)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                listener.stateUpdateHandler = { state in
                    let outcome: Result<Void, Error>
                    switch state {
                    case .ready:
                        outcome = .success(())
                    case .failed(let error):
                        outcome = .failure(MCPHTTPServerError(listenerError: error, port: port))
                    case .cancelled:
                        outcome = .failure(CancellationError())
                    default:
                        return
                    }
                    guard settled.withLock({ let first = !$0; $0 = true; return first }) else {
                        if case .failed(let error) = state { Log.mcp.error("listener failed: \(error.localizedDescription)") }
                        return
                    }
                    continuation.resume(with: outcome)
                }
                listener.start(queue: .global(qos: .userInitiated))
            }
        } onCancel: {
            listener.cancel()
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let closing = sessions.values.map(\.transport)
        sessions.removeAll()
        let fallbackTransport = fallback?.transport
        fallback = nil
        Task {
            for transport in closing { await transport.disconnect() }
            await fallbackTransport?.disconnect()
        }
    }

    // MARK: - Connection

    private func receive(on connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, _, error in
            guard let self, let data, !data.isEmpty, error == nil else {
                connection.cancel(); return
            }
            var buffer = buffer
            buffer.append(data)
            Task { await self.process(buffer: buffer, connection: connection) }
        }
    }

    // A request body can span multiple TCP reads; accumulate until Content-Length is satisfied.
    private func process(buffer: Data, connection: NWConnection) async {
        switch framing(of: buffer) {
        case .needMoreData:
            receive(on: connection, buffer: buffer)
        case .invalid:
            sendRaw("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n", on: connection, keepAlive: false)
        case .complete:
            guard let request = parseHTTPRequest(buffer) else {
                sendRaw("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n", on: connection, keepAlive: false)
                return
            }
            await handle(request: request, connection: connection)
        }
    }

    private enum Framing { case needMoreData, complete, invalid }

    private nonisolated func framing(of data: Data) -> Framing {
        guard data.count <= 16_777_216 else { return .invalid }
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 65_536 ? .invalid : .needMoreData
        }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid
        }
        let contentLength = head.components(separatedBy: "\r\n").dropFirst().compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        let bodyBytes = data.distance(from: headerEnd.upperBound, to: data.endIndex)
        return bodyBytes >= contentLength ? .complete : .needMoreData
    }

    // MARK: - Routing

    private func handle(request: HTTPRequest, connection: NWConnection) async {
        if request.path == "/.well-known/oauth-protected-resource" {
            let body = "{\"resource\":\"http://127.0.0.1:\(port)\"}"
            sendRaw("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)", on: connection, keepAlive: true)
            receive(on: connection)
            return
        }

        guard request.path == "/mcp" || request.path == "/" else {
            sendRaw("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n", on: connection, keepAlive: false)
            return
        }

        guard MCPAccessToken.isAuthorized(header: request.header("Authorization"), token: token) else {
            Log.mcp.debug("rejected request without a valid bearer token")
            sendRaw("HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                    on: connection, keepAlive: false)
            return
        }

        let response: HTTPResponse
        if let claimed = request.header(HTTPHeaderName.sessionID) {
            guard var session = sessions[claimed] else {
                // Unknown/expired session → 404 per spec; the client re-initializes
                // and refreshes its tool inventory.
                sendRaw("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n", on: connection, keepAlive: true)
                receive(on: connection)
                return
            }
            session.lastUsed = .now
            sessions[claimed] = session
            response = await session.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE", response.statusCode == 200 {
                sessions.removeValue(forKey: claimed)
            } else if request.method.uppercased() == "GET", response.statusCode == 200 {
                announceToolList(sessionID: claimed)
            }
        } else if isInitialize(request) {
            let transport = StatefulHTTPServerTransport(
                validationPipeline: StandardValidationPipeline(validators: baseValidators() + [SessionValidator()])
            )
            let server = await makeServer()
            try? await server.start(transport: transport)
            response = await transport.handleRequest(request)
            if let assigned = response.headers[HTTPHeaderName.sessionID] {
                pruneIdleSessions()
                sessions[assigned] = Session(server: server, transport: transport, lastUsed: .now)
                Log.mcp.notice("session started id=\(assigned) total=\(self.sessions.count)")
            } else {
                await transport.disconnect()
            }
        } else {
            // Sessionless clients (and plain curl) get simple request/response semantics.
            response = await fallbackPair().transport.handleRequest(request)
        }
        writeResponse(response, on: connection)
    }

    private func announceToolList(sessionID: String) {
        guard var session = sessions[sessionID], !session.toolListAnnounced else { return }
        session.toolListAnnounced = true
        sessions[sessionID] = session
        let server = session.server
        Task {
            do {
                try await server.notify(ToolListChangedNotification.message())
            } catch {
                Log.mcp.warning("tool list_changed notify failed id=\(sessionID): \(error.localizedDescription)")
                await self.resetToolListAnnouncement(sessionID: sessionID)
            }
        }
    }

    func broadcastToolListChanged() {
        for (id, session) in sessions {
            let server = session.server
            Task {
                do {
                    try await server.notify(ToolListChangedNotification.message())
                } catch {
                    Log.mcp.warning("tool list_changed broadcast failed id=\(id): \(error.localizedDescription)")
                }
            }
        }
    }

    // A failed announce retries on the next GET-stream attach.
    private func resetToolListAnnouncement(sessionID: String) {
        guard var session = sessions[sessionID] else { return }
        session.toolListAnnounced = false
        sessions[sessionID] = session
    }

    private nonisolated func isInitialize(_ request: HTTPRequest) -> Bool {
        guard request.method.uppercased() == "POST", let body = request.body,
              let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return false }
        return json["method"] as? String == "initialize"
    }

    private nonisolated func baseValidators() -> [any HTTPRequestValidator] {
        [OriginValidator.localhost(port: Int(port)), ContentTypeValidator(), ProtocolVersionValidator()]
    }

    private func fallbackPair() async -> (server: Server, transport: StatelessHTTPServerTransport) {
        if let fallback { return fallback }
        let pipeline = StandardValidationPipeline(validators: baseValidators())
        let pair = (server: await makeServer(), transport: StatelessHTTPServerTransport(validationPipeline: pipeline))
        try? await pair.server.start(transport: pair.transport)
        fallback = pair
        return pair
    }

    // Evicted clients recover transparently: their next request gets 404 and they re-initialize.
    private func pruneIdleSessions() {
        let cutoff = ContinuousClock.now - Self.sessionIdleLimit
        for (id, session) in sessions where session.lastUsed < cutoff {
            evictSession(id: id)
        }
        while sessions.count >= Self.sessionCountLimit,
              let oldest = sessions.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            evictSession(id: oldest.key)
        }
    }

    private func evictSession(id: String) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        Log.mcp.notice("session evicted id=\(id)")
        Task { await session.transport.disconnect() }
    }

    // MARK: - Response writing

    private func writeResponse(_ response: HTTPResponse, on connection: NWConnection) {
        if case .stream(let stream, let headers) = response {
            // SSE has no Content-Length; close the connection to delimit the body.
            var head = "HTTP/1.1 200 OK\r\n"
            for (k, v) in headers where k.lowercased() != "connection" { head += "\(k): \(v)\r\n" }
            head += "Connection: close\r\n\r\n"
            connection.send(content: head.data(using: .utf8), completion: .contentProcessed { _ in })
            Task {
                do {
                    for try await chunk in stream {
                        connection.send(content: chunk, completion: .contentProcessed { _ in })
                    }
                } catch {}
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
            return
        }

        var head = "HTTP/1.1 \(response.statusCode) \(statusText(response.statusCode))\r\n"
        for (k, v) in response.headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(response.bodyData?.count ?? 0)\r\nConnection: keep-alive\r\n\r\n"

        var responseData = head.data(using: .utf8)!
        if let bodyData = response.bodyData { responseData.append(bodyData) }

        connection.send(content: responseData, completion: .contentProcessed { _ in })
        receive(on: connection)
    }

    // MARK: - HTTP Parsing

    private nonisolated func parseHTTPRequest(_ data: Data) -> HTTPRequest? {
        guard let string = String(data: data, encoding: .utf8) else { return nil }
        let parts = string.components(separatedBy: "\r\n\r\n")
        guard let headerSection = parts.first else { return nil }
        let lines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let tokens = requestLine.split(separator: " ", maxSplits: 2)
        guard tokens.count >= 2 else { return nil }

        let method = String(tokens[0])
        let rawPath = String(tokens[1])
        let path = rawPath.split(separator: "?").first.map(String.init) ?? rawPath

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyString = parts.dropFirst().joined(separator: "\r\n\r\n")
        let body = bodyString.isEmpty ? nil : bodyString.data(using: .utf8)
        return HTTPRequest(method: method, headers: headers, body: body, path: path)
    }

    private nonisolated func sendRaw(_ string: String, on connection: NWConnection, keepAlive: Bool) {
        connection.send(content: string.data(using: .utf8), completion: .contentProcessed { _ in
            if !keepAlive { connection.cancel() }
        })
    }

    private nonisolated func statusText(_ code: Int) -> String {
        switch code {
        case 200: "OK"; case 202: "Accepted"; case 400: "Bad Request"; case 401: "Unauthorized"
        case 404: "Not Found"; case 405: "Method Not Allowed"; case 409: "Conflict"
        case 500: "Internal Server Error"
        default: "Unknown"
        }
    }
}

enum MCPHTTPServerError: LocalizedError, Equatable {
    case invalidPort(UInt16)
    case portInUse(UInt16)
    case listenerFailed(String)

    init(listenerError: NWError, port: UInt16) {
        if case .posix(.EADDRINUSE) = listenerError {
            self = .portInUse(port)
        } else {
            self = .listenerFailed(listenerError.localizedDescription)
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port): "invalid port \(port)"
        case .portInUse(let port): "port \(port) is already in use"
        case .listenerFailed(let detail): "listener failed: \(detail)"
        }
    }
}
