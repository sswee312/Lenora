import Foundation
import UniformTypeIdentifiers

enum RemoveBackgroundRefusal: Equatable {
    case notAnImage, unavailable, unsupportedType(String), tooLarge(maxBytes: Int64), sourceMissing

    @MainActor var userMessage: String {
        switch self {
        case .notAnImage:
            return L10n.string("Remove Background works on images only.")
        case .unavailable:
            return L10n.string("No connected backend can remove backgrounds. Open Settings → Backend.")
        case .unsupportedType(let type):
            return L10n.string("\(type) images aren't supported. Use PNG, JPEG, WebP, HEIC or TIFF.")
        case .tooLarge(let max):
            return L10n.string("The image is larger than \(ByteCountFormatter.string(fromByteCount: max, countStyle: .file)).")
        case .sourceMissing:
            return L10n.string("The source file is missing.")
        }
    }

    var toolMessage: String {
        switch self {
        case .notAnImage: "removeBackground needs an image asset."
        case .unavailable: "No connected backend supports removeBackground. Tell the user to connect one in Settings → Backend."
        case .unsupportedType(let type): "Unsupported image type \(type). Use PNG, JPEG, WebP, HEIC or TIFF."
        case .tooLarge(let max): "Image exceeds the \(max)-byte limit."
        case .sourceMissing: "The source file is missing or offline."
        }
    }
}

enum RemoveBackgroundOutcome: Equatable {
    case started(placeholderId: String, estimate: BackendEstimate?)
    case refused(RemoveBackgroundRefusal)
}

extension EditSubmitter {
    static let removeBackgroundKind = "image.removeBackground"

    static func submitRemoveBackground(asset: MediaAsset, editor: EditorViewModel) async -> RemoveBackgroundOutcome {
        guard asset.type == .image else { return .refused(.notAnImage) }
        let service = editor.generationService
        guard let model = service.catalog.models(ofKind: removeBackgroundKind).first else { return .refused(.unavailable) }
        let sourceURL = asset.url
        let contentType = UTType(filenameExtension: sourceURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        guard model.inputs.types.contains(contentType) else { return .refused(.unsupportedType(contentType)) }
        guard let size = await fileSize(sourceURL) else { return .refused(.sourceMissing) }
        guard size <= model.inputs.maxBytes else { return .refused(.tooLarge(maxBytes: model.inputs.maxBytes)) }
        guard editor.mediaAssetsById[asset.id] === asset else { return .refused(.sourceMissing) }

        let sourceAssetId = asset.id
        var input = GenerationInput(prompt: "", model: model.id, duration: 0, aspectRatio: "")
        input.undoActionName = L10n.string("Remove Background")
        let placeholderId = service.generate(
            genInput: input,
            assetType: .image,
            placeholderDuration: Defaults.imageDurationSeconds,
            references: [asset],
            name: prefixedName("Cutout", for: asset),
            folderId: asset.folderId,
            buildParams: { _ in .removeBackground },
            snapshotRefs: { input, uploaded in
                input.imageURLs = uploaded.isEmpty ? nil : uploaded
                input.imageURLAssetIds = [sourceAssetId]
            },
            fileExtension: "png",
            projectURL: editor.projectURL,
            editor: editor
        )
        return .started(placeholderId: placeholderId, estimate: model.estimate)
    }

    @concurrent private static func fileSize(_ url: URL) async -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }
}
