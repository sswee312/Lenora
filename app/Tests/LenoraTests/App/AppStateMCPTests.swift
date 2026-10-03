import Foundation
import Testing

@testable import Lenora

private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

@MainActor
struct AppStateMCPTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw EditorTestFixture.Timeout() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func startingAgainRetriesAFailedStart() async throws {
        try #require(MCPService.isEnabledPreference)
        let attempts = AttemptCounter()
        let port = UInt16.random(in: 50_000...59_999)
        let state = AppState(makeMCPService: { provider in
            MCPService(projectProvider: provider, port: { port }, loadToken: {
                if attempts.next() == 1 { throw MCPAccessTokenError.keychainReadFailed }
                return "tok"
            })
        })

        state.startMCPService()
        let service = try #require(state.mcpService)
        try await waitUntil { service.startFailure == .token }

        state.startMCPService()
        try await waitUntil { service.isRunning }
        #expect(state.mcpService === service)
        #expect(service.startFailure == nil)
        await service.stop()
    }
}
