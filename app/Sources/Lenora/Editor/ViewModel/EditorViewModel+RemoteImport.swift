import Foundation

extension EditorViewModel {
    func createRemotePlaceholder(
        projectURL: URL,
        type: ClipType,
        fileExtension: String,
        displayName: String,
        folderId: String?,
        importInput: MediaImportInput
    ) -> MediaAsset {
        let id = UUID().uuidString
        let mediaDir = projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        let destURL = mediaDir.appendingPathComponent("imported-\(id.prefix(8)).\(fileExtension)")
        let placeholder = MediaAsset(id: id, url: destURL, type: type, name: displayName)
        placeholder.folderId = folderId
        placeholder.importInput = importInput
        placeholder.generationStatus = .downloading
        importMediaAsset(placeholder)
        onProjectCheckpointRequired?()
        return placeholder
    }

    func downloadRemoteMedia(into asset: MediaAsset, from remoteURL: URL, fileExtension: String?) async throws {
        let downloader = RemoteMediaDownloader(maxBytes: ToolExecutor.remoteImportMaxBytes, timeout: ToolExecutor.remoteImportRequestTimeout)
        let file = try await downloader.download(remoteURL)
        let ext = (fileExtension ?? remoteURL.pathExtension).lowercased()
        if !ext.isEmpty, ext != asset.url.pathExtension.lowercased(), ClipType(fileExtension: ext) != nil {
            asset.url = asset.url.deletingPathExtension().appendingPathExtension(ext)
        }
        asset.url = try await commitStagedProjectMedia(file, filename: asset.url.lastPathComponent, maxBytes: ToolExecutor.remoteImportMaxBytes)
        asset.pendingDownloadURL = nil
        importMediaAsset(asset, skipAppend: true)
        await finalizeImportedAsset(asset)
    }
}
