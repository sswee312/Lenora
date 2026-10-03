import Foundation

enum GenerationJobParams: Sendable {
    case video(VideoGenerationParams)
    case image(ImageGenerationParams)
    case audio(AudioGenerationParams)
    case upscale(UpscaleGenerationParams)
    case removeBackground
    case edit(ImageEditParams)
    case reframe(VideoReframeParams)
}

extension GenerationJobParams {
    func jobParts(uploaded: [String]) throws(GenerationError) -> (inputs: [JobInput], params: any Encodable & Sendable) {
        switch self {
        case .video(let p):
            guard p.sourceVideoURL == nil, p.referenceVideoURLs.isEmpty, p.referenceAudioURLs.isEmpty else {
                throw .unsupportedInputs("video and audio references")
            }
            let inputs = [p.startFrameURL.map { JobInput.assetRef($0, role: .startFrame) },
                          p.endFrameURL.map { JobInput.assetRef($0, role: .endFrame) }].compactMap { $0 }
                + p.referenceImageURLs.map { .assetRef($0, role: .reference) }
            return (inputs, VideoGenerateParams(prompt: p.prompt, duration: p.duration, resolution: p.resolution.nonEmpty,
                                                aspectRatio: p.aspectRatio.nonEmpty, generateAudio: p.generateAudio))
        case .image(let p):
            return (p.imageURLs.map { .assetRef($0, role: .reference) },
                    ImageGenerateParams(prompt: p.prompt, aspectRatio: p.aspectRatio.nonEmpty, count: p.numImages, seed: p.seed))
        case .upscale(let p):
            return ([.assetRef(p.sourceURL)], EmptyParams())
        case .audio(let p):
            guard uploaded.isEmpty, p.videoURL == nil, p.sourceURL == nil, p.referenceImageURL == nil,
                  p.referenceAudioURLs?.isEmpty ?? true else {
                throw .unsupportedInputs("audio, video and image inputs")
            }
            return ([], SpeechParams(prompt: p.prompt, voice: p.voice.nonEmpty, styleInstructions: p.styleInstructions.nonEmpty))
        case .removeBackground:
            return (uploaded.map { .assetRef($0) }, EmptyParams())
        case .edit(let params):
            return (uploaded.map { .assetRef($0) }, params)
        case .reframe(let params):
            return (uploaded.map { .assetRef($0) }, params)
        }
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? { self.flatMap { $0.isEmpty ? nil : $0 } }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
