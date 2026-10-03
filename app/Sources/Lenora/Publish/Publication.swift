import AVFoundation
import Foundation
import MCP

enum PublishRole: String, Codable, Sendable, CaseIterable {
    case stream, download, poster, vertical, teaser
}

struct PublishOptions: Codable, Sendable, Equatable {
    var vertical: String?
    var teaserSeconds: Int?

    var roles: [PublishRole] {
        [.stream, .download, .poster] + (vertical == nil ? [] : [.vertical]) + (teaserSeconds == nil ? [] : [.teaser])
    }

    func merging(_ other: PublishOptions) -> PublishOptions {
        PublishOptions(vertical: other.vertical ?? vertical, teaserSeconds: other.teaserSeconds ?? teaserSeconds)
    }
}

extension VideoPublishParams {
    init(_ options: PublishOptions) {
        self.init(outputs: Outputs(vertical: options.vertical, teaserSeconds: options.teaserSeconds))
    }
}

struct PublishedOutput: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable { case pending, ready, failed }

    let role: PublishRole
    var url: URL? = nil
    var status: Status
    var errorCode: String? = nil
    var message: String? = nil
}

struct Publication: Codable, Sendable, Equatable, Identifiable {
    enum Status: String, Codable, Sendable { case uploading, processing, ready, partial, failed, unpublished }

    let id: UUID
    let exportFilename: String
    let createdAt: Date
    let model: String
    let durationSeconds: Double
    var options: PublishOptions
    var assetRef: String? = nil
    var jobId: String? = nil
    var status: Status
    var outputs: [PublishedOutput]
    var estimate: BackendEstimate? = nil
    var message: String? = nil

    func url(_ role: PublishRole) -> URL? { outputs.first { $0.role == role }?.url }

    /// Roles in `options` that aren't ready yet, or whose aspect or length changed.
    func rolesToRequest(for options: PublishOptions) -> [PublishRole] {
        options.roles.filter { role in
            guard outputs.first(where: { $0.role == role })?.status == .ready else { return true }
            switch role {
            case .vertical: return options.vertical != self.options.vertical
            case .teaser: return options.teaserSeconds != self.options.teaserSeconds
            default: return false
            }
        }
    }

    mutating func request(_ roles: [PublishRole], options: PublishOptions) {
        self.options = options
        for role in roles { set(PublishedOutput(role: role, status: .pending)) }
        message = nil
    }

    mutating func apply(_ state: JobState) {
        for result in state.results ?? [] {
            guard let role = result.role.flatMap(PublishRole.init(rawValue:)) else { continue }
            set(PublishedOutput(role: role, url: result.url, status: .ready))
        }
        for failure in state.failedOutputs ?? [] {
            guard let role = PublishRole(rawValue: failure.role) else { continue }
            set(PublishedOutput(role: role, status: .failed, errorCode: failure.code, message: failure.message))
        }
        switch state.status {
        case .queued, .running:
            status = .processing
        case .succeeded:
            failPending(code: "provider_error", message: "The backend returned no result for this output.")
            status = outputs.allSatisfy { $0.status == .ready } ? .ready : .partial
        case .failed, .cancelled:
            let code = state.error?.code ?? "provider_error"
            let message = state.error?.message ?? "Publishing failed."
            failPending(code: code, message: message)
            status = .failed
            self.message = message
        }
    }

    mutating func markFailed(message: String) {
        failPending(code: "provider_error", message: message)
        status = .failed
        self.message = message
    }

    mutating func markUnpublished() {
        status = .unpublished
        for index in outputs.indices { outputs[index].url = nil }
    }

    private mutating func failPending(code: String, message: String) {
        for index in outputs.indices where outputs[index].status == .pending {
            outputs[index].status = .failed
            outputs[index].errorCode = code
            outputs[index].message = message
        }
    }

    private mutating func set(_ output: PublishedOutput) {
        outputs.removeAll { $0.role == output.role }
        outputs.append(output)
        outputs.sort { PublishRole.allCases.firstIndex(of: $0.role)! < PublishRole.allCases.firstIndex(of: $1.role)! }
    }
}

struct PublishProbe: Sendable, Equatable {
    let byteCount: Int64
    let durationSeconds: Double

    @concurrent
    static func read(_ url: URL) async throws -> PublishProbe {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw PublishRefusal.unreadable }
        let duration = try await AVURLAsset(url: url).load(.duration)
        return PublishProbe(byteCount: Int64(size), durationSeconds: duration.seconds)
    }
}

struct PublishLimits: Decodable, Sendable, Equatable {
    struct SecondsRange: Decodable, Sendable, Equatable {
        let min: Int
        let max: Int
    }

    let verticalAspects: [String]?
    let teaserSeconds: SecondsRange?

    init(verticalAspects: [String]?, teaserSeconds: SecondsRange?) {
        self.verticalAspects = verticalAspects
        self.teaserSeconds = teaserSeconds
    }

