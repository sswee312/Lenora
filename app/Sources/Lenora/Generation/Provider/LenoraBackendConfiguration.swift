import Foundation

struct LenoraBackendConfiguration: Sendable, Equatable {
    let baseURL: URL
    let token: String?
}

enum BackendConfigurationError: Error, Equatable, Sendable {
    case invalidURL(String)
    case insecureURL(String)
}

extension LenoraBackendConfiguration {
    static let defaultURL = "http://127.0.0.1:8787"
    static let urlDefaultsKey = "xyz.agentage.lenora.backend.url"
    static let tokenAccount = "backend.token"
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    struct Sources: Sendable {
        var environment: [String: String]
        var storedURL: String?
        var plistURL: String?
        var keychainToken: String?
    }

    static func environmentURL(_ environment: [String: String]) -> String? {
        environment["LENORA_BACKEND_URL"].flatMap { $0.isEmpty ? nil : $0 }
    }

    static func environmentToken(_ environment: [String: String]) -> String? {
        environment["LENORA_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
    }

    static func resolve(_ sources: Sources) throws(BackendConfigurationError) -> (configuration: Self, tokenToPersist: String?) {
        let raw = environmentURL(sources.environment) ?? sources.storedURL ?? sources.plistURL ?? defaultURL
        guard let url = URL(string: raw), let scheme = url.scheme, let host = url.host(percentEncoded: false), !host.isEmpty else {
            throw .invalidURL(raw)
        }
        let isLoopback = loopbackHosts.contains(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        guard scheme == "https" || (scheme == "http" && isLoopback) else { throw .insecureURL(raw) }
        let environmentToken = environmentToken(sources.environment)
        let token = environmentToken ?? sources.keychainToken
        let persist = environmentToken.flatMap { $0 == sources.keychainToken ? nil : $0 }
        return (Self(baseURL: url, token: token), persist)
    }
}
