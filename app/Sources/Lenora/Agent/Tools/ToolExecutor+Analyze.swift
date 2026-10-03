import Foundation

enum AnalysisSummary {
    static func tagsAndCaption(in analysis: JSONValue) -> (tags: [String], caption: String?) {
        guard case .object(let object) = analysis else { return ([], nil) }
        var tags = tagNames(object["tags"])
        if tags.isEmpty, case .object(let models)? = object["categorization"] {
            for model in models.values {
                guard case .object(let body) = model else { continue }
                tags.append(contentsOf: tagNames(body["data"]))
            }
        }
        if tags.isEmpty { tags.append(contentsOf: tagNames(object["data"])) }
        let caption = text(object["caption"]) ?? nestedCaption(object["data"])
        var seen: Set<String> = []
        let unique = tags.filter { seen.insert($0).inserted }
        return (unique, caption)
    }

    private static func nestedCaption(_ value: JSONValue?) -> String? {
        guard case .object(let data)? = value else { return nil }
        return text(data["caption"])
    }

    private static func tagNames(_ value: JSONValue?) -> [String] {
        switch value {
        case .array(let items):
            return items.compactMap { item in
                switch item {
                case .string(let tag): return tag
                case .object(let fields): return text(fields["tag"]) ?? text(fields["name"])
                default: return nil
                }
            }
        case .object(let groups):
            return groups.values.flatMap { tagNames($0) }
        default:
            return []
        }
    }

    private static func text(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value, !text.isEmpty else { return nil }
        return text
    }
}

extension ToolExecutor {
    func analyzeMedia(_ editor: EditorViewModel, _ args: [String: Any]) async -> ToolResult {
        let mediaRef: String
        do { mediaRef = try args.requireString("mediaRef") }
        catch { return Self.transformError(code: "invalid_request", message: "mediaRef is required.", field: "mediaRef") }
        let source: MediaAsset
        do { source = try asset(mediaRef, editor: editor) }
        catch { return Self.transformError(code: "invalid_request", message: "Media not found: \(mediaRef)", field: "mediaRef") }
        guard source.type == .image else {
            return Self.transformError(code: "invalid_request", message: "Analysis needs an image asset.", field: "mediaRef")
        }

        let models = editor.generationService.catalog.models(ofKind: "image.analyze")
        guard !models.isEmpty else {
            return Self.transformError(code: "unsupported_kind", message: "No connected backend offers image analysis. Tell the user to connect one in Settings → Backend.", field: nil)
        }
        let model: BackendModel
        if let requested = args["model"] as? String {
            guard let match = models.first(where: { $0.id == requested }) else {
                return Self.transformError(code: "unknown_model", message: "Unknown analysis model '\(requested)'. Call list_models with type='analyze'.", field: "model")
            }
            model = match
        } else if let ready = Self.defaultAnalyzeModel(models) {
            model = ready
        } else {
            return Self.transformError(code: "invalid_request", message: "Every analysis model needs extra input. Call list_models with type='analyze' and pass what the model requires.", field: "model")
        }

        let params: AnalyzeJobParams
        do { params = try Self.analyzeParams(args, requires: model.analysisRequires) }
        catch let error as TransformArgumentError {
            return Self.transformError(code: "invalid_request", message: error.message, field: error.field)
        } catch {
            return Self.transformError(code: "invalid_request", message: "Invalid analysis parameters.", field: nil)
        }

        let limits = MediaInputCheck.Source(url: source.url, width: source.sourceWidth, height: source.sourceHeight)
        if let refusal = await MediaInputCheck.refusal(for: limits, limits: model.inputs) {
            return Self.transformError(code: refusal.code, message: refusal.toolMessage, field: nil)
        }

        let analysis: JSONValue
        do {
            analysis = try await editor.generationService.analyzeImage(fileURL: source.url, modelId: model.id, params: params)
        } catch let error as BackendError {
            return Self.transformError(code: error.code, message: error.localizedDescription, field: nil)
        } catch let error as GenerationError {
            let code = if case .modelUnavailable = error { "unknown_model" } else { "provider_error" }
            return Self.transformError(code: code, message: error.localizedDescription, field: nil)
        } catch {
            return Self.transformError(code: "provider_error", message: error.localizedDescription, field: nil)
        }

        let summary = AnalysisSummary.tagsAndCaption(in: analysis)
        source.analysis = MediaAnalysis(model: model.id, tags: summary.tags, caption: summary.caption)
        editor.updateManifestMetadata(for: [source])
        editor.onProjectCheckpointRequired?()

        var receipt: [String: Any] = [
            "mediaRef": source.id,
            "model": model.id,
            "tags": summary.tags,
            "analysis": analysis.anyValue,
        ]
        if let caption = summary.caption { receipt["caption"] = caption }
        guard let json = Self.jsonString(receipt) else { return .error("Failed to encode analysis") }
        return .ok(json)
    }

