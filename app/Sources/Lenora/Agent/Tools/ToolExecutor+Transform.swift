import Foundation

extension ToolExecutor {
    func transformMedia(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let mediaRef = try args.requireString("mediaRef")
        let operation = try args.requireString("operation")
        guard operation == "removeBackground" else {
            throw ToolError("Unsupported operation '\(operation)'. Supported: removeBackground")
        }
        let source = try asset(mediaRef, editor: editor)
        switch await EditSubmitter.submitEdit(.removeBackground, asset: source, editor: editor) {
        case .refused(let refusal):
            throw ToolError(refusal.toolMessage)
        case .started(let placeholderId, let estimate):
            var receipt: [String: Any] = ["mediaRef": placeholderId, "status": "generating", "sourceMediaRef": source.id]
            if let estimate { receipt["estimate"] = ["amount": estimate.amount, "unit": estimate.unit] }
            guard let json = Self.jsonString(receipt) else { return .error("Failed to encode receipt") }
            return .ok(json)
        }
    }
}
