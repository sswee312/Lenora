import Foundation

extension ToolExecutor {
    func publishExport(_ editor: EditorViewModel, _ args: [String: Any]) async -> ToolResult {
        let service = editor.publishService
        do {
            let input: PublishExportArgs = try decodeToolArgs(args, path: "publish_export")
            let options = PublishOptions(vertical: input.vertical, teaserSeconds: input.teaserSeconds)
            let confirmed = input.confirmPublic == true
            guard confirmed else { throw PublishRefusal.notConfirmed }
            switch (input.exportJobId, input.publicationId) {
            case (let raw?, nil):
                guard let id = UUID(uuidString: raw) else { throw PublishArgumentError(field: "exportJobId", message: "exportJobId must be a jobId from export_project or manage_exports.") }
                let record = try await service.publish(exportJobId: id, options: options, confirmPublic: confirmed)
                return try Self.publishReceipt(record.toolPayload(), tool: "publish_export")
            case (nil, let raw?):
                guard let id = UUID(uuidString: raw) else { throw PublishArgumentError(field: "publicationId", message: "publicationId must come from publish_export or manage_publications.") }
                let (record, noop) = try service.addOutputs(to: id, options: options, confirmPublic: confirmed)
                return try Self.publishReceipt(record.toolPayload(noop: noop), tool: "publish_export")
            default:
                throw PublishArgumentError(field: "exportJobId", message: "Pass exactly one of exportJobId or publicationId.")
            }
        } catch {
            return Self.publishError(error)
        }
    }

    func managePublications(_ editor: EditorViewModel, _ args: [String: Any]) async -> ToolResult {
        let service = editor.publishService
        do {
            let input: ManagePublicationsArgs = try decodeToolArgs(args, path: "manage_publications")
            switch input.action {
            case "list":
                guard input.publicationId == nil else { throw PublishArgumentError(field: "publicationId", message: "publicationId only applies to get and unpublish.") }
                return try Self.publishReceipt(["publications": service.publicationsNewestFirst.map { $0.toolPayload() }], tool: "manage_publications")
            case "get", "unpublish":
                guard let raw = input.publicationId, let id = UUID(uuidString: raw) else {
                    throw PublishArgumentError(field: "publicationId", message: "\(input.action) requires a publicationId from manage_publications list.")
                }
                guard let record = service.publications.first(where: { $0.id == id }) else { throw PublishRefusal.notFound }
                guard input.action == "unpublish" else { return try Self.publishReceipt(record.toolPayload(), tool: "manage_publications") }
                let noop = try await service.unpublish(id)
                let updated = service.publications.first { $0.id == id } ?? record
                return try Self.publishReceipt(updated.toolPayload(noop: noop), tool: "manage_publications")
            default:
                throw PublishArgumentError(field: "action", message: "action must be list, get or unpublish.")
            }
        } catch {
            return Self.publishError(error)
        }
    }

    private struct PublishArgumentError: Error { let field: String?; let message: String }

    private static func publishReceipt(_ payload: [String: Any], tool: String) throws -> ToolResult {
        guard let json = jsonString(payload) else { throw ToolError("\(tool): failed to encode receipt") }
        return .ok(json)
    }

    static func publishError(_ error: Error) -> ToolResult {
        switch error {
        case let refusal as PublishRefusal: transformError(code: refusal.code, message: refusal.message, field: refusal.field)
        case let error as PublishArgumentError: transformError(code: "invalid_request", message: error.message, field: error.field)
        case let error as ToolError: transformError(code: "invalid_request", message: error.message, field: nil)
        case is CancellationError: transformError(code: "cancelled", message: "The project closed before the request finished.", field: nil)
        case let error as BackendError: transformError(code: error.code, message: error.localizedDescription, field: nil)
        default: transformError(code: "internal_error", message: error.localizedDescription, field: nil)
        }
    }
}

private extension PublishRefusal {
    var field: String? {
        switch self {
        case .notConfirmed: "confirmPublic"
        case .exportNotPublishable: "exportJobId"
        case .unsupportedAspect: "vertical"
        case .teaserUnsupported, .teaserOutOfRange, .teaserTooLong: "teaserSeconds"
        case .notFound, .busy, .notUploaded, .unpublished: "publicationId"
        case .unavailable, .unreadable, .tooLarge: nil
        }
    }
}

private struct PublishExportArgs: DecodableToolArgs {
    static let allowedKeys: Set<String> = ["exportJobId", "publicationId", "confirmPublic", "vertical", "teaserSeconds"]

    var exportJobId: String?
    var publicationId: String?
    var confirmPublic: Bool?
    var vertical: String?
    var teaserSeconds: Int?
}

private struct ManagePublicationsArgs: DecodableToolArgs {
    static let allowedKeys: Set<String> = ["action", "publicationId"]

    let action: String
    var publicationId: String?
}

private extension Publication {
    func toolPayload(noop: Bool? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            "publicationId": id.uuidString,
            "exportFilename": exportFilename,
            "status": status.rawValue,
            "createdAt": createdAt.formatted(.iso8601),
            "outputs": outputs.map { output -> [String: Any] in
                var row: [String: Any] = ["role": output.role.rawValue, "status": output.status.rawValue]
                if let url = output.url { row["url"] = url.absoluteString }
                if let code = output.errorCode { row["errorCode"] = code }
                if let message = output.message { row["message"] = message }
                return row
            },
        ]
        if let estimate { payload["estimate"] = ["amount": estimate.amount, "unit": estimate.unit] }
        if let failure {
            payload["errorCode"] = failure.code
            payload["message"] = failure.message
        }
        if let noop { payload["noop"] = noop }
        return payload
    }
}
