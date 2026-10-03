import Foundation

enum MediaEditRequest: Equatable, Sendable {
    case removeBackground
    case edit(ImageEditParams)
    case reframe(VideoReframeParams)

    static let fillAspectRatios = ["1:1", "16:9", "9:16", "4:3", "3:4"]
    static let reframeAspectRatios = ["9:16", "1:1", "4:5", "16:9"]

    var kind: String {
        switch self {
        case .removeBackground: "image.removeBackground"
        case .edit: "image.edit"
        case .reframe: "video.reframe"
        }
    }

    var mediaType: ClipType {
        if case .reframe = self { return .video }
        return .image
    }

    @MainActor var title: String {
        switch self {
        case .removeBackground: L10n.string("Remove Background")
        case .edit(.fill): L10n.string("Generative Fill")
        case .edit(.replace): L10n.string("Replace")
        case .edit(.remove): L10n.string("Remove")
        case .edit(.recolor): L10n.string("Recolor")
        case .edit(.backgroundReplace): L10n.string("Replace Background")
        case .edit(.restore): L10n.string("Restore")
        case .reframe: L10n.string("Reframe")
        }
    }

    static func isURLSafe(_ text: String) -> Bool {
        text.wholeMatch(of: /[A-Za-z0-9 .'\-]{1,100}/) != nil
    }

    func invalidField() -> (field: String, reason: String)? {
        let unsafe = "Use 1–100 letters, digits, spaces or . ' -"
        switch self {
        case .removeBackground, .edit(.restore):
            return nil
        case .edit(.fill(let aspectRatio)):
            return Self.fillAspectRatios.contains(aspectRatio) ? nil : ("aspectRatio", "Use one of \(Self.fillAspectRatios.joined(separator: ", "))")
        case .edit(.replace(let from, let to)):
            if !Self.isURLSafe(from) { return ("from", unsafe) }
            return Self.isURLSafe(to) ? nil : ("to", unsafe)
        case .edit(.remove(let prompt)):
            return Self.isURLSafe(prompt) ? nil : ("prompt", unsafe)
        case .edit(.recolor(let prompt, let color)):
            if !Self.isURLSafe(prompt) { return ("prompt", unsafe) }
            return color.wholeMatch(of: /#[0-9A-Fa-f]{6}/) != nil ? nil : ("color", "Use #RRGGBB")
        case .edit(.backgroundReplace(let prompt)):
            return prompt.map(Self.isURLSafe) == false ? ("prompt", unsafe) : nil
        case .reframe(let params):
            return Self.reframeAspectRatios.contains(params.aspectRatio) ? nil : ("aspectRatio", "Use one of \(Self.reframeAspectRatios.joined(separator: ", "))")
        }
    }
}

enum MediaEditRefusal: Equatable {
    case unavailable(kind: String)
    case operationUnavailable(String)
    case wrongMediaType(ClipType)
    case invalidParameter(field: String, reason: String)
    case unsupportedType(String)
    case tooLarge(maxBytes: Int64)
    case tooManyPixels(maxPixels: Int64)
    case dimensionsUnknown
    case sourceMissing

    var code: String {
        switch self {
        case .unavailable, .operationUnavailable: "unsupported_kind"
        case .wrongMediaType, .invalidParameter, .unsupportedType, .dimensionsUnknown, .sourceMissing: "invalid_request"
        case .tooLarge, .tooManyPixels: "input_too_large"
        }
    }

    @MainActor var userMessage: String {
        switch self {
        case .unavailable, .operationUnavailable: L10n.string("The connected backend doesn't offer this edit. Open Settings → Backend.")
        case .wrongMediaType(.video): L10n.string("This edit works on videos only.")
        case .wrongMediaType: L10n.string("This edit works on images only.")
        case .invalidParameter(_, let reason): reason
        case .unsupportedType(let type): L10n.string("\(type) files aren't supported by this edit.")
        case .tooLarge(let max): L10n.string("The file is larger than \(ByteCountFormatter.string(fromByteCount: max, countStyle: .file)).")
        case .tooManyPixels(let max): L10n.string("The image is larger than \(max) pixels in total.")
        case .dimensionsUnknown: L10n.string("The image size isn't known yet. Try again in a moment.")
        case .sourceMissing: L10n.string("The source file is missing.")
        }
    }

    var toolMessage: String {
        switch self {
        case .unavailable(let kind): "No connected backend supports \(kind). Tell the user to connect one in Settings → Backend."
        case .operationUnavailable(let op): "The connected backend does not offer operation \(op)."
        case .wrongMediaType(let type): "This operation needs a \(type.rawValue) asset."
        case .invalidParameter(let field, let reason): "Invalid \(field): \(reason)."
        case .unsupportedType(let type): "Unsupported file type \(type)."
        case .tooLarge(let max): "File exceeds the \(max)-byte limit."
        case .tooManyPixels(let max): "Image exceeds the \(max)-pixel limit."
        case .dimensionsUnknown: "Image dimensions are not loaded yet; retry shortly."
        case .sourceMissing: "The source file is missing or offline."
        }
    }
}

enum MediaEditOutcome: Equatable {
    case started(placeholderId: String, estimate: BackendEstimate?)
    case refused(MediaEditRefusal)
}
