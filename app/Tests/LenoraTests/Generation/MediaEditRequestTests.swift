import Foundation
import Testing
@testable import Lenora

struct MediaEditRequestTests {
    @Test(arguments: ["the cat, left", "a;b", "a/b", "x:y", "snake_case", "café", "", String(repeating: "a", count: 101)])
    func rejectsUnsafePrompts(prompt: String) {
        #expect(MediaEditRequest.edit(.remove(prompt: prompt)).invalidField()?.field == "prompt")
    }

    @Test(arguments: ["the bee", "Bob's hat", "a-b.c", String(repeating: "a", count: 100)])
    func acceptsSafePrompts(prompt: String) {
        #expect(MediaEditRequest.edit(.remove(prompt: prompt)).invalidField() == nil)
    }

    @Test func checksEveryTextField() {
        #expect(MediaEditRequest.edit(.replace(from: "cup", to: "a, mug")).invalidField()?.field == "to")
        #expect(MediaEditRequest.edit(.recolor(prompt: "jacket", color: "blue")).invalidField()?.field == "color")
        #expect(MediaEditRequest.edit(.backgroundReplace(prompt: nil)).invalidField() == nil)
        #expect(MediaEditRequest.edit(.fill(aspectRatio: "2:1")).invalidField()?.field == "aspectRatio")
        #expect(MediaEditRequest.reframe(VideoReframeParams(aspectRatio: "3:2")).invalidField()?.field == "aspectRatio")
    }

    @Test func invalidFieldsNameTheirIssue() {
        #expect(MediaEditRequest.edit(.remove(prompt: "a;b")).invalidField()?.issue == .unsafeText)
        #expect(MediaEditRequest.edit(.recolor(prompt: "jacket", color: "blue")).invalidField()?.issue == .hexColor)
        #expect(MediaEditRequest.edit(.fill(aspectRatio: "2:1")).invalidField()?.issue == .aspectRatio(MediaEditRequest.fillAspectRatios))
    }

    @MainActor
    @Test(arguments: [MediaEditParameterIssue.unsafeText, .aspectRatio(["1:1", "16:9"]), .hexColor])
    func parameterIssuesAreTranslated(issue: MediaEditParameterIssue) throws {
        let english = try localization(["en"]), german = try localization(["de"])
        #expect(issue.userMessage(in: german) != issue.userMessage(in: english))
        #expect(MediaEditRefusal.invalidParameter(field: "x", issue: issue).toolMessage == "Invalid x: \(issue.toolReason).")
    }

    @MainActor
    private func localization(_ languages: [String]) throws -> AppLocalization {
        let suite = "MediaEditRequestTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        return AppLocalization(defaults: defaults, preferredLanguages: languages)
    }

    @Test func kindsAndMediaTypes() {
        #expect(MediaEditRequest.removeBackground.kind == "image.removeBackground")
        #expect(MediaEditRequest.edit(.restore).kind == "image.edit")
        #expect(MediaEditRequest.reframe(VideoReframeParams(aspectRatio: "9:16")).mediaType == .video)
    }
}
