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

    func downloadRemoteMedia(
        into asset: MediaAsset,
        from remoteURL: URL,
        fileExtension: String?,
        undoActionName: String? = nil,
        downloader: RemoteMediaDownloader? = nil
    ) async throws {
        let downloader = downloader ?? RemoteMediaDownloader(
            maxBytes: ToolExecutor.remoteImportMaxBytes,
            timeout: ToolExecutor.remoteImportRequestTimeout,
            fetch: remoteDownloadFetch
        )
        let file = try await downloader.download(remoteURL)
        guard mediaAssetsById[asset.id] === asset else {
            await Self.removeFile(file)
            throw CancellationError()
        }
        let ext = (fileExtension ?? remoteURL.pathExtension).lowercased()
        if !ext.isEmpty, ext != asset.url.pathExtension.lowercased(), ClipType(fileExtension: ext) != nil {
            asset.url = asset.url.deletingPathExtension().appendingPathExtension(ext)
        }
        asset.url = try await commitStagedProjectMedia(file, filename: asset.url.lastPathComponent, maxBytes: ToolExecutor.remoteImportMaxBytes)
        guard mediaAssetsById[asset.id] === asset else {
            await Self.removeFile(asset.url)
            throw CancellationError()
        }
        asset.pendingDownloadURL = nil
        importMediaAsset(asset, skipAppend: true)
        let finalized = await finalizeImportedAsset(asset)
        guard mediaAssetsById[asset.id] === asset else {
            mediaManifest.entries.removeAll { $0.id == asset.id }
            await Self.removeFile(asset.url)
            throw CancellationError()
        }
        guard finalized else { throw RemoteDownloadError.unreadableMedia }
        if let undoActionName { registerImportUndo(of: asset, actionName: undoActionName) }
    }

    private func registerImportUndo(of asset: MediaAsset, actionName: String) {
        let before = mediaLibraryUndoSnapshot(removing: asset.id)
        undo.register(actionName, withTarget: self) { editor in
            editor.restoreMediaLibraryUndoSnapshot(before, actionName: actionName)
        }
        onProjectCheckpointRequired?()
    }

    private static func removeFile(_ url: URL) async {
        await Task.detached(priority: .utility) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                Log.project.warning("remote download cleanup failed file=\(url.lastPathComponent) error=\(error.localizedDescription)")
            }
        }.value
    }
}
