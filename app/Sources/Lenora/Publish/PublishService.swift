import Foundation

/// Owns this project's publications; the only code that changes them.
@MainActor @Observable
final class PublishService {
    nonisolated static let kind = "video.publish"

    private(set) var publications: [Publication] = []
    @ObservationIgnored var exportJobs: @MainActor () -> [ExportJob] = { [] }
    @ObservationIgnored var onChange: @MainActor () -> Void = {}

    private let provider: @MainActor () -> (any GenerationProvider)?
    private let catalog: ModelCatalog
    private let probe: @Sendable (URL) async throws -> PublishProbe
    @ObservationIgnored private var runs: [UUID: Run] = [:]
    @ObservationIgnored private var deletesInFlight: [UUID: Int] = [:]
    @ObservationIgnored private var isOpen = true

    private struct Run {
        let token: UUID
        let task: Task<Void, Never>
    }

    init(
        provider: @escaping @MainActor () -> (any GenerationProvider)?,
        catalog: ModelCatalog = .shared,
        probe: @escaping @Sendable (URL) async throws -> PublishProbe = { try await PublishProbe.read($0) }
    ) {
        self.provider = provider
        self.catalog = catalog
        self.probe = probe
    }

    var model: BackendModel? { catalog.models(ofKind: Self.kind).first }
    var limits: PublishLimits? { model.flatMap(PublishLimits.init(model:)) }
    var isAvailable: Bool { limits != nil }

    func canPublish(_ job: ExportJob) -> Bool {
        guard job.status == .completed, let contentType = job.videoContentType else { return false }
        return model?.inputs.types.contains(contentType) == true
    }

    // MARK: - Intents

    func publish(exportJobId: UUID, options: PublishOptions, confirmPublic: Bool) async throws -> Publication {
        guard isOpen else { throw CancellationError() }
        guard confirmPublic else { throw PublishRefusal.notConfirmed }
        guard let model, let limits else { throw PublishRefusal.unavailable }
        guard let job = exportJobs().first(where: { $0.id == exportJobId }), canPublish(job),
              let contentType = job.videoContentType
        else { throw PublishRefusal.exportNotPublishable }
        let probed: PublishProbe
        do { probed = try await probe(job.outputURL) } catch { throw PublishRefusal.unreadable }
        guard isOpen else { throw CancellationError() }
        if let refusal = limits.refusal(for: options, probe: probed, maxBytes: model.inputs.maxBytes) { throw refusal }

        var record = Publication(id: UUID(), exportFilename: job.filename, createdAt: Date(), model: model.id,
                                 durationSeconds: probed.durationSeconds, options: options, status: .uploading, outputs: [])
        record.request(options.roles, options: options)
        publications.append(record)
        onChange()
        let id = record.id, file = job.outputURL
        start(id) { service, token in
            await service.upload(id, file: file, contentType: contentType, byteCount: probed.byteCount, token: token)
        }
        return record
    }

    func addOutputs(to id: UUID, options: PublishOptions, confirmPublic: Bool) throws -> (publication: Publication, noop: Bool) {
        guard isOpen else { throw CancellationError() }
        guard confirmPublic else { throw PublishRefusal.notConfirmed }
        guard let limits else { throw PublishRefusal.unavailable }
        guard let index = publications.firstIndex(where: { $0.id == id }) else { throw PublishRefusal.notFound }
        let record = publications[index]
        guard record.status != .unpublished else { throw PublishRefusal.unpublished }
        guard record.status != .uploading, record.status != .processing, deletesInFlight[id] == nil
        else { throw PublishRefusal.busy }
        guard record.canAddOutputs else { throw PublishRefusal.notUploaded }
        let merged = record.options.merging(options)
        let known = PublishProbe(byteCount: 0, durationSeconds: record.durationSeconds)
        if let refusal = limits.refusal(for: merged, probe: known, maxBytes: nil) { throw refusal }
        let roles = record.rolesToRequest(for: merged)
        guard !roles.isEmpty else { return (record, true) }
        guard let provider = provider() else { throw PublishRefusal.unavailable }

        publications[index].request(roles, options: merged)
        publications[index].status = .processing
        publications[index].jobId = nil
        onChange()
        start(id) { service, token in await service.submit(id, provider: provider, token: token) }
        return (publications[index], false)
    }

    /// Returns true when the publication was already unpublished.
    func unpublish(_ id: UUID) async throws -> Bool {
        guard isOpen else { throw CancellationError() }
        guard let record = publication(id) else { throw PublishRefusal.notFound }
        guard record.status != .unpublished else { return true }
        if let assetRef = record.assetRef {
            guard let provider = provider() else { throw PublishRefusal.unavailable }
            // The run is stopped first so a finishing transfer can't queue billed outputs for a deleted asset.
            let run = runs.removeValue(forKey: id)
            run?.task.cancel()
            await run?.task.value
            deletesInFlight[id, default: 0] += 1
            defer { deletesInFlight[id] = deletesInFlight[id].flatMap { $0 > 1 ? $0 - 1 : nil } }
            do {
                try await provider.deleteAsset(model: record.model, assetRef: assetRef)
            } catch BackendError.problem(let problem) where problem.code == "not_found" {
            } catch {
                if run != nil { settleInterrupted(id) }
                throw error
            }
            guard isOpen else { throw CancellationError() }
        } else {
            runs.removeValue(forKey: id)?.task.cancel()
        }
        guard let index = publications.firstIndex(where: { $0.id == id }) else { throw PublishRefusal.notFound }
        guard publications[index].status != .unpublished else { return true }
        publications[index].markUnpublished()
        onChange()
        return false
    }

