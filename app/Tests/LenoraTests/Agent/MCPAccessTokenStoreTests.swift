import Foundation
import Testing

@testable import Lenora

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _writes: [String] = []
    var writes: [String] { lock.withLock { _writes } }
    func record(_ value: String) { lock.withLock { _writes.append(value) } }
}

struct MCPAccessTokenStoreTests {
    @Test func missingItemCreatesAndSavesAToken() async throws {
        let recorder = Recorder()
        let store = MCPAccessTokenStore(read: { nil }, write: { recorder.record($0); return true })
        let token = try await store.loadOrCreate()
        #expect(token.count == 43)
        #expect(recorder.writes == [token])
    }

    @Test func existingTokenIsReturnedWithoutWriting() async throws {
        let recorder = Recorder()
        let store = MCPAccessTokenStore(read: { "kept" }, write: { recorder.record($0); return true })
        #expect(try await store.loadOrCreate() == "kept")
        #expect(recorder.writes.isEmpty)
    }

    @Test func readErrorSurfacesAndNeverOverwrites() async {
        let recorder = Recorder()
        let store = MCPAccessTokenStore(
            read: { throw KeychainReadError(status: errSecInteractionNotAllowed) },
            write: { recorder.record($0); return true })
        await #expect(throws: MCPAccessTokenError.keychainReadFailed) {
            try await store.loadOrCreate()
        }
        #expect(recorder.writes.isEmpty)
    }

    @Test func writeFailureSurfaces() async {
        let store = MCPAccessTokenStore(read: { nil }, write: { _ in false })
        await #expect(throws: MCPAccessTokenError.keychainWriteFailed) {
            try await store.loadOrCreate()
        }
    }

    @Test func regenerateReplacesTheToken() async throws {
        let recorder = Recorder()
        let store = MCPAccessTokenStore(read: { "old" }, write: { recorder.record($0); return true })
        let token = try await store.regenerate()
        #expect(token != "old")
        #expect(recorder.writes == [token])
    }
}
