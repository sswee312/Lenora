import Foundation

extension ToolExecutor {
    func transformMedia(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let mediaRef = try args.requireString("mediaRef")
        let operation = try args.requireString("operation")
        let request: MediaEditRequest
        let supported = ToolDefinitions.transformOperations(catalog: editor.generationService.catalog)
        do { request = try Self.mediaEditRequest(operation: operation, args: args, supported: supported) }
        catch let error as TransformArgumentError { return Self.transformError(code: "invalid_request", message: error.message, field: error.field) }
        let source = try asset(mediaRef, editor: editor)
        switch await EditSubmitter.submitEdit(request, asset: source, editor: editor) {
        case .refused(let refusal):
            var field: String?
            if case .invalidParameter(let name, _) = refusal { field = name }
            return Self.transformError(code: refusal.code, message: refusal.toolMessage, field: field)
        case .started(let placeholderId, let estimate):
            var receipt: [String: Any] = ["mediaRef": placeholderId, "status": "generating", "sourceMediaRef": source.id, "operation": operation]
            if let estimate { receipt["estimate"] = ["amount": estimate.amount, "unit": estimate.unit] }
            guard let json = Self.jsonString(receipt) else { return .error("Failed to encode receipt") }
            return .ok(json)
        }
    }

    struct TransformArgumentError: Error { let field: String; let message: String }

    static func mediaEditRequest(operation: String, args: [String: Any], supported: [String]) throws -> MediaEditRequest {
        func text(_ key: String) throws -> String {
            guard let value = args[key] as? String else { throw TransformArgumentError(field: key, message: "\(key) is required for \(operation).") }
            return value
        }
        switch operation {
        case "removeBackground": return .removeBackground
        case "generativeFill": return .edit(.fill(aspectRatio: try text("aspectRatio")))
        case "replace": return .edit(.replace(from: try text("from"), to: try text("to")))
        case "remove": return .edit(.remove(prompt: try text("prompt")))
        case "recolor": return .edit(.recolor(prompt: try text("prompt"), color: try text("color")))
        case "backgroundReplace":
            if let prompt = args["prompt"], !(prompt is String) { throw TransformArgumentError(field: "prompt", message: "prompt must be a string.") }
            return .edit(.backgroundReplace(prompt: args["prompt"] as? String))
        case "restore": return .edit(.restore)
        case "reframe": return .reframe(VideoReframeParams(aspectRatio: try text("aspectRatio")))
        default:
            let available = supported.isEmpty ? "The connected backend offers no transform operations." : "Supported: \(supported.joined(separator: ", "))."
            throw TransformArgumentError(field: "operation", message: "Unsupported operation '\(operation)'. \(available)")
        }
    }

    static func transformError(code: String, message: String, field: String?) -> ToolResult {
        var error: [String: Any] = ["code": code, "message": message]
        if let field { error["field"] = field }
        return .error(jsonString(["error": error]) ?? message)
    }
}
