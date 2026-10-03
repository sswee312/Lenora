import Testing
@testable import Lenora

@MainActor
struct EditActionGateTests {
    @Test func aiEditsNeedAnAdvertisedOp() throws {
        let spec1 = try EditorTestFixture.connectedCatalog()
        #expect(!EditAction.generativeFill.isAvailable(for: .image, in: spec1))
        let full = try EditorTestFixture.connectedCatalog("Capabilities.cloudinaryFull")
        #expect(EditAction.allAIEdits.allSatisfy { $0.isAvailable(for: .image, in: full) })
    }

    @Test func aiEditIsHiddenWhenTheModelOmitsItsOp() throws {
        let catalog = ModelCatalog()
        let full = try BackendCoding.decoder().decode(BackendCapabilities.self, from: ProtocolFixtures.data("Capabilities.cloudinaryFull"))
        let restoreOnly = full.models.map { model in
            model.kind == "image.edit"
                ? BackendModel(id: model.id, kind: model.kind, displayName: model.displayName, inputs: model.inputs,
                               cancellable: model.cancellable, estimate: model.estimate, ui: model.ui, operations: ["restore"])
                : model
        }
        catalog.apply(BackendCapabilities(protocolVersion: "1", adapters: full.adapters, models: restoreOnly))
        #expect(EditAction.restore.isAvailable(for: .image, in: catalog))
        #expect(!EditAction.recolor.isAvailable(for: .image, in: catalog))
    }

    @Test func eachAIEditMapsToItsProtocolOp() {
        #expect(EditAction.allAIEdits.compactMap(\.editOp) == ImageEditParams.operations)
    }

    @Test func reframeAndEditKinds() {
        #expect(EditAction.reframe.kinds(for: .video) == ["video.reframe"])
        #expect(EditAction.edit.kinds(for: .image) == ["image.generate"])
        #expect(EditAction.edit.kinds(for: .video) == ["video.edit"])
    }

    @Test func reframeIsHiddenWithoutTheKind() throws {
        #expect(!EditAction.reframe.isAvailable(for: .video, in: try EditorTestFixture.connectedCatalog()))
        #expect(EditAction.reframe.isAvailable(for: .video, in: try EditorTestFixture.connectedCatalog("Capabilities.cloudinaryFull")))
    }
}
