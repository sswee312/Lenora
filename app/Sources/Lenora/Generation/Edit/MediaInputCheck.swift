import Foundation
import UniformTypeIdentifiers

enum MediaInputCheck {
    struct Source: Sendable {
        let url: URL
        let width: Int?
        let height: Int?
    }

    @concurrent static func refusal(for source: Source, limits: BackendInputLimits) async -> MediaEditRefusal? {
        let contentType = ImageConverter.requiresConversion(source.url)
            ? "image/jpeg"
            : UTType(filenameExtension: source.url.pathExtension)?.preferredMIMEType
        guard let contentType, limits.types.contains(contentType) else {
            let shown = contentType
                ?? (source.url.pathExtension.isEmpty ? source.url.lastPathComponent : source.url.pathExtension.uppercased())
            return .unsupportedType(shown)
        }
        guard let size = (try? source.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) else { return .sourceMissing }
        guard size <= limits.maxBytes else { return .tooLarge(maxBytes: limits.maxBytes) }
        if let maxPixels = limits.maxPixels {
            guard let width = source.width, let height = source.height else { return .dimensionsUnknown }
            guard Int64(width) * Int64(height) <= maxPixels else { return .tooManyPixels(maxPixels: maxPixels) }
        }
        return nil
    }
}
