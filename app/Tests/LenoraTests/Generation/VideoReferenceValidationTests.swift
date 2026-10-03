import Foundation
import Testing
@testable import Lenora

@Suite("Video reference validation")
@MainActor
struct VideoReferenceValidationTests {
    @Test("Validates combined video-ref duration against the trimmed span")
    func validateUsesTrimmedVideoRefDuration() throws {
        let model = try Self.minimaxH3()
        let url = URL(fileURLWithPath: "/tmp/long-reframe.mp4")
        let asset = MediaAsset(
            id: "long-1",
            url: url,
            type: .video,
            name: "Long",
            duration: 60
        )
        let inputs = VideoGenerationSubmission.InputAssets(videoRefs: [asset])
        #expect(inputs.validate(for: model)?.contains("Combined video reference duration") == true)

        let trim = TrimmedSource(
            sourceURL: url,
            trimStartFrame: 0,
            trimEndFrame: 45 * 30,
            sourceFramesConsumed: 10 * 30,
            fps: 30
        )
        #expect(trim.durationSeconds == 10)
        #expect(inputs.validate(for: model, trimmedSource: trim) == nil)
    }

    @Test("Applies trim to the matching video even when an image reference precedes it")
    func validateAppliesTrimBehindImageReference() throws {
        let model = try Self.minimaxH3()
        let image = MediaAsset(
            id: "img-1",
            url: URL(fileURLWithPath: "/tmp/style.png"),
            type: .image,
            name: "Style"
        )
        let videoURL = URL(fileURLWithPath: "/tmp/long-second.mp4")
        let video = MediaAsset(
            id: "vid-2",
            url: videoURL,
            type: .video,
            name: "Long second",
            duration: 60
        )
        let inputs = VideoGenerationSubmission.InputAssets(
            imageRefs: [image],
            videoRefs: [video]
        )
        let trim = TrimmedSource(
            sourceURL: videoURL,
            trimStartFrame: 30,
            trimEndFrame: 49 * 30,
            sourceFramesConsumed: 10 * 30,
            fps: 30
        )
        #expect(inputs.validate(for: model, trimmedSource: trim) == nil)
    }

    @Test("Ignores trim whose source URL matches no reference")
    func validateIgnoresUnrelatedTrim() throws {
        let model = try Self.minimaxH3()
        let video = MediaAsset(
            id: "vid-3",
            url: URL(fileURLWithPath: "/tmp/long-third.mp4"),
            type: .video,
            name: "Long third",
            duration: 60
        )
        let inputs = VideoGenerationSubmission.InputAssets(videoRefs: [video])
        let trim = TrimmedSource(
            sourceURL: URL(fileURLWithPath: "/tmp/other.mp4"),
            trimStartFrame: 30,
            trimEndFrame: 49 * 30,
            sourceFramesConsumed: 10 * 30,
            fps: 30
        )
        #expect(inputs.validate(for: model, trimmedSource: trim)?.contains("Combined video reference duration") == true)
    }

    private static func minimaxH3() throws -> VideoModelConfig {
        try decodeVideoModel(#"""
        {
          "id": "minimax-h3",
          "kind": "video",
          "displayName": "MiniMax H3",
          "providerIconKey": "minimax",
          "allowedEndpoints": ["opaque"],
          "responseShape": "video",
          "uiCapabilities": {
            "supportsPrompt": true,
            "durations": [5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
            "resolutions": ["768P", "2K"],
            "aspectRatios": ["16:9", "9:16", "1:1"],
            "supportsFirstFrame": false,
            "supportsLastFrame": false,
            "maxReferenceImages": 9,
            "maxReferenceVideos": 3,
            "maxReferenceAudios": 3,
            "maxTotalReferences": 12,
            "maxCombinedVideoRefSeconds": 15,
            "maxCombinedAudioRefSeconds": 15,
            "framesAndReferencesExclusive": false,
            "referenceTagNoun": "Video",
            "requiresSourceVideo": false,
            "maxSourceVideoSeconds": null,
            "requiresReferenceImage": false,
            "requiresReferenceAudio": false
          }
        }
        """#)
    }

    private static func decodeVideoModel(_ json: String) throws -> VideoModelConfig {
        let entry = try JSONDecoder().decode(CatalogEntry.self, from: Data(json.utf8))
        guard case .video(let caps) = entry.uiCapabilities else {
            Issue.record("Expected video capabilities")
            throw DecodeError.wrongKind
        }
        return VideoModelConfig(entry: entry, caps: caps)
    }

    private enum DecodeError: Error { case wrongKind }
}
