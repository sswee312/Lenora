import Testing
@testable import Lenora

@MainActor
struct ToolAvailabilityTests {
    private func names(in catalog: ModelCatalog) -> Set<ToolName> {
        Set(ToolDefinitions.available(ToolDefinitions.mcpServer, catalog: catalog).map(\.name))
    }

    @Test func transformMediaIsListedOnlyWithBackgroundRemoval() throws {
        #expect(!names(in: ModelCatalog()).contains(.transformMedia))
        let connected = names(in: try EditorTestFixture.connectedCatalog())
        #expect(connected.contains(.transformMedia))
        #expect(!connected.contains(.generateVideo) && !connected.contains(.upscaleMedia))
        #expect(connected.contains(.getTimeline))
    }

    @Test func disconnectedBackendHidesEveryBackendTool() {
        let listed = names(in: ModelCatalog())
        let backendTools: Set<ToolName> = [.transformMedia, .generateVideo, .generateImage, .generateAudio, .upscaleMedia]
        #expect(listed.isDisjoint(with: backendTools))
    }

    @Test func listModelsStaysListedWithoutBackend() {
        #expect(names(in: ModelCatalog()).contains(.listModels))
    }

    @Test func inAppAgentListIsFilteredLikeMCP() throws {
        let listed = ToolDefinitions.available(ToolDefinitions.inAppAgent, catalog: ModelCatalog()).map(\.name)
        #expect(!listed.contains(.transformMedia))
        #expect(listed.contains(.readSkill))
    }

    @Test func backendGuidanceDoesNotEquateNoGenerationWithNoBackend() throws {
        let timeline = try #require(ToolDefinitions.mcpServer.first { $0.name == .getTimeline }).description
        let listModels = try #require(ToolDefinitions.mcpServer.first { $0.name == .listModels }).description
        for text in [timeline, listModels, AgentInstructions.serverInstructions] {
            #expect(!text.contains("connect a backend"))
            #expect(!text.contains("isn't connected"))
            #expect(text.contains("transform_media"))
            #expect(text.contains("Settings → Backend shows which adapters are enabled"))
        }
    }

    @Test func editingToolsNeverDependOnTheBackend() {
        let unconditional = ToolDefinitions.mcpServer.filter { $0.name.requiredKinds == nil }.map(\.name)
        #expect(unconditional.contains(.getTimeline) && unconditional.contains(.addClips))
    }
}
