import AppKit
import Foundation
import Testing
@testable import Lenora

@Suite("Project close persistence", .serialized)
@MainActor
struct ProjectClosePersistenceTests {
    @Test func finalSavePersistsSnapshotWhenDocumentIsNotMarkedEdited() async throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-close-\(UUID().uuidString).lenora", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: package) }

        let document = VideoProject()
        document.fileURL = package
        document.fileType = VideoProject.typeIdentifier
        document.editorViewModel.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(start: 0, duration: 30)]),
        ])

        document.save(to: package, ofType: VideoProject.typeIdentifier, for: .saveOperation) { error in
            if let error { Issue.record(error) }
        }
        document.editorViewModel.timeline.tracks[0].clips[0].durationFrames = 90
        #expect(!document.isDocumentEdited)
        try await document.saveBeforeClosing()

        let saved = try VideoProject.readProjectPackage(at: package)
        #expect(saved.projectFile.timelines.first?.tracks.first?.clips.count == 1)
        #expect(saved.projectFile.timelines.first?.tracks.first?.clips.first?.durationFrames == 90)
    }

    @Test func publishingRefusesIntentsOnceTheFinalSaveCompletes() async throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-close-\(UUID().uuidString).lenora", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: package) }
        let document = VideoProject()
        document.fileURL = package
        document.fileType = VideoProject.typeIdentifier
        try await document.saveBeforeClosing()
        await #expect(throws: CancellationError.self) {
            try await document.editorViewModel.publishService.unpublish(UUID())
        }
    }

    @Test func failedFinalSaveReopensPublishing() async throws {
        let document = VideoProject()
        await #expect(throws: (any Error).self) { try await document.saveBeforeClosing() }
        await #expect(throws: PublishRefusal.notFound) {
            try await document.editorViewModel.publishService.unpublish(UUID())
        }
    }

    @Test func canCloseForwardsTheDecisionAfterTheFinalSave() async throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-close-\(UUID().uuidString).lenora", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: package) }
        let document = VideoProject()
        document.fileURL = package
        document.fileType = VideoProject.typeIdentifier
        let shouldClose = await withCheckedContinuation { continuation in
            let spy = CloseDecisionSpy { continuation.resume(returning: $0) }
            document.canClose(withDelegate: spy, shouldClose: #selector(CloseDecisionSpy.document(_:shouldClose:contextInfo:)), contextInfo: nil)
        }
        #expect(shouldClose)
    }
}

private final class CloseDecisionSpy: NSObject {
    private var decided: ((Bool) -> Void)?

    init(_ decided: @escaping (Bool) -> Void) { self.decided = decided }

    @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        decided?(shouldClose)
        decided = nil
    }
}
