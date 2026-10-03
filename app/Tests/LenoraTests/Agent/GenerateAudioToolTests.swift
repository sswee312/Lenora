import Foundation
import Testing
@testable import Lenora

@MainActor
struct GenerateAudioToolTests {
    private static let backend = LenoraBackendConfiguration(baseURL: URL(string: "http://127.0.0.1:8787")!, token: "secret-token")
    private static let resultURL = URL(string: "http://127.0.0.1:8787/v1/results/0f1e2d3c4b5a69788796a5b4c3d2e1f0")!

    private func fixture(_ provider: FakeProvider) async throws -> EditorTestFixture {
        try await EditorTestFixture.withImage(provider: provider, catalog: EditorTestFixture.connectedCatalog("Capabilities.openai"))
    }

    private func run(_ fixture: EditorTestFixture, _ args: [String: Any]) async -> ToolResult {
        await fixture.executor.execute(name: "generate_audio", args: args, source: "mcp")
    }

    private func error(in result: ToolResult) throws -> [String: Any] {
        guard case .text(let text) = try #require(result.content.first) else { throw ToolError("expected text") }
        return try #require((try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["error"] as? [String: Any])
    }

    @Test func listedOnlyWhenTheBackendOffersAVoiceModel() throws {
        func names(_ catalog: ModelCatalog) -> [ToolName] { ToolDefinitions.available(ToolDefinitions.all, catalog: catalog).map(\.name) }
        #expect(names(try EditorTestFixture.connectedCatalog("Capabilities.openai")).contains(.generateAudio))
        #expect(!names(try EditorTestFixture.connectedCatalog()).contains(.generateAudio))
    }

    @Test func submitsTheProtocolSpeechRequest() async throws {
        let provider = FakeProvider(states: [jobState(.running)])
        let fixture = try await fixture(provider)
        defer { fixture.cleanup() }
        let result = await run(fixture, ["prompt": "Welcome back.", "voice": "nova", "styleInstructions": "Warm."])
        try #require(!result.isError)
        try await provider.waitForPoller()
        let job = try #require(await provider.submitted.first?.0)
        let encoded = try JSONSerialization.jsonObject(with: BackendCoding.encoder().encode(job)) as? NSDictionary
        #expect(encoded == ["kind": "audio.speech", "model": "openai/voice", "inputs": [],
                            "params": ["prompt": "Welcome back.", "voice": "nova", "styleInstructions": "Warm."]] as NSDictionary)
    }

    @Test(arguments: [
        (["prompt": "Hi.", "voice": "robot"], "robot"),
        (["prompt": "Hi.", "model": "openai/rewrite"], "openai/rewrite"),
    ] as [([String: String], String)])
    func refusalsAreStructuredAndCreateNothing(args: [String: String], mentioned: String) async throws {
        let provider = FakeProvider()
        let fixture = try await fixture(provider)
        defer { fixture.cleanup() }
        let error = try error(in: await run(fixture, args))
        #expect(error["code"] as? String == "invalid_request")
        #expect((error["message"] as? String)?.contains(mentioned) == true)
        #expect(fixture.editor.mediaAssets.count == 1)
        #expect(await provider.submitted.isEmpty)
        #expect(!fixture.undoManager.canUndo)
    }

    @Test func generatedWavLandsAsWavWithTheBackendToken() async throws {
        let result = JobResult(url: Self.resultURL, contentType: "audio/wav", fileExtension: "wav")
        let states = [jobState(.queued), jobState(.running), jobState(.succeeded, results: [result])]
        let fixture = try await fixture(FakeProvider(states: states))
        defer { fixture.cleanup() }
        let wav = try TestAudio.silentWav(durationSeconds: 1)
        defer { try? FileManager.default.removeItem(at: wav) }
        let authorization = Box<String?>(nil)
        fixture.editor.backendConfiguration = { Self.backend }
        fixture.editor.remoteDownloadFetch = { request in
            authorization.value = request.value(forHTTPHeaderField: "Authorization")
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.copyItem(at: wav, to: file)
            return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/wav"])!)
        }
        #expect(!(await run(fixture, ["prompt": "Welcome back."])).isError)
        let asset = try #require(fixture.editor.mediaAssets.first { $0.type == .audio })
        try await fixture.waitUntil { fixture.isFinalized(asset) }
        #expect(asset.url.pathExtension == "wav")
        #expect(authorization.value == "Bearer secret-token")
    }

    @Test func toolCopyNamesNoProvider() throws {
        let tool = try #require(ToolDefinitions.all.first { $0.name == .generateAudio })
        let text = tool.description + String(describing: tool.inputSchema)
        for name in ["OpenAI", "MiniMax", "Gemini", "ElevenLabs", "Sonilo", "Lyria"] {
            #expect(!text.contains(name), "generate_audio copy names \(name)")
        }
    }
}
