import Foundation

enum BackendConfig {
    static let clerkPublishableKey: String? = string("LenoraClerkPublishableKey")
    static let clerkKeychainAccessGroup: String? = string("LenoraClerkKeychainAccessGroup")
    static let convexDeploymentURL: URL? = string("LenoraConvexDeploymentURL").flatMap { URL(string: $0) }
    static let convexHttpURL: URL? = string("LenoraConvexHttpURL").flatMap { URL(string: $0) }

    private static func string(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty
        else { return nil }
        return value
    }
}
