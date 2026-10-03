import Foundation
import MCP

enum JobStatus: String, Codable, Sendable {
    case queued, running, succeeded, failed, cancelled

    var isTerminal: Bool { self == .succeeded || self == .failed || self == .cancelled }
}

struct BackendEstimate: Codable, Sendable, Equatable {
    let amount: Double
    let unit: String
}

struct BackendInputLimits: Decodable, Sendable, Equatable {
    let types: [String]
    let maxBytes: Int64
    let maxPixels: Int64?
}

struct BackendModel: Decodable, Sendable {
    let id: String
    let kind: String
    let displayName: String
    let inputs: BackendInputLimits
    let cancellable: Bool
    let estimate: BackendEstimate?
    let ui: Value?
    let operations: [String]?
}

struct AdapterVersion: Decodable, Sendable, Equatable {
    let id: String
    let version: String
}

struct BackendCapabilities: Decodable, Sendable {
    let protocolVersion: String
    let adapters: [AdapterVersion]
    let models: [BackendModel]

    static let empty = BackendCapabilities(protocolVersion: "1", adapters: [], models: [])
}

struct AdapterHealth: Decodable, Sendable, Equatable {
    let id: String
    let enabled: Bool
    let reason: String?
    let details: AdapterHealthDetails?
}

struct AdapterHealthDetails: Decodable, Sendable, Equatable {
    let addons: [AddonStatus]?
    let budget: BudgetStatus?
}

struct AddonStatus: Decodable, Sendable, Equatable, Identifiable {
    let id: String
    let mode: String
    let available: Bool
    let reason: String?
}

struct BudgetStatus: Decodable, Sendable, Equatable {
    let limit: Double?
    let used: Double
    let day: String
}

struct BackendHealth: Decodable, Sendable {
    let status: String
    let protocolVersion: String
    let backendVersion: String?
    let adapters: [AdapterHealth]?
}

struct UploadTicket: Decodable, Sendable {
    struct Ticket: Decodable, Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let fields: [String: String]
        let fileField: String?
        let expiresAt: Date
    }

    let assetRef: String
    let ticket: Ticket
}

enum InputRole: String, Codable, Sendable {
    case startFrame, endFrame, reference
}

struct JobInput: Codable, Sendable, Equatable {
    enum Source: Equatable, Sendable { case assetRef(String), url(URL) }

    let source: Source
    let role: InputRole?

    static func assetRef(_ ref: String, role: InputRole? = nil) -> JobInput { JobInput(source: .assetRef(ref), role: role) }
    static func url(_ url: URL, role: InputRole? = nil) -> JobInput { JobInput(source: .url(url), role: role) }

    private init(source: Source, role: InputRole?) {
        self.source = source
        self.role = role
    }

    private enum CodingKeys: String, CodingKey { case assetRef, url, role }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let ref = try container.decodeIfPresent(String.self, forKey: .assetRef) {
            source = .assetRef(ref)
        } else {
            source = .url(try container.decode(URL.self, forKey: .url))
        }
        role = try container.decodeIfPresent(InputRole.self, forKey: .role)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch source {
        case .assetRef(let ref): try container.encode(ref, forKey: .assetRef)
        case .url(let url): try container.encode(url, forKey: .url)
        }
        try container.encodeIfPresent(role, forKey: .role)
    }
}

struct EmptyParams: Encodable, Sendable {}

struct JobRequest: Encodable, Sendable {
    let kind: String
    let model: String
    let inputs: [JobInput]
    let params: any Encodable & Sendable

    private enum CodingKeys: String, CodingKey { case kind, model, inputs, params }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(model, forKey: .model)
        try container.encode(inputs, forKey: .inputs)
        try container.encode(params, forKey: .params)
    }
}

struct SubmittedJob: Decodable, Sendable {
    let jobId: String
    let status: JobStatus
    let estimate: BackendEstimate?
}

struct JobResult: Codable, Sendable, Equatable {
    let url: URL
    let contentType: String
    let fileExtension: String
}

struct JobFailure: Decodable, Sendable, Equatable {
    let code: String
    let message: String
    let retryable: Bool
}

struct JobState: Decodable, Sendable {
    let jobId: String
    let status: JobStatus
    let results: [JobResult]?
    let error: JobFailure?
}

struct BackendProblem: Decodable, Sendable, Equatable, Error {
    let code: String
    let detail: String?
    let status: Int
    let retryable: Bool
}

enum BackendCoding {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = try? Date(text, strategy: .iso8601) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid ISO 8601 date."))
            }
            return date
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