    // MARK: - Lifecycle

    func restore(_ records: [Publication]) {
        stopMonitoring()
        isOpen = true
        publications = records.map(Self.settledAfterInterruption)
        resumeMonitoring()
    }

    private static func settledAfterInterruption(_ record: Publication) -> Publication {
        var settled = record
        if record.status == .uploading {
            settled.markFailed(.uploadInterrupted)
        } else if record.status == .processing, record.jobId == nil {
            settled.failPendingOutputs(.submitInterrupted)
        }
        return settled
    }

    /// An unpublish that stopped a run but then failed leaves the record as restore would find it.
    private func settleInterrupted(_ id: UUID) {
        guard isOpen, let index = publications.firstIndex(where: { $0.id == id }) else { return }
        publications[index] = Self.settledAfterInterruption(publications[index])
        onChange()
        resumeMonitoring()
    }

    func resumeMonitoring() {
        guard isOpen, let provider = provider() else { return }
        for record in publications where record.status == .processing && runs[record.id] == nil {
            guard let jobId = record.jobId else { continue }
            let id = record.id
            start(id) { service, token in await service.monitor(id, jobId: jobId, provider: provider, token: token) }
        }
    }

    func stopMonitoring() {
        runs.values.forEach { $0.task.cancel() }
        runs.removeAll()
        isOpen = false
    }

    // MARK: - Runs

    private func upload(_ id: UUID, file: URL, contentType: String, byteCount: Int64, token: UUID) async {
        guard let provider = provider(), let model = publication(id)?.model else {
            return fail(id, token: token, .backendUnavailable)
        }
        do {
            let ticket = try await provider.createUpload(
                model: model, contentType: contentType, byteCount: byteCount, filename: file.lastPathComponent
            )
            // Recorded before the transfer so an interrupted upload can still be unpublished.
            guard commit(id, token: token, { $0.assetRef = ticket.assetRef }) else {
                return discardAsset(ticket.assetRef, model: model, provider: provider)
            }
            try await provider.upload(file, ticket: ticket)
            await submit(id, provider: provider, token: token)
        } catch {
            fail(id, token: token, PublishFailure(error))
        }
    }

    private func submit(_ id: UUID, provider: any GenerationProvider, token: UUID) async {
        guard runs[id]?.token == token, let record = publication(id), let assetRef = record.assetRef else { return }
        let pending = Set(record.outputs.filter { $0.status == .pending }.map(\.role))
        let params = VideoPublishParams(PublishOptions(
            vertical: pending.contains(.vertical) ? record.options.vertical : nil,
            teaserSeconds: pending.contains(.teaser) ? record.options.teaserSeconds : nil
        ))
        let job = JobRequest(kind: Self.kind, model: record.model, inputs: [.assetRef(assetRef)], params: params)
        do {
            let submitted = try await provider.submit(job, idempotencyKey: UUID().uuidString)
            guard commit(id, token: token, {
                $0.jobId = submitted.jobId
                $0.estimate = submitted.estimate
                $0.status = .processing
            }) else { return }
            await monitor(id, jobId: submitted.jobId, provider: provider, token: token)
        } catch {
            fail(id, token: token, PublishFailure(error))
        }
    }

    private func monitor(_ id: UUID, jobId: String, provider: any GenerationProvider, token: UUID) async {
        do {
            for try await state in provider.jobUpdates(jobId: jobId) {
                guard commit(id, token: token, { $0.apply(state) }) else { return }
            }
        } catch let error as BackendError where error.isTransient {
            // Stays processing; resumeMonitoring picks it up after the backend reconnects.
        } catch {
            fail(id, token: token, PublishFailure(error))
        }
    }

    private func start(_ id: UUID, _ work: @escaping @MainActor (PublishService, UUID) async -> Void) {
        runs[id]?.task.cancel()
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await work(self, token)
            if runs[id]?.token == token { runs[id] = nil }
        }
        runs[id] = Run(token: token, task: task)
    }

    /// Applies a run's result only while that run is current and the record exists.
    @discardableResult
    private func commit(_ id: UUID, token: UUID, _ change: (inout Publication) -> Void) -> Bool {
        guard runs[id]?.token == token, let index = publications.firstIndex(where: { $0.id == id }) else { return false }
        change(&publications[index])
        onChange()
        return true
    }

    private func fail(_ id: UUID, token: UUID, _ failure: PublishFailure) {
        commit(id, token: token) { $0.failPendingOutputs(failure) }
    }

    /// Best effort: deletes an asset whose run went stale, outside the cancelled run.
    private func discardAsset(_ assetRef: String, model: String, provider: any GenerationProvider) {
        Task {
            do { try await provider.deleteAsset(model: model, assetRef: assetRef) }
            catch { Log.generation.warning("publish orphan delete failed asset=\(assetRef) error=\(Log.detail(error))") }
        }
    }

    private func publication(_ id: UUID) -> Publication? {
        publications.first { $0.id == id }
    }
}
