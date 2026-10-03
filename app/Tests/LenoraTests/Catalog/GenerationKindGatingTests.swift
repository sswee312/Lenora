import Foundation
import Testing
@testable import Lenora

@MainActor
struct GenerationKindGatingTests {
    private static let imageUI = #""ui":{"uiCapabilities":{"aspectRatios":["1:1"],"supportsImageReference":false,"maxImages":1}}"#
    private static let upscaleUI = #""ui":{"uiCapabilities":{"speed":"Fast","p75DurationSeconds":5,"supportedTypes":["image"]}}"#

    private func catalog(loaded: Bool = true, _ models: [(id: String, kind: String, ui: String?)]) throws -> ModelCatalog {
        let entries = models.map { model in
            let ui = model.ui.map { "," + $0 } ?? ""
            return #"{"id":"\#(model.id)","kind":"\#(model.kind)","displayName":"\#(model.id)","inputs":{"types":[],"maxBytes":1},"cancellable":false\#(ui)}"#
        }
        let json = #"{"protocolVersion":"1","adapters":[],"models":[\#(entries.joined(separator: ","))]}"#
        let catalog = ModelCatalog()
        if loaded {
            catalog.apply(try BackendCoding.decoder().decode(BackendCapabilities.self, from: Data(json.utf8)))
        }
        return catalog
    }

    @Test func panelShowsOnlyTabsThatHaveModels() throws {
        let catalog = try catalog([("a/up", "image.upscale", Self.upscaleUI)])
        #expect(GenerationView.availableTypes(in: catalog) == [.upscale])
        #expect(GenerationView.panelState(in: catalog) == .ready)
    }

    @Test func panelListsEveryTypeWithModelsInTabOrder() throws {
        let catalog = try catalog([
            ("a/up", "image.upscale", Self.upscaleUI),
            ("a/img", "image.generate", Self.imageUI),
        ])
        #expect(GenerationView.availableTypes(in: catalog) == [.image, .upscale])
    }

    @Test func panelIsEmptyOnceLoadedWithoutModels() throws {
        #expect(GenerationView.panelState(in: try catalog([("a/bg", "image.removeBackground", nil)])) == .empty)
        #expect(GenerationView.panelState(in: try catalog([])) == .empty)
    }

    @Test func panelIsLoadingBeforeCapabilitiesArrive() throws {
        #expect(GenerationView.panelState(in: try catalog(loaded: false, [])) == .loading)
    }

    @Test func modelsWithoutUIHintsDoNotMakeATabAvailable() throws {
        let catalog = try catalog([("a/img", "image.generate", nil)])
        #expect(GenerationView.availableTypes(in: catalog).isEmpty)
        #expect(catalog.supports(kind: "image.generate"))
    }

    @Test(arguments: [
        (EditAction.edit, ClipType.image, "image.generate", true),
        (.edit, .image, "video.edit", false),
        (.edit, .video, "video.edit", true),
        (.edit, .video, "image.edit", false),
        (.upscale, .image, "image.upscale", true),
        (.upscale, .image, "video.upscale", false),
        (.upscale, .video, "video.upscale", true),
        (.rerun, .audio, "audio.music", true),
        (.rerun, .audio, "image.edit", false),
        (.rerun, .audio, "video.edit", false),
        (.rerun, .image, "video.generate", false),
        (.createVideo, .image, "video.generate", true),
    ])
    func actionsAreGatedByTheKindTheMediaTypeNeeds(
        action: EditAction, mediaType: ClipType, advertisedKind: String, expected: Bool
    ) throws {
        let catalog = try catalog([("a/m", advertisedKind, nil)])
        #expect(action.isAvailable(for: mediaType, in: catalog) == expected)
    }
}
