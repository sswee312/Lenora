import Testing
@testable import Lenora

struct CredentialStoreTests {
    @Test func testProcessNeverUsesTheLoginKeychain() {
        #expect(!CredentialStore.current.isLoginKeychain)
    }

    @Test func memoryStoreSavesReadsAndDeletes() throws {
        let store = CredentialStore.memory()
        #expect(store.save("secret", "account"))
        #expect(try store.read("account") == "secret")
        store.delete("account")
        #expect(try store.read("account") == nil)
    }

    @Test func agentKeysIgnoreTheProcessEnvironmentUnderTests() async {
        for provider in AgentProvider.allCases {
            #expect(await provider.loadAPIKey().isEmpty)
        }
    }
}
