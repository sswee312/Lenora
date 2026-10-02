import Foundation
import MCP
import Testing
@testable import Lenora

@MainActor
struct ModelCatalogCapabilitiesTests {
    private func capabilities(_ name: String = "Capabilities.cloudinary") throws -> BackendCapabilities {
        try BackendCoding.decoder().decode(BackendCapabilities.self, from: ProtocolFixtures.data(name))
    }

    @Test func supportsAdvertisedKindsOnly() throws {
        let catalog = ModelCatalog()
        catalog.apply(try capabilities())
        #expect(catalog.supports(kind: "image.removeBackground"))
        #expect(!catalog.supports(kind: "video.generate"))
        #expect(catalog.backendModel(id: "cloudinary/background-removal")?.inputs.maxBytes == 10_485_760)
        #expect(catalog.isLoaded)
    }

    @Test func emptyCapabilitiesClearEverything() throws {
        let catalog = ModelCatalog()
        catalog.apply(try capabilities())
        catalog.apply(.empty)
        #expect(!catalog.supports(kind: "image.removeBackground"))
        #expect(catalog.video.isEmpty && catalog.image.isEmpty)
    }

    @Test func unknownKindsAreIgnored() throws {
        let json = #"{"protocolVersion":"1","adapters":[],"models":[{"id":"x/y","kind":"hologram.render","displayName":"Y","inputs":{"types":[],"maxBytes":1},"cancellable":false}]}"#
        let catalog = ModelCatalog()
        catalog.apply(try BackendCoding.decoder().decode(BackendCapabilities.self, from: Data(json.utf8)))
        #expect(catalog.video.isEmpty && catalog.image.isEmpty && catalog.audio.isEmpty && catalog.upscale.isEmpty)
        #expect(catalog.supports(kind: "hologram.render"))
    }

    @Test func buildsEditorConfigsFromUIHints() throws {
        let json = #"{"protocolVersion":"1","adapters":[],"models":[{"id":"acme/paint","kind":"image.generate","displayName":"Paint","inputs":{"types":[],"maxBytes":1},"cancellable":true,"ui":{"providerName":"Acme","uiCapabilities":{"aspectRatios":["1:1"],"supportsImageReference":false,"maxImages":2}}}]}"#
        let catalog = ModelCatalog()
        catalog.apply(try BackendCoding.decoder().decode(BackendCapabilities.self, from: Data(json.utf8)))
        #expect(catalog.image.map(\.id) == ["acme/paint"])
        #expect(catalog.image.first?.aspectRatios == ["1:1"])
        #expect(catalog.models(ofKind: "image.generate").map(\.id) == ["acme/paint"])
    }

    @Test func modelsWithMalformedUIHintsStayAdvertisedButHaveNoEditorConfig() throws {
        let json = #"{"protocolVersion":"1","adapters":[],"models":[{"id":"acme/bad","kind":"image.generate","displayName":"Bad","inputs":{"types":[],"maxBytes":1},"cancellable":true,"ui":{"uiCapabilities":{}}}]}"#
        let catalog = ModelCatalog()
        catalog.apply(try BackendCoding.decoder().decode(BackendCapabilities.self, from: Data(json.utf8)))
        #expect(catalog.image.isEmpty)
        #expect(catalog.supports(kind: "image.generate"))
    }

    @Test func gatesFollowAdvertisedKinds() throws {
        let catalog = ModelCatalog()
        catalog.apply(try capabilities())
        #expect(!catalog.supportsAny(of: ModelCatalog.generationKinds))
        #expect(catalog.supportsAny(of: ["image.removeBackground", "video.generate"]))
    }

    @Test func postsDidChange() async throws {
        let catalog = ModelCatalog()
        let notified = Box(false)
        let token = NotificationCenter.default.addObserver(forName: ModelCatalog.didChange, object: catalog, queue: nil) { _ in
            notified.value = true
        }
        defer { NotificationCenter.default.removeObserver(token) }
        catalog.apply(try capabilities())
        #expect(notified.value)
    }
}

final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }
