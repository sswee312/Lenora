import Foundation

enum EditAction: String {
    case upscale
    case removeBackground
    case generativeFill, replace, remove, recolor, replaceBackground, restore
    case edit
    case rerun
    case lipSync
    case reframe
    case generateMusic
    case generateSFX
    case createVideo

    static let editMaxDurationSeconds: Double = 10.0
    static let allAIEdits: [EditAction] = [.generativeFill, .replace, .remove, .recolor, .replaceBackground, .restore]

    /// The image.edit op this action performs.
    var editOp: String? {
        switch self {
        case .generativeFill: "fill"
        case .replace: "replace"
        case .remove: "remove"
        case .recolor: "recolor"
        case .replaceBackground: "backgroundReplace"
        case .restore: "restore"
        default: nil
        }
    }

    @MainActor var aiEditTitle: String {
        switch self {
        case .generativeFill: L10n.string("Generative Fill")
        case .replace: L10n.string("Replace")
        case .remove: L10n.string("Remove")
        case .recolor: L10n.string("Recolor")
        case .replaceBackground: L10n.string("Replace Background")
        case .restore: L10n.string("Restore")
        default: L10n.string("Reframe")
        }
    }

    @MainActor var aiEditDescription: String {
        switch self {
        case .generativeFill: L10n.string("Extend the image to a new aspect ratio")
        case .replace: L10n.string("Swap one object for another")
        case .remove: L10n.string("Erase an object from the image")
        case .recolor: L10n.string("Change the color of an object")
        case .replaceBackground: L10n.string("Put the subject on a new background")
        case .restore: L10n.string("Repair noise, blur and compression damage")
        default: L10n.string("Change aspect ratio and extend the frame with AI")
        }
    }

    var aiEditSymbol: String {
        switch self {
        case .generativeFill: "rectangle.expand.vertical"
        case .replace: "arrow.left.arrow.right"
        case .remove: "eraser"
        case .recolor: "paintpalette"
        case .replaceBackground: "photo.on.rectangle"
        case .restore: "wand.and.stars"
        default: "aspectratio"
        }
    }

    func kinds(for mediaType: ClipType) -> [String] {
        switch (self, mediaType) {
        case (.upscale, .image): ["image.upscale"]
        case (.upscale, .video): ["video.upscale"]
        case (.removeBackground, .image): ["image.removeBackground"]
        case (.generativeFill, .image), (.replace, .image), (.remove, .image),
             (.recolor, .image), (.replaceBackground, .image), (.restore, .image): ["image.edit"]
        case (.edit, .image): ["image.generate"]
        case (.edit, .video): ["video.edit"]
        case (.rerun, .image): ["image.generate", "image.edit", "image.upscale"]
        case (.rerun, .video): ClipType.video.generationKinds + ["video.upscale"]
        case (.rerun, .audio): ClipType.audio.generationKinds
        case (.lipSync, .video): ["video.lipSync"]
        case (.reframe, .video): ["video.reframe"]
        case (.generateMusic, .video): ["audio.music"]
        case (.generateSFX, .video): ["audio.sfx"]
        case (.createVideo, .image): ["video.generate"]
        default: []
        }
    }

    @MainActor func isAvailable(for mediaType: ClipType, in catalog: ModelCatalog = .shared) -> Bool {
        guard let op = editOp else { return catalog.supportsAny(of: kinds(for: mediaType)) }
        return mediaType == .image && catalog.models(ofKind: "image.edit").contains { $0.operations?.contains(op) == true }
    }

    func group(for mediaType: ClipType) -> AIEditActionGroup {
        switch self {
        case .generateMusic, .generateSFX:
            .audio
        case .rerun where mediaType == .audio:
            .audio
        case .upscale, .removeBackground, .generativeFill, .replace, .remove, .recolor, .replaceBackground, .restore,
             .edit, .rerun, .lipSync, .reframe, .createVideo:
            .enhance
        }
    }

    @MainActor
    static func available(for asset: MediaAsset, effectiveDurationOverride: Double? = nil) -> [EditAction] {
        let candidates: [EditAction]
        switch asset.type {
        case .image: candidates = [.upscale, .removeBackground] + allAIEdits + [.edit, .rerun, .createVideo]
        case .video:
            candidates = [
                .upscale, .edit, .rerun, .lipSync, .reframe,
                .generateMusic, .generateSFX,
            ]
        case .audio, .text: candidates = [.upscale, .edit, .rerun]
        case .lottie, .sequence, .subtitle: candidates = []
        }
        return candidates.filter {
            $0.availability(for: asset, effectiveDurationOverride: effectiveDurationOverride).isAvailable
        }
    }

    @MainActor
    func availability(for asset: MediaAsset, effectiveDurationOverride: Double? = nil) -> EditActionAvailability {
        switch self {
        case .upscale:
            guard asset.type == .video || asset.type == .image else {
                return .disabled(reason: L10n.string("Upscale only works on video or images"))
            }
            guard isAvailable(for: asset.type), !UpscaleModelConfig.models(for: asset.type).isEmpty else {
                return .disabled(reason: L10n.string("Upscale model not available"))
            }
            if asset.isGenerating {
                return .disabled(reason: L10n.string("Generation in progress"))
            }
            return .available

        case .removeBackground:
            guard asset.type == .image else {
                return .disabled(reason: L10n.string("Remove Background works on images only."))
            }
            guard isAvailable(for: asset.type) else {
                return .disabled(reason: L10n.string("Remove Background isn't available from the connected backend"))
            }
            if asset.isGenerating {
                return .disabled(reason: L10n.string("Generation in progress"))
            }
            return .available

        case .reframe:
            guard asset.type == .video else {
                return .disabled(reason: L10n.string("Reframe only works on video"))
            }
            guard isAvailable(for: asset.type) else {
                return .disabled(reason: L10n.string("Reframe model not available"))
            }
            if asset.isGenerating {
                return .disabled(reason: L10n.string("Generation in progress"))
            }
            return .available

        case .generativeFill, .replace, .remove, .recolor, .replaceBackground, .restore:
            guard asset.type == .image else {
                return .disabled(reason: L10n.string("This edit works on images only."))
            }
            guard isAvailable(for: asset.type) else {
                return .disabled(reason: L10n.string("The connected backend doesn't offer this edit. Open Settings → Backend."))
            }
            if asset.isGenerating {
                return .disabled(reason: L10n.string("Generation in progress"))
            }
            return .available

        case .lipSync:
            guard asset.type == .video else {
                return .disabled(reason: L10n.string("Lip Sync only works on video"))
            }
            guard isAvailable(for: asset.type) else {
                return .disabled(reason: L10n.string("Lip Sync model not available"))
            }
            if asset.isGenerating {
                return .disabled(reason: L10n.string("Generation in progress"))
            }
            guard let model = VideoModelConfig.lipSync else {
                return .disabled(reason: L10n.string("Lip Sync model not available"))
            }
            let duration = effectiveDurationOverride ?? asset.resolvedDuration
            if let error = model.validateSourceDuration(duration) {
                return .disabled(reason: error)
            }
            return .available

        case .edit:
            switch asset.type {
            case .video:
                guard isAvailable(for: asset.type), VideoModelConfig.edit != nil else {
                    return .disabled(reason: L10n.string("Edit model not available"))
                }
                let duration = effectiveDurationOverride ?? asset.resolvedDuration
                guard duration > 0 else {
                    return .disabled(reason: L10n.string("Loading video metadata…"))
                }
                guard duration <= EditAction.editMaxDurationSeconds else {
                    return .disabled(reason: L10n.string(
                        "Edit supports up to \(Int(EditAction.editMaxDurationSeconds))s (this is \(Int(duration.rounded()))s)"
                    ))
                }
            case .image:
                guard isAvailable(for: asset.type), ImageModelConfig.edit != nil else {
                    return .disabled(reason: L10n.string("Edit model not available"))
                }
            case .audio:
                return .disabled(reason: L10n.string("Edit doesn't support audio"))
            case .text:
                return .disabled(reason: L10n.string("Edit doesn't support text"))
            case .lottie:
                return .disabled(reason: L10n.string("Edit doesn't support Lottie"))
            case .sequence:
                return .disabled(reason: L10n.string("Edit doesn't support sequences"))
            case .subtitle:
                return .disabled(reason: L10n.string("Edit doesn't support subtitles"))
            }
            if asset.isGenerating {
                return .disabled(reason: L10n.string("Generation in progress"))
            }
            return .available

        case .generateMusic:
            return Self.videoAudioAvailability(
                for: asset,
                kind: .music,
                effectiveDurationOverride: effectiveDurationOverride
            )

        case .generateSFX:
            return Self.videoAudioAvailability(
                for: asset,
                kind: .sfx,
                effectiveDurationOverride: effectiveDurationOverride
            )

        case .createVideo:
            guard asset.type == .image else {
                return .disabled(reason: L10n.string("Create Video only works on images"))
            }
            guard isAvailable(for: asset.type) else {
                return .disabled(reason: L10n.string("Video model not available"))
            }
            if asset.isGenerating {
                return .disabled(reason: L10n.string("Generation in progress"))
            }
            return .available

        case .rerun:
            guard asset.isGenerated else {
                return .disabled(reason: L10n.string("Only available for AI-generated media"))
            }
            if asset.isGenerating {
                return .disabled(reason: L10n.string("Generation in progress"))
            }
            guard isAvailable(for: asset.type),
                  let modelId = asset.generationInput?.model, ModelRegistry.exists(id: modelId) else {
                return .disabled(reason: L10n.string("Model no longer available"))
            }
            return .available
        }
    }

    @MainActor
    private static func videoAudioAvailability(
        for asset: MediaAsset,
        kind: VideoToAudioEditKind,
        effectiveDurationOverride: Double?
    ) -> EditActionAvailability {
        guard asset.type == .video else {
            let reason = switch kind {
            case .music: L10n.string("Generate Music only works on video")
            case .sfx: L10n.string("Generate SFX only works on video")
            }
            return .disabled(reason: reason)
        }
        if asset.isGenerating {
            return .disabled(reason: L10n.string("Generation in progress"))
        }
        let duration = effectiveDurationOverride ?? asset.resolvedDuration
        guard duration > 0 else {
            return .disabled(reason: L10n.string("Loading video metadata…"))
        }
        guard kind.action.isAvailable(for: asset.type), let model = kind.model else {
            return .disabled(reason: L10n.string("\(kind.providerName) model not available"))
        }
        if let err = model.validate(spanSeconds: duration) {
            return .disabled(reason: err)
        }
        return .available
    }
}

enum AIEditActionGroup {
    case enhance
    case audio
}

enum EditActionAvailability: Equatable {
    case available
    case disabled(reason: String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var reason: String? {
        if case .disabled(let r) = self { return r }
        return nil
    }
}
