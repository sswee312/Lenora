import Foundation
import MCP

enum ModelKind: Sendable {
    case video(VideoModelConfig)
    case image(ImageModelConfig)
    case audio(AudioModelConfig)
    case upscale(UpscaleModelConfig)
}

enum ModelRegistry {
    @MainActor static var byId: [String: ModelKind] { ModelCatalog.shared.byId }

    @MainActor static func exists(id: String) -> Bool { byId[id] != nil }


    @MainActor static func displayName(for id: String) -> String {
        switch byId[id] {
        case .video(let m): m.displayName
        case .image(let m): m.displayName
        case .audio(let m): m.displayName
        case .upscale(let m): m.displayName
        case .none: id
        }
    }

    @MainActor static func providerIconKey(for id: String) -> String? {
        switch byId[id] {
        case .video(let m): m.entry.providerIconKey
        case .image(let m): m.entry.providerIconKey
        case .audio(let m): m.entry.providerIconKey
        case .upscale(let m): m.entry.providerIconKey
        case .none: nil
        }
    }
}

@Observable
@MainActor
final class ModelCatalog {
    static let shared = ModelCatalog()
    static let didChange = Notification.Name("ModelCatalogDidChange")

    private(set) var video: [VideoModelConfig] = []
    private(set) var image: [ImageModelConfig] = []
    private(set) var audio: [AudioModelConfig] = []
    private(set) var upscale: [UpscaleModelConfig] = []
    private(set) var byId: [String: ModelKind] = [:]
    private(set) var backendModels: [String: BackendModel] = [:]
    private(set) var isLoaded: Bool = false

    init() {}

