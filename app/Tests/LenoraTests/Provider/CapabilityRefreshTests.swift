import Testing
@testable import Lenora

@MainActor
struct CapabilityRefreshTests {
    private func refreshes(after provider: FakeProvider) async throws -> Int {
        let fixture = try await EditorTestFixture.withImage(provider: provider, catalog: EditorTestFixture.connectedCatalog("Capabilities.cloudinaryFull"))
        defer { fixture.cleanup() }
        var refreshes = 0
        fixture.editor.generationService.onCapabilityRefusal = { refreshes += 1 }
        _ = await EditSubmitter.submitEdit(.edit(.restore), asset: fixture.image, editor: fixture.editor)
        await fixture.editor.generationService.waitForIdle()
        return refreshes
    }

    @Test func nonRetryableUnavailableSubmitRefreshes() async throws {
        let problem = BackendProblem(code: "provider_unavailable", detail: "add-on missing", status: 503, retryable: false)
        #expect(try await refreshes(after: FakeProvider(submitError: .problem(problem))) == 1)
    }

    @Test func nonRetryableUnavailableJobRefreshes() async throws {
        let failure = JobFailure(code: "provider_unavailable", message: "add-on missing", retryable: false)
        #expect(try await refreshes(after: FakeProvider(states: [jobState(.failed, error: failure)])) == 1)
    }

    @Test(arguments: [("provider_unavailable", true), ("provider_error", false), ("rate_limited", true)])
    func otherFailuresDoNotRefresh(code: String, retryable: Bool) async throws {
        let problem = BackendProblem(code: code, detail: nil, status: 503, retryable: retryable)
        #expect(try await refreshes(after: FakeProvider(submitError: .problem(problem))) == 0)
        let failure = JobFailure(code: code, message: "x", retryable: retryable)
        #expect(try await refreshes(after: FakeProvider(states: [jobState(.failed, error: failure)])) == 0)
    }
}
