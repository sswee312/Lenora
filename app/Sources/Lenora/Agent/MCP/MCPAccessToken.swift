import Foundation
import Security

enum MCPAccessToken {
    static let account = "mcp.token"

    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func isAuthorized(header: String?, token: String) -> Bool {
        guard let header, header.count > 7, header.prefix(7).lowercased() == "bearer " else { return false }
        return constantTimeEquals(Array(header.dropFirst(7).utf8), Array(token.utf8))
    }

    private static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var difference: UInt8 = a.count == b.count ? 0 : 1
        for i in 0..<max(a.count, b.count) {
            difference |= (i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0)
        }
        return difference == 0
    }

    @concurrent static func loadOrCreate() async throws -> String {
        try await storage.loadOrCreate()
    }

    @concurrent static func regenerate() async throws -> String {
        try await storage.regenerate()
    }

    private static let storage = Storage()

    // One actor serializes Keychain access so concurrent callers never mint two tokens.
    private actor Storage {
        func loadOrCreate() throws -> String {
            if let existing = KeychainStore.load(account: MCPAccessToken.account) { return existing }
            return try regenerate()
        }

        func regenerate() throws -> String {
            let token = MCPAccessToken.generate()
            guard KeychainStore.save(token, account: MCPAccessToken.account) else {
                throw MCPAccessTokenError.keychainWriteFailed
            }
            return token
        }
    }
}

enum MCPAccessTokenError: LocalizedError {
    case keychainWriteFailed

    var errorDescription: String? {
        "The MCP access token could not be saved to the Keychain."
    }
}

enum MCPPort {
    static let defaultsKey = "xyz.agentage.lenora.mcp.port"
    static let defaultValue: UInt16 = 19789

    static var current: UInt16 {
        resolve(UserDefaults.standard.object(forKey: defaultsKey) as? Int)
    }

    static func resolve(_ stored: Int?) -> UInt16 {
        guard let stored, (1024...65535).contains(stored) else { return defaultValue }
        return UInt16(stored)
    }
}
