import Foundation
import Observation

enum BackendConnectionState: Equatable, Sendable {
    case unknown, connecting, connected
    case unreachable(URL)
    case unauthorized
    case invalidConfiguration(BackendConfigurationError)
    case tokenNotSaved
    case failed(String)
}

@Observable @MainActor
final class BackendConnection {
    static let shared = BackendConnection()

    private(set) var configuration: LenoraBackendConfiguration?
    private(set) var provider: (any GenerationProvider)?
    private(set) var state: BackendConnectionState = .unknown
    private(set) var health: BackendHealth?
    private(set) var urlFromEnvironment = false
    @ObservationIgnored private var generation = 0

    private init() {}

    func reload() async {
        generation &+= 1
        let current = generation
        state = .connecting
        let defaults = UserDefaults.standard
        let sources = LenoraBackendConfiguration.Sources(
            environment: ProcessInfo.processInfo.environment,
            storedURL: defaults.string(forKey: LenoraBackendConfiguration.urlDefaultsKey),
            plistURL: Bundle.main.object(forInfoDictionaryKey: "LenoraBackendURL") as? String,
            keychainToken: await Self.loadToken()
        )
        guard current == generation else { return }
        urlFromEnvironment = LenoraBackendConfiguration.environmentURL(sources.environment) != nil
        let resolved: (configuration: LenoraBackendConfiguration, tokenToPersist: String?)
        do {
            resolved = try LenoraBackendConfiguration.resolve(sources)
        } catch {
            clear()
            state = .invalidConfiguration(error)
            return
        }
        if let token = resolved.tokenToPersist, !(await Self.storeToken(token)) {
            Log.generation.warning("backend token could not be saved to the Keychain")
        }
        guard current == generation else { return }
        let client = LenoraBackendClient(configuration: resolved.configuration)
        configuration = resolved.configuration
        provider = client
        do {
            let health = try await client.health()
            let capabilities = try await client.capabilities()
            guard current == generation else { return }
            self.health = health
            ModelCatalog.shared.apply(capabilities)
            state = .connected
        } catch {
            guard current == generation else { return }
            health = nil
            ModelCatalog.shared.apply(.empty)
            switch error as? BackendError {
            case .unauthorized: state = .unauthorized
            case .unreachable(let url): state = .unreachable(url)
            default: state = .failed(error.localizedDescription)
            }
            Log.generation.warning("backend connection failed: \(error.localizedDescription)")
        }
    }

    func save(url: String, token: String?) async {
        if LenoraBackendConfiguration.environmentURL(ProcessInfo.processInfo.environment) == nil {
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed.isEmpty ? nil : trimmed, forKey: LenoraBackendConfiguration.urlDefaultsKey)
        }
        if let token, !(await Self.storeToken(token)) {
            generation &+= 1
            clear()
            state = .tokenNotSaved
            Log.generation.warning("backend token could not be saved to the Keychain")
            return
        }
        await reload()
    }

    private func clear() {
        configuration = nil
        provider = nil
        health = nil
        ModelCatalog.shared.apply(.empty)
    }

    @concurrent private static func loadToken() async -> String? {
        KeychainStore.load(account: LenoraBackendConfiguration.tokenAccount)
    }

    @concurrent private static func storeToken(_ token: String) async -> Bool {
        KeychainStore.save(token, account: LenoraBackendConfiguration.tokenAccount)
    }
}
