import Foundation
import Testing
@testable import Lenora

struct OpenAIProtocolTests {
    private func encoded(_ request: JobRequest) throws -> NSDictionary? {
        try JSONSerialization.jsonObject(with: BackendCoding.encoder().encode(request)) as? NSDictionary
    }

    private func fixture(_ name: String) throws -> NSDictionary? {
        try JSONSerialization.jsonObject(with: ProtocolFixtures.data(name)) as? NSDictionary
    }

    @Test func rewriteStateDecodesItsText() throws {
        let state = try BackendCoding.decoder().decode(JobState.self, from: ProtocolFixtures.data("JobState.rewriteSucceeded"))
        #expect(state.status == .succeeded && state.results == nil)
        #expect(state.text == "A black cat on a moonlit tin roof, low angle, soft blue rim light, slow push-in.")
    }

    @Test func speechStateHasAResultAndNoText() throws {
        let state = try BackendCoding.decoder().decode(JobState.self, from: ProtocolFixtures.data("JobState.speechSucceeded"))
        #expect(state.text == nil)
        #expect(state.results?.map(\.fileExtension) == ["mp3"])
    }

    @Test func speechParamsEncodeLikeTheFixture() throws {
        let request = JobRequest(kind: "audio.speech", model: "openai/voice", inputs: [],
                                 params: SpeechParams(prompt: "Welcome back to the channel.", voice: "nova",
                                                      styleInstructions: "Warm and unhurried."))
        #expect(try encoded(request) == fixture("JobRequest.audioSpeech"))
    }

    @Test func rewriteParamsEncodeLikeTheFixture() throws {
        let request = JobRequest(kind: "text.rewritePrompt", model: "openai/rewrite", inputs: [],
                                 params: RewritePromptParams(text: "a cat on a roof at night", targetKind: "image.generate"))
        #expect(try encoded(request) == fixture("JobRequest.rewritePrompt"))
    }

    @Test func usdBudgetDecodesItsUnit() throws {
        let json = #"{"limit":5.0,"used":0.03,"day":"2026-10-03","unit":"usd"}"#
        #expect(try BackendCoding.decoder().decode(BudgetStatus.self, from: Data(json.utf8)).unit == "usd")
    }

    @MainActor @Test func voiceModelBecomesASpeechAudioConfig() throws {
        let catalog = try EditorTestFixture.connectedCatalog("Capabilities.openai")
        let voice = try #require(catalog.audio.first)
        #expect(catalog.audio.count == 1)
        #expect(voice.category == .tts && voice.inputs == [.text] && voice.promptLabel == "Script")
        #expect(voice.voices?.count == 13 && voice.defaultVoice == "alloy" && voice.supportsStyleInstructions)
        #expect(catalog.supports(kind: "text.rewritePrompt") && catalog.byId["openai/rewrite"] == nil)
    }
}
