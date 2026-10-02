import Foundation

struct LenoraBackendConfiguration: Sendable, Equatable {
    let baseURL: URL
    let token: String?
}
