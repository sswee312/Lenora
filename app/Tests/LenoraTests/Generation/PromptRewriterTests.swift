import AppKit
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
        field.value = "a cat"
        await provider.emit(jobState(.succeeded, text: "A golden retriever."))
        await task?.value
        #expect(field.value == "a cat" && rewriter.phase == .idle)
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

    @Test func refusesTextOverTheProtocolLimit() throws {
        let provider = FakeProvider()
        let rewriter = try rewriter(provider)
        #expect(rewriter.canRewrite(String(repeating: "a", count: PromptRewriter.maxTextLength)))
        #expect(!rewriter.canRewrite(String(repeating: "a", count: PromptRewriter.maxTextLength + 1)))
        #expect(start(rewriter, Box(String(repeating: "a", count: PromptRewriter.maxTextLength + 1))) == nil)
    }

    @Test func scalarCountDecidesTheLimit() throws {
        let rewriter = try rewriter(FakeProvider())
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let text = String(repeating: family, count: PromptRewriter.maxTextLength / 5 + 1)
        #expect(text.count <= PromptRewriter.maxTextLength && text.unicodeScalars.count > PromptRewriter.maxTextLength)
        #expect(!rewriter.canRewrite(text))
    }

    @Test func maxTextLengthMatchesTheProtocolSchema() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "protocol/openapi.yaml")
        let yaml = try await Task.detached { try String(contentsOf: url, encoding: .utf8) }.value
        let schema = try #require(yaml.components(separatedBy: "    RewritePromptParams:").last)
        let line = try #require(schema.split(separator: "\n").first { $0.contains("text: {") })
        #expect(line.contains("maxLength: \(PromptRewriter.maxTextLength) "))
    }

    @Test func onlyTheFocusedPromptEditorReceivesTheRewrite() {
        let prompt = NSTextView()
        prompt.string = "a cat"
        let other = NSTextView()
        other.string = "a cat"
        let pick = { (focused: Bool, responder: NSResponder?, sent: String) in
            PromptRewriter.promptTextView(promptFocused: focused, firstResponder: responder, sentText: sent)
        }
        #expect(pick(true, prompt, "a cat") === prompt)
        #expect(pick(false, other, "a cat") == nil)
        #expect(pick(true, prompt, "a dog") == nil)
        #expect(pick(true, NSView(), "a cat") == nil)
        #expect(pick(true, nil, "a cat") == nil)
    }

    @Test func textViewReplacementUndoesInOneStep() {
        let undo = UndoManager()
        let delegate = UndoDelegate(undo)
        let view = NSTextView()
        view.allowsUndo = true
        view.delegate = delegate
        view.string = "a cat"
        PromptRewriter.replaceText(in: view, with: "A black cat.")
        #expect(view.string == "A black cat.")
        undo.undo()
        #expect(view.string == "a cat")
    }
}

private final class UndoDelegate: NSObject, NSTextViewDelegate {
    let manager: UndoManager
    init(_ manager: UndoManager) { self.manager = manager }
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
}
