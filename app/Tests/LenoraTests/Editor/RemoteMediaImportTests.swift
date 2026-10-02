import AppKit
import Foundation
import Testing
@testable import Lenora

@MainActor
struct RemoteMediaImportTests {
    private let remote = URL(string: "https://res.cloudinary.com/demo/image/upload/x.png")!

    private static let png: Data = {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }()

    private func downloader(status: Int = 200, body: Data = png) -> RemoteMediaDownloader {
        RemoteMediaDownloader(maxBytes: 1_000_000, timeout: 5) { request in
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try body.write(to: file)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
            return (file, response)
        }
    }

    private func makeProject() -> (editor: EditorViewModel, root: URL, media: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "remote-import-\(UUID().uuidString)")
        let editor = EditorViewModel()
        editor.projectURL = root.appending(path: "P.lenora")
        return (editor, root, root.appending(path: "P.lenora/\(Project.mediaDirectoryName)"))
    }

    private func placeholder(_ editor: EditorViewModel, ext: String = "png") -> MediaAsset {
        editor.createRemotePlaceholder(
            projectURL: editor.projectURL!, type: .image, fileExtension: ext, displayName: "x", folderId: nil,
            importInput: MediaImportInput(sourceURL: remote.absoluteString, createdAt: Date())
        )
    }

    @Test(arguments: [
        ("jpg", "https://a.example/x.png", "jpg"),
        ("bin", "https://a.example/x.png", "png"),
        (nil, "https://a.example/x.jpg", "jpg"),
        (nil, "https://a.example/x.bin", "png"),
        (nil, "https://a.example/x", "png"),
    ] as [(String?, String, String)])
    func choosesFileExtension(explicit: String?, remoteURL: String, expected: String) async throws {
        let (editor, root, _) = makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = placeholder(editor)
        try await editor.downloadRemoteMedia(into: asset, from: URL(string: remoteURL)!, fileExtension: explicit, downloader: downloader())
        #expect(asset.url.pathExtension == expected)
        #expect(FileManager.default.fileExists(atPath: asset.url.path))
        #expect(asset.generationStatus == .none)
    }

    @Test func rejectedDownloadThrowsAndCommitsNothing() async throws {
        let (editor, root, media) = makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = placeholder(editor)
        let originalURL = asset.url
        await #expect(throws: RemoteDownloadError.badStatus(404)) {
            try await editor.downloadRemoteMedia(into: asset, from: remote, fileExtension: nil, downloader: downloader(status: 404))
        }
        #expect(asset.url == originalURL)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: media.path)) ?? []).isEmpty)
    }

    @Test func unreadableMediaThrows() async throws {
        let (editor, root, _) = makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = placeholder(editor)
        await #expect(throws: RemoteDownloadError.unreadableMedia) {
            try await editor.downloadRemoteMedia(into: asset, from: remote, fileExtension: nil, downloader: downloader(body: Data("not an image".utf8)))
        }
        #expect(asset.generationStatus == .failed("Could not read media file."))
    }
}
