import Foundation

extension EditSubmitter {
    static func submitEdit(_ request: MediaEditRequest, asset: MediaAsset, editor: EditorViewModel) async -> MediaEditOutcome {
        let service = editor.generationService
        guard let model = service.catalog.models(ofKind: request.kind).first else { return .refused(.unavailable(kind: request.kind)) }
        if case .edit(let params) = request, model.operations?.contains(params.op) != true {
            return .refused(.operationUnavailable(params.op))
        }
        guard asset.type == request.mediaType else { return .refused(.wrongMediaType(request.mediaType)) }
        if let invalid = request.invalidField() { return .refused(.invalidParameter(field: invalid.field, reason: invalid.reason)) }
        let source = MediaInputCheck.Source(url: asset.url, width: asset.sourceWidth, height: asset.sourceHeight)
        if let refusal = await MediaInputCheck.refusal(for: source, limits: model.inputs) { return .refused(refusal) }
        guard editor.mediaAssetsById[asset.id] === asset else { return .refused(.sourceMissing) }

        let sourceAssetId = asset.id
        let isVideo = request.mediaType == .video
        var input = GenerationInput(prompt: "", model: model.id, duration: 0, aspectRatio: "")
        input.undoActionName = request.title
        input.imageURLAssetIds = [sourceAssetId]
        let placeholderId = service.generate(
            genInput: input,
            assetType: request.mediaType,
            placeholderDuration: isVideo ? asset.duration : Defaults.imageDurationSeconds,
            references: [asset],
            name: prefixedName(request.title, for: asset),
            folderId: asset.folderId,
            buildParams: { _ in request.jobParams },
            snapshotRefs: { input, uploaded in
                input.imageURLs = uploaded.isEmpty ? nil : uploaded
            },
            fileExtension: isVideo ? "mp4" : "png",
            projectURL: editor.projectURL,
            editor: editor
        )
        return .started(placeholderId: placeholderId, estimate: model.estimate)
    }

    static func upscaleRefusal(asset: MediaAsset, modelId: String, editor: EditorViewModel) async -> MediaEditRefusal? {
        guard let backendModel = editor.generationService.catalog.backendModel(id: modelId) else {
            return .unavailable(kind: "image.upscale")
        }
        let source = MediaInputCheck.Source(url: asset.url, width: asset.sourceWidth, height: asset.sourceHeight)
        return await MediaInputCheck.refusal(for: source, limits: backendModel.inputs)
    }
}

extension MediaEditRequest {
    var jobParams: GenerationJobParams {
        switch self {
        case .removeBackground: .removeBackground
        case .edit(let params): .edit(params)
        case .reframe(let params): .reframe(params)
        }
    }
}
