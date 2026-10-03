import AppKit
import Foundation
@testable import Lenora

@MainActor
struct EditorTestFixture {
    struct Timeout: Error {}

    static let servedImageURL = URL(string: "https://res.cloudinary.com/demo/image/upload/served.png")!

    let editor: EditorViewModel
    let image: MediaAsset
    private let root: URL

    var servedImageURL: URL { Self.servedImageURL }

    static func withImage(editor: EditorViewModel = EditorViewModel()) async throws -> EditorTestFixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "generation-\(UUID().uuidString)")
        let project = root.appending(path: "P.lenora")
        let media = project.appending(path: Project.mediaDirectoryName)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let png = pngData()
        let sourceURL = media.appending(path: "source.png")
        try png.write(to: sourceURL)

        editor.projectURL = project
        editor.remoteDownloadFetch = { request in
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try png.write(to: file)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
            return (file, response)
        }
        let image = editor.addMediaAsset(from: sourceURL, type: .image, finalize: false)
        return EditorTestFixture(editor: editor, image: image, root: root)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            guard ContinuousClock.now < deadline else { throw Timeout() }
            await Task.yield()
        }
    }

    func addGeneratingPlaceholder(jobId: String, fileExtension: String) -> MediaAsset {
        var input = GenerationInput(prompt: "", model: "cloudinary/background-removal", duration: 0, aspectRatio: "")
        input.jobId = jobId
        let placeholder = MediaAsset(
            url: editor.projectURL!.appending(path: "\(Project.mediaDirectoryName)/gen-resume.\(fileExtension)"),
            type: .image, name: "Remove Background", generationInput: input
        )
        placeholder.generationStatus = .generating
        editor.importMediaAsset(placeholder)
        return placeholder
    }

    func isFinalized(_ asset: MediaAsset) -> Bool {
        !asset.isGenerating && asset.generationStatus == .none && FileManager.default.fileExists(atPath: asset.url.path)
    }

    private static func pngData() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }
}