    /// Reads `ui.publish`; nil when the model isn't a publish model or the hints are malformed.
    init?(model: BackendModel) {
        guard model.kind == PublishService.kind, case .object(let ui)? = model.ui, let hints = ui["publish"],
              let data = try? JSONEncoder().encode(hints),
              let limits = try? JSONDecoder().decode(PublishLimits.self, from: data)
        else { return nil }
        if let range = limits.teaserSeconds, range.min > range.max { return nil }
        self = limits
    }

    func refusal(for options: PublishOptions, probe: PublishProbe, maxBytes: Int64?) -> PublishRefusal? {
        if let maxBytes, probe.byteCount > maxBytes { return .tooLarge(byteCount: probe.byteCount, maxBytes: maxBytes) }
        guard probe.durationSeconds.isFinite, probe.durationSeconds > 0 else { return .unreadable }
        if let vertical = options.vertical, !(verticalAspects ?? []).contains(vertical) {
            return .unsupportedAspect(vertical, allowed: verticalAspects ?? [])
        }
        if let seconds = options.teaserSeconds {
            guard let range = teaserSeconds else { return .teaserUnsupported }
            guard (range.min...range.max).contains(seconds) else { return .teaserOutOfRange(seconds, min: range.min, max: range.max) }
            guard Double(seconds) < probe.durationSeconds else { return .teaserTooLong(seconds, durationSeconds: probe.durationSeconds) }
        }
        return nil
    }
}

enum PublishRefusal: Error, Equatable {
    case unavailable
    case notConfirmed
    case exportNotPublishable
    case unreadable
    case tooLarge(byteCount: Int64, maxBytes: Int64)
    case unsupportedAspect(String, allowed: [String])
    case teaserUnsupported
    case teaserOutOfRange(Int, min: Int, max: Int)
    case teaserTooLong(Int, durationSeconds: Double)
    case notFound
    case busy
    case notUploaded
    case unpublished

    /// Stable machine code for Agent tools.
    var code: String {
        switch self {
        case .unavailable: "unavailable"
        case .tooLarge: "input_too_large"
        case .notFound: "not_found"
        default: "invalid_request"
        }
    }

    /// English message for Agent tools.
    var message: String {
        switch self {
        case .unavailable: "No connected backend can publish video."
        case .notConfirmed: "Publishing makes the video public; pass confirmPublic: true."
        case .exportNotPublishable: "Only completed MP4 or MOV exports from this project's export queue can be published."
        case .unreadable: "The export file can't be read."
        case .tooLarge(let bytes, let max): "The export is \(bytes) bytes; publishing accepts up to \(max) bytes."
        case .unsupportedAspect(let aspect, let allowed): "Vertical aspect \(aspect) isn't supported. Allowed: \(allowed.joined(separator: ", "))."
        case .teaserUnsupported: "The backend can't make teasers."
        case .teaserOutOfRange(let seconds, let min, let max): "Teaser length \(seconds) s is outside \(min)–\(max) s."
        case .teaserTooLong(let seconds, let duration): "A \(seconds) s teaser must be shorter than the \(Int(duration)) s video."
        case .notFound: "No publication with that ID in this project."
        case .busy: "This publication is still uploading or processing."
        case .notUploaded: "This publication never finished uploading; publish the export again."
        case .unpublished: "This publication was unpublished."
        }
    }

    @MainActor var userMessage: String {
        switch self {
        case .unavailable: L10n.string("No connected backend can publish video.")
        case .notConfirmed: L10n.string("Confirm that anyone with the link can watch.")
        case .exportNotPublishable: L10n.string("Only completed MP4 or MOV exports can be published.")
        case .unreadable: L10n.string("The export file can't be read.")
        case .tooLarge(let bytes, let max):
            L10n.string("The export is \(bytes.formatted(.byteCount(style: .file))); publishing accepts up to \(max.formatted(.byteCount(style: .file))).")
        case .unsupportedAspect(let aspect, _): L10n.string("Vertical aspect \(aspect) isn't supported.")
        case .teaserUnsupported: L10n.string("Teasers aren't available.")
        case .teaserOutOfRange(_, let min, let max): L10n.string("Teasers must be \(min)–\(max) seconds.")
        case .teaserTooLong: L10n.string("The teaser must be shorter than the video.")
        case .notFound: L10n.string("The publication no longer exists.")
        case .busy: L10n.string("Wait for the current upload or processing to finish.")
        case .notUploaded: L10n.string("The upload didn't finish. Publish the export again.")
        case .unpublished: L10n.string("This video was unpublished.")
        }
    }
}

extension ExportJob {
    /// The upload content type of a video export; nil for timeline interchange and project exports.
    var videoContentType: String? {
        switch outputURL.pathExtension.lowercased() {
        case "mp4": "video/mp4"
        case "mov": "video/quicktime"
        default: nil
        }
    }
}