    static func defaultAnalyzeModel(_ models: [BackendModel]) -> BackendModel? {
        let ready = models.filter { $0.analysisRequires == nil }
        return ready.first { $0.id.hasSuffix("/google-tagging") }
            ?? ready.first { $0.id.hasSuffix("/imagga-tagging") }
            ?? ready.first
    }

    static func analyzeParams(_ args: [String: Any], requires: String?) throws -> AnalyzeJobParams {
        func text(_ key: String) -> String? {
            guard let value = args[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let prompt = text("prompt")
        let questions = try stringList(args["questions"], field: "questions")
        let tags = try analyzeTags(args["tags"])
        if let requires {
            switch requires {
            case "prompt" where prompt == nil:
                throw TransformArgumentError(field: "prompt", message: "This model needs a prompt.")
            case "tags" where tags == nil:
                throw TransformArgumentError(field: "tags", message: "This model needs tags, each with a name and a description.")
            case "questions" where questions?.isEmpty != false:
                throw TransformArgumentError(field: "questions", message: "This model needs questions.")
            default:
                break
            }
        }
        return AnalyzeJobParams(prompt: prompt, tags: tags, questions: questions)
    }

    private static func analyzeTags(_ value: Any?) throws -> [AnalyzeTag]? {
        guard let rows = try objectRows(value, field: "tags", emptyMessage: "tags must be a list of {name, description}.") else {
            return nil
        }
        return try rows.map { row in
            guard let name = row["name"] as? String, !name.isEmpty,
                  let description = row["description"] as? String, !description.isEmpty else {
                throw TransformArgumentError(field: "tags", message: "Each tag needs a name and a description.")
            }
            return AnalyzeTag(name: name, description: description)
        }
    }

    private static func stringList(_ value: Any?, field: String) throws -> [String]? {
        guard let value, !(value is NSNull) else { return nil }
        let items: [String]
        if let strings = value as? [String] {
            items = strings
        } else if let any = value as? [Any] {
            items = any.compactMap { $0 as? String }
            guard items.count == any.count else {
                throw TransformArgumentError(field: field, message: "\(field) must be a list of strings.")
            }
        } else {
            throw TransformArgumentError(field: field, message: "\(field) must be a list of strings.")
        }
        return items
    }

    private static func objectRows(_ value: Any?, field: String, emptyMessage: String) throws -> [[String: Any]]? {
        guard let value, !(value is NSNull) else { return nil }
        let rows: [[String: Any]]
        if let objects = value as? [[String: Any]] {
            rows = objects
        } else if let any = value as? [Any] {
            rows = any.compactMap { $0 as? [String: Any] }
            guard rows.count == any.count else { throw TransformArgumentError(field: field, message: emptyMessage) }
        } else {
            throw TransformArgumentError(field: field, message: emptyMessage)
        }
        guard !rows.isEmpty else { throw TransformArgumentError(field: field, message: emptyMessage) }
        return rows
    }
}
