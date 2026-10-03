import Foundation
import Testing
@testable import Lenora

@MainActor @Suite(.timeLimit(.minutes(1)))
struct PublishServiceTests {
    private let exportID = UUID()
    private let twentySeconds = PublishProbe(byteCount: 1_000_000, durationSeconds: 20)

    private func export(_ status: ExportJobStatus = .completed, fileExtension: String = "mp4") -> ExportJob {
        ExportJob(id: exportID, projectID: "p", filename: "cut.\(fileExtension)", source: .manual,
                  outputURL: URL(fileURLWithPath: "/tmp/cut.\(fileExtension)"), createdAt: Date(),
                  status: status, progress: 1, error: nil, warnings: [], lenoraReport: nil)
    }

    private func makeService(_ provider: FakeProvider, catalog: ModelCatalog? = nil, jobs: [ExportJob]? = nil,
                             probe: PublishProbe? = nil) throws -> PublishService {
        let probe = probe ?? twentySeconds
        let catalog = try catalog ?? EditorTestFixture.connectedCatalog("Capabilities.cloudinaryFull")
        let service = PublishService(provider: { provider }, catalog: catalog, probe: { _ in probe })
        let jobs = jobs ?? [export()]
        service.exportJobs = { jobs }
        return service
    }

    /// Resumes when `condition` holds after a change; never sleeps.
    private func waitFor(_ service: PublishService, _ condition: @escaping @MainActor () -> Bool) async {
        if condition() { return }
        await withCheckedContinuation { continuation in
            service.onChange = {
                guard condition() else { return }
                service.onChange = {}
                continuation.resume()
            }
        }
    }

    private func body(_ job: JobRequest) throws -> String {
        String(decoding: try BackendCoding.encoder().encode(job), as: UTF8.self)
    }

    @Test func publishUploadsOnceSubmitsAndSettlesReady() async throws {
        let provider = FakeProvider(states: [PublishFixtures.state(.running), PublishFixtures.state(.succeeded, roles: PublishRole.allCases)])
        let service = try makeService(provider)
        let record = try await service.publish(exportJobId: exportID, options: PublishOptions(vertical: "9:16", teaserSeconds: 5), confirmPublic: true)
        #expect(record.status == .uploading)
        await waitFor(service) { service.publications.first?.status == .ready }
        let published = try #require(service.publications.first)
        #expect(published.assetRef == "ref-cut.mp4" && published.jobId == "fake:1")
        #expect(published.outputs.allSatisfy { $0.status == .ready && $0.url != nil })
        #expect(await provider.uploads == ["ref-cut.mp4"])
        let (job, _) = try #require(await provider.submitted.first)
        #expect(job.kind == "video.publish" && job.inputs == [.assetRef("ref-cut.mp4")])
        #expect(try body(job).contains(#""params":{"outputs":{"teaserSeconds":5,"vertical":"9:16"}}"#))
    }

    enum Refused: CaseIterable, Sendable { case unconfirmed, notCompleted, notVideo, unknownExport, tooLarge, teaserTooLong, badAspect, unavailable, unreadable }

