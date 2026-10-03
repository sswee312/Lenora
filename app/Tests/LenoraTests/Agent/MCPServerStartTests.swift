import Darwin
import Foundation
import MCP
import Testing

@testable import Lenora

/// Holds a listening loopback socket so the port is genuinely taken.
private final class PortHolder {
    let port: UInt16
    private let descriptor: Int32

    init() throws {
        for _ in 0..<50 {
            let candidate = UInt16.random(in: 40_000...49_999)
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { continue }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = candidate.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bound == 0, listen(descriptor, 1) == 0 {
                self.descriptor = descriptor
                self.port = candidate
                return
            }
            close(descriptor)
        }
        throw POSIXError(.EADDRINUSE)
    }

    deinit { close(descriptor) }
}

private func makeServer(port: UInt16) -> MCPHTTPServer {
    MCPHTTPServer(port: port, token: "tok") {
        Server(name: "test", version: "1.0.0", capabilities: .init(tools: .init(listChanged: true)))
    }
}

struct MCPHTTPServerStartTests {
    @Test func startThrowsPortInUseWhenPortIsTaken() async throws {
        let holder = try PortHolder()
        let server = makeServer(port: holder.port)
        await #expect(throws: MCPHTTPServerError.portInUse(holder.port)) {
            try await server.start()
        }
        await server.stop()
    }

    @Test func startReturnsOnceListening() async throws {
        let server = makeServer(port: UInt16.random(in: 50_000...59_999))
        try await server.start()
        await server.stop()
    }
}

@MainActor
struct MCPServiceStartTests {
    @Test func portConflictLeavesServiceStoppedAndReportsFailure() async throws {
        let holder = try PortHolder()
        let port = holder.port
        let service = MCPService(projectProvider: { nil }, port: { port }, loadToken: { "tok" })
        await service.start()
        #expect(!service.isRunning)
        #expect(service.startFailure == .portInUse(port))
    }

    @Test func tokenFailureLeavesServiceStopped() async {
        let service = MCPService(
            projectProvider: { nil }, port: { 50_000 },
            loadToken: { throw MCPAccessTokenError.keychainReadFailed })
        await service.start()
        #expect(!service.isRunning)
        #expect(service.startFailure == .token)
    }

    @Test func successfulStartIsRunningAndStops() async {
        let port = UInt16.random(in: 50_000...59_999)
        let service = MCPService(projectProvider: { nil }, port: { port }, loadToken: { "tok" })
        await service.start()
        #expect(service.isRunning)
        #expect(service.startFailure == nil)
        await service.stop()
        #expect(!service.isRunning)
    }
}
