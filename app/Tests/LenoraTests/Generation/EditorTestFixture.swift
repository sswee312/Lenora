import AppKit
import Foundation
@testable import Lenora

@MainActor
struct EditorTestFixture {
    struct Timeout: Error {}

    static let servedImageURL = URL(string: "https://res.cloudinary.com/demo/image/upload/served.png")!

    let editor: EditorViewModel
    let image: MediaAsset
    let video: MediaAsset?
    let executor: ToolExecutor
    let undoManager: UndoManager
    private let root: URL

    var servedImageURL: URL { Self.servedImageURL }

    static func connectedCatalog(_ fixture: String = "Capabilities.cloudinary") throws -> ModelCatalog {
        let catalog = ModelCatalog()
        catalog.apply(try BackendCoding.decoder().decode(BackendCapabilities.self, from: ProtocolFixtures.data(fixture)))
        return catalog
    }

    static func withImage(
        editor: EditorViewModel? = nil,
        byteCount: Int? = nil,
        fileExtension: String = "png",
        width: Int = 4,
        height: Int = 4,
        provider: (any GenerationProvider)? = nil,
        catalog: ModelCatalog = ModelCatalog()
    ) async throws -> EditorTestFixture {
        let editor = editor ?? EditorViewModel(generationProvider: { provider }, modelCatalog: catalog)
        let fixture = try make(editor: editor, byteCount: byteCount, fileExtension: fileExtension, width: width, height: height, includesVideo: false)
        fixture.image.sourceWidth = width
        fixture.image.sourceHeight = height
        return fixture
    }

    static func withVideo(provider: (any GenerationProvider)? = nil, catalog: ModelCatalog = ModelCatalog()) async throws -> EditorTestFixture {
        let editor = EditorViewModel(generationProvider: { provider }, modelCatalog: catalog)
        return try make(editor: editor, byteCount: nil, fileExtension: "png", width: 4, height: 4, includesVideo: true)
    }

    private static func make(
        editor: EditorViewModel,
        byteCount: Int?,
        fileExtension: String,
        width: Int,
        height: Int,
        includesVideo: Bool
    ) throws -> EditorTestFixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "generation-\(UUID().uuidString)")
        let project = root.appending(path: "P.lenora")
        let media = project.appending(path: Project.mediaDirectoryName)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let png = imageData(fileExtension: "png")
        var sourceData = imageData(fileExtension: fileExtension, width: width, height: height)
        if let byteCount, sourceData.count < byteCount {
            sourceData.append(Data(count: byteCount - sourceData.count))
        }
        let sourceURL = media.appending(path: "source.\(fileExtension)")
        try sourceData.write(to: sourceURL)

        editor.projectURL = project
        editor.remoteDownloadFetch = { request in
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try png.write(to: file)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
            return (file, response)
        }
        let undoManager = UndoManager()
        editor.undo.attach(undoManager)
        let image = editor.addMediaAsset(from: sourceURL, type: .image, finalize: false)
        var video: MediaAsset?
        if includesVideo {
            let videoURL = media.appending(path: "clip.mp4")
            try Data(count: 16).write(to: videoURL)
            video = editor.addMediaAsset(from: videoURL, type: .video, finalize: false)
        }
        return EditorTestFixture(
            editor: editor, image: image, video: video,
            executor: ToolExecutor(editor: editor, exportQueue: ExportQueue()),
            undoManager: undoManager, root: root
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func waitUntil(timeout: Duration = .seconds(30), _ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            guard ContinuousClock.now < deadline else { throw Timeout() }
            try await Task.sleep(for: .milliseconds(10))
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

    private static func imageData(fileExtension: String, width: Int = 4, height: Int = 4) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let type: NSBitmapImageRep.FileType = switch fileExtension {
        case "gif": .gif
        case "jpg", "jpeg": .jpeg
        case "tif", "tiff": .tiff
        default: .png
        }
        return rep.representation(using: type, properties: [:])!
    }
}
