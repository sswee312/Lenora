import Foundation
import Synchronization

/// Starts as an empty memory store; only app launch installs the login Keychain, so tests never reach it.
struct CredentialStore: Sendable {
    let read: @Sendable (_ account: String) throws -> String?
    let save: @Sendable (_ value: String, _ account: String) -> Bool
    let delete: @Sendable (_ account: String) -> Void
    let environment: [String: String]
    let isLoginKeychain: Bool

    static var current: CredentialStore { installed.withLock { $0 } }

    static func useLoginKeychain() {
        installed.withLock { $0 = .loginKeychain }
    }

    static func memory() -> CredentialStore {
        let vault = MemoryVault()
        return CredentialStore(
            read: { account in vault.values.withLock { $0[account] } },
            save: { value, account in vault.values.withLock { $0[account] = value }; return true },
            delete: { account in _ = vault.values.withLock { $0.removeValue(forKey: account) } },
            environment: [:],
            isLoginKeychain: false
        )
    }

    private static let loginKeychain = CredentialStore(
        read: { try KeychainStore.read(account: $0) },
        save: { KeychainStore.save($0, account: $1) },
        delete: { KeychainStore.delete(account: $0) },
        environment: ProcessInfo.processInfo.environment,
        isLoginKeychain: true
    )

    private static let installed = Mutex(memory())
}

private final class MemoryVault: Sendable {
    let values = Mutex<[String: String]>([:])
}
