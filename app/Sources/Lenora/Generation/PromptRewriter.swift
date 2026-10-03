import Foundation
import Observation

enum PromptRewriteFailure: Error, Equatable, Sendable {
    case noResult
    case backend(String)

    @MainActor var userMessage: String {
        switch self {
        case .noResult: L10n.string("Couldn't improve the prompt.")
        case .backend(let detail): L10n.string("Couldn't improve the prompt: \(detail)")
        }
    }
}

/// Rewrites a generation prompt through the backend's `text.rewritePrompt` model.
@Observable @MainActor
final class PromptRewriter {
    enum Phase: Equatable { case idle, rewriting, failed(PromptRewriteFailure) }

    static let kind = "text.rewritePrompt"

    private(set) var phase: Phase = .idle
    @ObservationIgnored private let provider: @MainActor () -> (any GenerationProvider)?
    @ObservationIgnored private let catalog: ModelCatalog
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var sentText: String?

    init(provider: @escaping @MainActor () -> (any GenerationProvider)?, catalog: ModelCatalog) {
        self.provider = provider
        self.catalog = catalog
    }

    var isAvailable: Bool { model != nil }

    private var model: BackendModel? { catalog.models(ofKind: Self.kind).first }

    /// Applies the rewrite only if `current()` still returns `text` when the result arrives.
    @discardableResult
    func rewrite(_ text: String, targetKind: String, current: @escaping @MainActor () -> String,
                 apply: @escaping @MainActor (String) -> Void) -> Task<Void, Never>? {
        guard phase != .rewriting, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let model, let provider = provider() else { return nil }
        let job = JobRequest(kind: Self.kind, model: model.id, inputs: [],
                             params: RewritePromptParams(text: text, targetKind: targetKind))
        phase = .rewriting
        sentText = text
        let task = Task { [weak self] in
            let outcome = await Self.run(job, provider: provider)
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            self.sentText = nil
            switch outcome {
            case .success(let rewritten):
                self.phase = .idle
                if current() == text { apply(rewritten) }
            case .failure(let failure):
                self.phase = .failed(failure)
            }
        }
        self.task = task
        return task
    }

    /// Local only: a submitted rewrite still runs, and is billed, on the backend.
    func cancel() {
        task?.cancel()
        task = nil
        sentText = nil
        phase = .idle
    }

    func fieldDidChange(_ text: String) {
        switch phase {
        case .rewriting where text != sentText: cancel()
        case .failed: phase = .idle
        case .idle, .rewriting: break
        }
    }

    private static func run(_ job: JobRequest, provider: any GenerationProvider) async -> Result<String, PromptRewriteFailure> {
        do {
            let submitted = try await provider.submit(job, idempotencyKey: UUID().uuidString)
            for try await state in provider.jobUpdates(jobId: submitted.jobId) where state.status.isTerminal {
                if state.status == .succeeded, let text = state.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    return .success(text)
                }
                return .failure(state.error.map { .backend($0.message) } ?? .noResult)
            }
            return .failure(.noResult)
        } catch {
            return .failure(.backend(error.localizedDescription))
        }
    }
}
