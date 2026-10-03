import Foundation
import Testing
@testable import Lenora

@MainActor
struct PromptRewriterTests {
    private func rewriter(_ provider: FakeProvider?, catalog fixture: String = "Capabilities.openai") throws -> PromptRewriter {
        PromptRewriter(provider: { provider }, catalog: try EditorTestFixture.connectedCatalog(fixture))
    }

    private func start(_ rewriter: PromptRewriter, _ field: Box<String>, target: String = "image.generate") -> Task<Void, Never>? {
        rewriter.rewrite(field.value, targetKind: target, current: { field.value }, apply: { field.value = $0 })
    }

    @Test func replacesTheFieldWithTheRewrite() async throws {
        let provider = FakeProvider(states: [jobState(.succeeded, text: "A black cat at night.")])
        let rewriter = try rewriter(provider)
        let field = Box("a cat")
        await start(rewriter, field)?.value
        #expect(field.value == "A black cat at night." && rewriter.phase == .idle)
        let job = try #require(await provider.submitted.first?.0)
        #expect(job.kind == "text.rewritePrompt" && job.model == "openai/rewrite")
        #expect(job.params as? RewritePromptParams == RewritePromptParams(text: "a cat", targetKind: "image.generate"))
    }

    @Test func dropsTheResultWhenTheFieldChangedMeanwhile() async throws {
        let rewriter = try rewriter(FakeProvider(states: [jobState(.succeeded, text: "A black cat.")]))
        let field = Box("a cat")
        await rewriter.rewrite("a cat", targetKind: "image.generate", current: { "a cat on a roof" }, apply: { field.value = $0 })?.value
        #expect(field.value == "a cat" && rewriter.phase == .idle)
    }

    @Test func editingTheFieldCancelsThePendingRewrite() async throws {
        let provider = FakeProvider(states: [jobState(.running)])
        let rewriter = try rewriter(provider)
        let field = Box("a cat")
        let task = start(rewriter, field)
        try await provider.waitForPoller()
        field.value = "a dog"
        rewriter.fieldDidChange(field.value)
        await provider.emit(jobState(.succeeded, text: "A golden retriever."))
        await task?.value
        #expect(field.value == "a dog" && rewriter.phase == .idle)
    }

    @Test func cancelLeavesTheFieldAlone() async throws {
        let provider = FakeProvider(states: [jobState(.running)])
        let rewriter = try rewriter(provider)
        let field = Box("a cat")
        let task = start(rewriter, field)
        try await provider.waitForPoller()
        rewriter.cancel()
        await provider.emit(jobState(.succeeded, text: "A black cat."))
        await task?.value
        #expect(field.value == "a cat" && rewriter.phase == .idle)
    }

    @Test func backendRefusalIsShownUntilTheFieldChanges() async throws {
        let refusal = BackendProblem(code: "quota_exceeded", detail: "The daily budget is reached.", status: 429, retryable: false)
        let rewriter = try rewriter(FakeProvider(submitError: .problem(refusal)))
        let field = Box("a cat")
        await start(rewriter, field)?.value
        #expect(rewriter.phase == .failed(.backend("The daily budget is reached.")) && field.value == "a cat")
        rewriter.fieldDidChange("a cat!")
        #expect(rewriter.phase == .idle)
    }

    @Test(arguments: [
        (jobState(.failed, error: JobFailure(code: "provider_error", message: "No rewrite.", retryable: true)), PromptRewriteFailure.backend("No rewrite.")),
        (jobState(.succeeded), PromptRewriteFailure.noResult),
        (jobState(.succeeded, text: "  "), PromptRewriteFailure.noResult),
    ])
    func terminalStatesWithoutTextFail(state: JobState, failure: PromptRewriteFailure) async throws {
        let rewriter = try rewriter(FakeProvider(states: [state]))
        let field = Box("a cat")
        await start(rewriter, field)?.value
        #expect(rewriter.phase == .failed(failure) && field.value == "a cat")
    }

    @Test func doesNothingWithoutARewriteModelOrText() async throws {
        let provider = FakeProvider()
        let unavailable = try rewriter(provider, catalog: "Capabilities.cloudinary")
        #expect(!unavailable.isAvailable)
        #expect(start(unavailable, Box("a cat")) == nil)
        #expect(start(try rewriter(provider), Box("  \n")) == nil)
        #expect(await provider.submitted.isEmpty)
    }
}