    @Test(arguments: Refused.allCases)
    func refusalsUploadNothingAndLeaveNoRecord(_ refused: Refused) async throws {
        let provider = FakeProvider(states: [])
        var jobs = [export()], probe = twentySeconds, options = PublishOptions(), confirm = true
        let expected: PublishRefusal
        switch refused {
        case .unconfirmed: confirm = false; expected = .notConfirmed
        case .notCompleted: jobs = [export(.exporting)]; expected = .exportNotPublishable
        case .notVideo: jobs = [export(fileExtension: "fcpxml")]; expected = .exportNotPublishable
        case .unknownExport: jobs = []; expected = .exportNotPublishable
        case .tooLarge:
            probe = PublishProbe(byteCount: 104_857_601, durationSeconds: 20)
            expected = .tooLarge(byteCount: 104_857_601, maxBytes: 104_857_600)
        case .teaserTooLong:
            probe = PublishProbe(byteCount: 1, durationSeconds: 5); options.teaserSeconds = 5
            expected = .teaserTooLong(5, durationSeconds: 5)
        case .badAspect: options.vertical = "16:9"; expected = .unsupportedAspect("16:9", allowed: ["9:16", "1:1", "4:5"])
        case .unavailable: expected = .unavailable
        case .unreadable: probe = PublishProbe(byteCount: 1, durationSeconds: .nan); expected = .unreadable
        }
        let service = try makeService(provider, catalog: refused == .unavailable ? ModelCatalog() : nil, jobs: jobs, probe: probe)
        let (finalOptions, finalConfirm) = (options, confirm)
        await #expect(throws: expected) {
            try await service.publish(exportJobId: exportID, options: finalOptions, confirmPublic: finalConfirm)
        }
        #expect(service.publications.isEmpty)
        #expect(await provider.uploads.isEmpty)
    }

    @Test func probeFailureRefusesAsUnreadable() async throws {
        let provider = FakeProvider(states: [])
        let catalog = try EditorTestFixture.connectedCatalog("Capabilities.cloudinaryFull")
        let service = PublishService(provider: { provider }, catalog: catalog, probe: { _ in throw CocoaError(.fileReadUnknown) })
        let jobs = [export()]
        service.exportJobs = { jobs }
        await #expect(throws: PublishRefusal.unreadable) {
            try await service.publish(exportJobId: exportID, options: PublishOptions(), confirmPublic: true)
        }
        #expect(service.publications.isEmpty)
        #expect(await provider.uploads.isEmpty)
    }

    @Test func partialResultMarksRecordPartial() async throws {
        let partial = try BackendCoding.decoder().decode(JobState.self, from: ProtocolFixtures.data("JobState.publishPartial"))
        let service = try makeService(FakeProvider(states: [partial]))
        _ = try await service.publish(exportJobId: exportID, options: PublishOptions(vertical: "9:16", teaserSeconds: 15), confirmPublic: true)
        await waitFor(service) { service.publications.first?.status == .partial }
        let teaser = try #require(service.publications.first?.outputs.first { $0.role == .teaser })
        #expect(teaser.status == .failed && teaser.errorCode == "provider_error")
    }

    @Test func failedJobKeepsTheAssetForUnpublish() async throws {
        let provider = FakeProvider(states: [PublishFixtures.state(.failed)])
        let service = try makeService(provider)
        let record = try await service.publish(exportJobId: exportID, options: PublishOptions(), confirmPublic: true)
        await waitFor(service) { service.publications.first?.status == .failed }
        #expect(service.publications.first?.assetRef == "ref-cut.mp4")
        #expect(try await service.unpublish(record.id) == false)
        #expect(await provider.deletedAssets == ["ref-cut.mp4"])
    }

    @Test func lateResultAfterCloseIsNotCommitted() async throws {
        let provider = FakeProvider(states: [PublishFixtures.state(.running)])
        let service = try makeService(provider)
        _ = try await service.publish(exportJobId: exportID, options: PublishOptions(), confirmPublic: true)
        await provider.waitForPoller()
        service.stopMonitoring()
        var changes = 0
        service.onChange = { changes += 1 }
        await provider.emit(PublishFixtures.state(.succeeded, roles: PublishRole.allCases))
        await Task.yield()
        let record = try #require(service.publications.first)
        #expect(record.status != .ready && record.outputs.allSatisfy { $0.url == nil })
        #expect(changes == 0)
    }

    @Test func publishFinishingAfterCloseRecordsNothing() async throws {
        let provider = FakeProvider(states: [])
        let catalog = try EditorTestFixture.connectedCatalog("Capabilities.cloudinaryFull")
        let (probing, probingStarted) = AsyncStream<Void>.makeStream()
        let (release, releaseProbe) = AsyncStream<Void>.makeStream()
        let probe = twentySeconds
        let service = PublishService(provider: { provider }, catalog: catalog, probe: { _ in
            probingStarted.yield()
            for await _ in release { break }
            return probe
        })
        let jobs = [export()]
        service.exportJobs = { jobs }
        let id = exportID
        let publishing = Task { try await service.publish(exportJobId: id, options: PublishOptions(), confirmPublic: true) }
        for await _ in probing { break }
        service.stopMonitoring()
        releaseProbe.yield()
        await #expect(throws: CancellationError.self) { try await publishing.value }
        #expect(service.publications.isEmpty)
        #expect(await provider.uploads.isEmpty)
    }

    @Test func uploadingBecomesFailedOnRestore() async throws {
        let provider = FakeProvider(states: [])
        let service = try makeService(provider)
        var record = PublishFixtures.readyRecord()
        record.status = .uploading
        service.restore([record])
        #expect(service.publications.first?.status == .failed)
        #expect(service.publications.first?.message == "Upload interrupted.")
        #expect(service.publications.first?.assetRef == "a")
        #expect(try await service.unpublish(record.id) == false)
        #expect(service.publications.first?.status == .unpublished)
    }

    @Test func processingResumesOnRestore() async throws {
        let service = try makeService(FakeProvider(states: [PublishFixtures.state(.succeeded, roles: [.stream, .download, .poster])]))
        var record = PublishFixtures.readyRecord()
        record.request(PublishOptions().roles, options: PublishOptions())
        record.status = .processing
        service.restore([record])
        await waitFor(service) { service.publications.first?.status == .ready }
    }

    @Test func addOutputsMakesNoUpload() async throws {
        let provider = FakeProvider(states: [PublishFixtures.state(.succeeded, roles: [.stream, .download, .poster, .vertical])])
        let service = try makeService(provider)
        let record = PublishFixtures.readyRecord()
        service.restore([record])
        let (pending, noop) = try service.addOutputs(to: record.id, options: PublishOptions(vertical: "9:16"), confirmPublic: true)
        #expect(!noop && pending.status == .processing)
        await waitFor(service) { service.publications.first?.status == .ready }
        #expect(service.publications.first?.url(.vertical) != nil)
        #expect(await provider.uploads.isEmpty)
        #expect(await provider.submitted.map(\.0.inputs) == [[.assetRef("a")]])
    }

    @Test func addOutputsRequestsOnlyOutputsThatAreNotReady() async throws {
        let provider = FakeProvider(states: [PublishFixtures.state(.succeeded, roles: [.stream, .download, .poster, .vertical])])
        let service = try makeService(provider)
        let record = PublishFixtures.readyRecord(PublishOptions(teaserSeconds: 5))
        service.restore([record])
        _ = try service.addOutputs(to: record.id, options: PublishOptions(vertical: "9:16"), confirmPublic: true)
        await waitFor(service) { service.publications.first?.status == .ready }
        let (job, _) = try #require(await provider.submitted.first)
        #expect(try body(job).contains(#""params":{"outputs":{"vertical":"9:16"}}"#))
        #expect(service.publications.first?.url(.teaser) != nil)
    }

    @Test func addOutputsRefusesWhenNoOutputIsReady() async throws {
        let provider = FakeProvider(states: [])
        let service = try makeService(provider)
        var record = PublishFixtures.readyRecord()
        record.markUnpublished()
        record.status = .failed
        record.outputs = [PublishedOutput(role: .stream, status: .failed)]
        service.restore([record])
        #expect(!record.canAddOutputs)
        #expect(throws: PublishRefusal.notUploaded) {
            try service.addOutputs(to: record.id, options: PublishOptions(vertical: "9:16"), confirmPublic: true)
        }
        #expect(service.publications == [record])
        #expect(await provider.submitted.isEmpty)
    }

    @Test func addOutputsWithNothingNewIsANoop() async throws {
        let provider = FakeProvider(states: [])
        let service = try makeService(provider)
        let record = PublishFixtures.readyRecord()
        service.restore([record])
        var changes = 0
        service.onChange = { changes += 1 }
        let (unchanged, noop) = try service.addOutputs(to: record.id, options: PublishOptions(), confirmPublic: true)
        #expect(noop && unchanged == record)
        #expect(changes == 0)
        #expect(await provider.submitted.isEmpty)
    }

    @Test func unpublishTwiceIsANoop() async throws {
        let provider = FakeProvider(states: [])
        let service = try makeService(provider)
        let record = PublishFixtures.readyRecord()
        service.restore([record])
        #expect(try await service.unpublish(record.id) == false)
        #expect(try await service.unpublish(record.id) == true)
        #expect(await provider.deletedAssets == ["a"])
        #expect(service.publications.first?.status == .unpublished)
        #expect(service.publications.first?.outputs.allSatisfy { $0.url == nil } == true)
    }

    @Test func unpublishTreatsNotFoundAsDone() async throws {
        let provider = FakeProvider(states: [])
        await provider.setDeleteResult(.failure(.problem(BackendProblem(code: "not_found", detail: nil, status: 404, retryable: false))))
        let service = try makeService(provider)
        let record = PublishFixtures.readyRecord()
        service.restore([record])
        _ = try await service.unpublish(record.id)
        #expect(service.publications.first?.status == .unpublished)
    }

    @Test func unpublishFailureLeavesRecordUnchanged() async throws {
        let provider = FakeProvider(states: [])
        await provider.setDeleteResult(.failure(.problem(BackendProblem(code: "provider_error", detail: nil, status: 502, retryable: false))))
        let service = try makeService(provider)
        let record = PublishFixtures.readyRecord()
        service.restore([record])
        await #expect(throws: BackendError.self) { try await service.unpublish(record.id) }
        #expect(service.publications == [record])
    }

    @Test func unpublishDuringCreateUploadDeletesTheTicketAsset() async throws {
        let provider = FakeProvider(states: [])
        await provider.hold(.createUpload)
        let service = try makeService(provider)
        let record = try await service.publish(exportJobId: exportID, options: PublishOptions(), confirmPublic: true)
        await provider.waitForCalls(.createUpload)
        #expect(try await service.unpublish(record.id) == false)
        await provider.release(.createUpload)
        await provider.waitForCalls(.deleteAsset)
        let unpublished = try #require(service.publications.first)
        #expect(unpublished.status == .unpublished && unpublished.assetRef == nil)
        #expect(await provider.deletedAssets == ["ref-cut.mp4"])
        #expect(await provider.uploads.isEmpty)
        #expect(await provider.submitted.isEmpty)
    }

    @Test func unpublishDuringTransferSubmitsNothingAndDeletesOnce() async throws {
        let provider = FakeProvider(states: [])
        await provider.hold(.upload)
        await provider.hold(.deleteAsset)
        let service = try makeService(provider)
        let record = try await service.publish(exportJobId: exportID, options: PublishOptions(), confirmPublic: true)
        await provider.waitForCalls(.upload)
        let unpublishing = Task { try await service.unpublish(record.id) }
        await provider.release(.upload)
        await provider.waitForCalls(.deleteAsset)
        await provider.release(.deleteAsset)
        #expect(try await unpublishing.value == false)
        #expect(await provider.submitted.isEmpty)
        #expect(await provider.deletedAssets == ["ref-cut.mp4"])
        #expect(service.publications.first?.status == .unpublished)
    }

    @Test func failedUnpublishAfterCancellingAnUploadSettlesTheRecord() async throws {
        let provider = FakeProvider(states: [])
        await provider.hold(.upload)
        await provider.setDeleteResult(.failure(.problem(BackendProblem(code: "provider_error", detail: nil, status: 502, retryable: false))))
        let service = try makeService(provider)
        let record = try await service.publish(exportJobId: exportID, options: PublishOptions(), confirmPublic: true)
        await provider.waitForCalls(.upload)
        let unpublishing = Task { try await service.unpublish(record.id) }
        await provider.release(.upload)
        await #expect(throws: BackendError.self) { try await unpublishing.value }
        let settled = try #require(service.publications.first)
        #expect(settled.status == .failed && settled.assetRef == "ref-cut.mp4")
    }

    @Test func addOutputsClearsTheFinishedJobId() throws {
        let service = try makeService(FakeProvider(states: []))
        let record = PublishFixtures.readyRecord()
        service.restore([record])
        let (pending, _) = try service.addOutputs(to: record.id, options: PublishOptions(vertical: "9:16"), confirmPublic: true)
        #expect(pending.jobId == nil)
    }

    @Test func processingWithoutJobFailsPendingOutputsOnRestore() async throws {
        let provider = FakeProvider(states: [])
        let service = try makeService(provider)
        var record = PublishFixtures.readyRecord()
        record.request([.vertical], options: PublishOptions(vertical: "9:16"))
        record.status = .processing
        record.jobId = nil
        service.restore([record])
        let restored = try #require(service.publications.first)
        #expect(restored.status == .partial && restored.message == "Submit interrupted.")
        #expect(restored.outputs.first { $0.role == .vertical }?.status == .failed)
        #expect(restored.outputs.filter { $0.status == .ready }.count == 3)
        #expect(await provider.pollers == 0)
    }

    @Test func intentsAfterCloseChangeNothing() async throws {
        let provider = FakeProvider(states: [])
        let service = try makeService(provider)
        let ready = PublishFixtures.readyRecord()
        var notUploaded = PublishFixtures.readyRecord()
        notUploaded.assetRef = nil
        notUploaded.status = .failed
        service.restore([ready, notUploaded])
        service.stopMonitoring()
        var changes = 0
        service.onChange = { changes += 1 }
        #expect(throws: CancellationError.self) {
            try service.addOutputs(to: ready.id, options: PublishOptions(vertical: "9:16"), confirmPublic: true)
        }
        await #expect(throws: CancellationError.self) { try await service.unpublish(ready.id) }
        await #expect(throws: CancellationError.self) { try await service.unpublish(notUploaded.id) }
        #expect(service.publications == [ready, notUploaded])
        #expect(changes == 0)
        #expect(await provider.submitted.isEmpty)
        #expect(await provider.deletedAssets.isEmpty)
    }

    @Test func failedAddOutputsSubmitKeepsReadyOutputs() async throws {
        let provider = FakeProvider(states: [], submitError: .problem(BackendProblem(code: "provider_error", detail: nil, status: 502, retryable: false)))
        let service = try makeService(provider)
        let record = PublishFixtures.readyRecord()
        service.restore([record])
        _ = try service.addOutputs(to: record.id, options: PublishOptions(vertical: "9:16"), confirmPublic: true)
        await waitFor(service) { service.publications.first?.status != .processing }
        let settled = try #require(service.publications.first)
        #expect(settled.status == .partial)
        #expect(settled.outputs.first { $0.role == .vertical }?.status == .failed)
        #expect(settled.outputs.filter { $0.status == .ready && $0.url != nil }.count == 3)
    }

    @Test func concurrentUnpublishCommitsOnce() async throws {
        let provider = FakeProvider(states: [])
        await provider.hold(.deleteAsset)
        let service = try makeService(provider)
        let record = PublishFixtures.readyRecord()
        service.restore([record])
        var changes = 0
        service.onChange = { changes += 1 }
        let first = Task { try await service.unpublish(record.id) }
        let second = Task { try await service.unpublish(record.id) }
        await provider.waitForCalls(.deleteAsset, count: 2)
        await provider.release(.deleteAsset)
        let results = [try await first.value, try await second.value]
        #expect(results.sorted { !$0 && $1 } == [false, true])
        #expect(changes == 1)
        #expect(service.publications.first?.status == .unpublished)
    }

    @Test func editorSavesAndRestoresPublications() throws {
        let editor = EditorViewModel(generationProvider: { nil })
        let record = PublishFixtures.readyRecord()
        editor.publishService.restore([record])
        let file = editor.projectFileSnapshot()
        #expect(file.publications == [record])
        let reopened = EditorViewModel(generationProvider: { nil })
        reopened.applyProjectFile(file)
        #expect(reopened.publishService.publications == [record])
    }
}