    func apply(_ capabilities: BackendCapabilities) {
        backendModels = Dictionary(capabilities.models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let entries = capabilities.models.compactMap { model -> CatalogEntry? in
            do {
                if let entry = try CatalogEntry(model: model) { return entry }
            } catch {
                Log.generation.warning("skipping model \(model.id) (\(model.kind)): invalid ui hints: \(error)")
                return nil
            }
            if CatalogEntry.Kind(protocolKind: model.kind) == nil {
                Log.generation.notice("skipping model \(model.id) (\(model.kind)): kind has no editor config")
            } else {
                Log.generation.warning("skipping model \(model.id) (\(model.kind)): no ui hints")
            }
            return nil
        }
        apply(entries)
        isLoaded = true
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func supports(kind: String) -> Bool { backendModels.values.contains { $0.kind == kind } }
    func supportsAny(of kinds: [String]) -> Bool { kinds.contains(where: supports(kind:)) }
    func backendModel(id: String) -> BackendModel? { backendModels[id] }
    func models(ofKind kind: String) -> [BackendModel] {
        backendModels.values.filter { $0.kind == kind }.sorted { $0.id < $1.id }
    }

    func firstConfig(ofKind kind: String) -> ModelKind? {
        models(ofKind: kind).lazy.compactMap { self.byId[$0.id] }.first
    }

    private func apply(_ entries: [CatalogEntry]) {
        var newVideo: [VideoModelConfig] = []
        var newImage: [ImageModelConfig] = []
        var newAudio: [AudioModelConfig] = []
        var newUpscale: [UpscaleModelConfig] = []
        var newById: [String: ModelKind] = [:]
        newVideo.reserveCapacity(entries.count)
        newImage.reserveCapacity(entries.count)
        newAudio.reserveCapacity(entries.count)
        newUpscale.reserveCapacity(entries.count)
        newById.reserveCapacity(entries.count)

        for entry in entries {
            switch entry.uiCapabilities {
            case .video(let caps):
                let m = VideoModelConfig(entry: entry, caps: caps)
                newVideo.append(m)
                newById[m.id] = .video(m)
            case .image(let caps):
                let m = ImageModelConfig(entry: entry, caps: caps)
                newImage.append(m)
                newById[m.id] = .image(m)
            case .audio(let caps):
                let m = AudioModelConfig(entry: entry, caps: caps)
                newAudio.append(m)
                newById[m.id] = .audio(m)
            case .upscale(let caps):
                let m = UpscaleModelConfig(entry: entry, caps: caps)
                newUpscale.append(m)
                newById[m.id] = .upscale(m)
            }
        }

        self.video = newVideo
        self.image = newImage
        self.audio = newAudio
        self.upscale = newUpscale
        self.byId = newById
    }
}

struct CatalogEntry: Decodable, Sendable {
    let id: String
    let kind: Kind
    let displayName: String
    let providerIconKey: String?
    let providerName: String?
    let description: String?
    let uiCapabilities: UICapabilities

    enum Kind: String, Decodable, Sendable { case video, image, audio, upscale }

    enum UICapabilities: Sendable {
        case video(VideoCaps)
        case image(ImageCaps)
        case audio(AudioCaps)
        case upscale(UpscaleCaps)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, displayName, providerIconKey, providerName, description, uiCapabilities
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.kind = try c.decode(Kind.self, forKey: .kind)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.providerIconKey = try c.decodeIfPresent(String.self, forKey: .providerIconKey)
        self.providerName = try c.decodeIfPresent(String.self, forKey: .providerName)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        switch self.kind {
        case .video:
            self.uiCapabilities = .video(try c.decode(VideoCaps.self, forKey: .uiCapabilities))
        case .image:
            self.uiCapabilities = .image(try c.decode(ImageCaps.self, forKey: .uiCapabilities))
        case .audio:
            self.uiCapabilities = .audio(try c.decode(AudioCaps.self, forKey: .uiCapabilities))
        case .upscale:
            self.uiCapabilities = .upscale(try c.decode(UpscaleCaps.self, forKey: .uiCapabilities))
        }
    }
}

extension CatalogEntry.Kind {
    init?(protocolKind: String) {
        switch protocolKind {
        case "video.generate", "video.reframe", "video.edit", "video.lipSync": self = .video
        case "image.generate", "image.edit": self = .image
        case "audio.speech", "audio.music", "audio.sfx": self = .audio
        case "image.upscale", "video.upscale": self = .upscale
        default: return nil
        }
    }
}

extension CatalogEntry {
    /// Builds an editor config entry from a generation model's `ui` hints; nil for kinds without editor configs.
    init?(model: BackendModel) throws {
        guard let kind = Kind(protocolKind: model.kind), case .object(var fields)? = model.ui else { return nil }
        fields["id"] = .string(model.id)
        fields["kind"] = .string(kind.rawValue)
        fields["displayName"] = .string(model.displayName)
        self = try JSONDecoder().decode(CatalogEntry.self, from: JSONEncoder().encode(Value.object(fields)))
    }
}

extension ModelCatalog {
    static let generationKinds = [
        "image.generate", "image.edit", "image.upscale", "video.generate", "video.reframe",
        "video.edit", "video.lipSync", "video.upscale", "audio.speech", "audio.music", "audio.sfx",
    ]
}

extension ClipType {
    var generationKinds: [String] {
        switch self {
        case .video: ["video.generate", "video.reframe", "video.edit", "video.lipSync"]
        case .image: ["image.generate", "image.edit"]
        case .audio: ["audio.speech", "audio.music", "audio.sfx"]
        default: []
        }
    }
}

struct VideoCaps: Decodable, Sendable {
    let supportsPrompt: Bool?
    let durations: [Int]
    let resolutions: [String]?
    let aspectRatios: [String]
    let supportsFirstFrame: Bool
    let supportsLastFrame: Bool
    let maxReferenceImages: Int
    let maxReferenceVideos: Int
    let maxReferenceAudios: Int
    let maxTotalReferences: Int?
    let maxCombinedVideoRefSeconds: Double?
    let maxCombinedAudioRefSeconds: Double?
    let framesAndReferencesExclusive: Bool
    let referenceTagNoun: String
    let requiresSourceVideo: Bool
    let maxSourceVideoSeconds: Double?
    let maxSourceVideoResolution: SourceVideoResolution?
    let requiredSourceVideoEncoding: SourceVideoEncoding?
    let requiresReferenceImage: Bool
    let requiresReferenceAudio: Bool?
    let supportsDraft: Bool?
    let supportsAudioToggle: Bool?
    let supportsSourceVideo: Bool?
}

enum SourceVideoResolution: String, Decodable, Sendable {
    case p720 = "720p", p1080 = "1080p", p4k = "4k"
}

enum SourceVideoEncoding: String, Decodable, Sendable {
    case h264MP4 = "h264-mp4"
}

struct ImageCaps: Decodable, Sendable {
    let resolutions: [String]?
    let aspectRatios: [String]
    let qualities: [String]?
    let supportsImageReference: Bool
    let maxImages: Int
}

struct AudioCaps: Decodable, Sendable {
    let category: String
    let voices: [String]?
    let defaultVoice: String?
    let supportsLyrics: Bool
    let supportsInstrumental: Bool
    let supportsStyleInstructions: Bool
    let durations: [Int]?
    let durationRange: AudioDurationRange?
    let minPromptLength: Int
    let maxReferenceImages: Int?
    let maxReferenceAudios: Int?
    let maxReferenceAudioSeconds: Double?
    let referenceAudioExtensions: [String]?
    let referenceImagesAndAudiosExclusive: Bool?
    let supportsMultilingual: Bool?
    let inputs: [String]?
    let promptLabel: String?
    let minSeconds: Int?
    let maxSeconds: Int?
    let targetLanguages: [String]?
    let defaultTargetLanguage: String?
}

struct AudioDurationRange: Decodable, Sendable {
    let minimum: Int
    let maximum: Int
    let defaultValue: Int
}

struct UpscaleCaps: Decodable, Sendable {
    let speed: String   // "Fast" | "Medium" | "Slow"
    let p75DurationSeconds: Int
    let maximumUpscaleFactor: Double?
    let supportedTypes: [String]   // "video" | "image"
    let selectSettings: [UpscaleSelectSetting]?
    let numericSettings: [UpscaleNumericSetting]?
    let toggleSettings: [UpscaleToggleSetting]?
}
