import Foundation
import MCP

/// HTTP adapter. Tool handling lives in `ToolExecutor`.
@Observable
@MainActor
final class MCPService {

    var port: UInt16 { MCPPort.current }

    private static let enabledKey = "xyz.agentage.lenora.mcp.enabled"

    static var isEnabledPreference: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: enabledKey) == nil { return true }
            return defaults.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }

    private(set) var isRunning: Bool = false
    private(set) var startError: String?

    @ObservationIgnored
    private var generation = 0

    @ObservationIgnored
    private let projectProvider: () -> VideoProject?
    @ObservationIgnored
    private var httpServer: MCPHTTPServer?

    init(projectProvider: @escaping () -> VideoProject?) {
        self.projectProvider = projectProvider
    }

    func start() async {
        generation += 1
        let attempt = generation
        startError = nil
        let port = port
        let token: String
        do {
            token = try await MCPAccessToken.loadOrCreate()
        } catch {
            guard attempt == generation else { return }
            Log.mcp.error("http server not started: \(error.localizedDescription)")
            startError = error.localizedDescription
            isRunning = false
            return
        }
        guard attempt == generation else { return }
        let httpServer = MCPHTTPServer(port: port, token: token) { [self] in
            let toolExecutor = await makeSessionToolExecutor()
            let server = Server(
                name: "lenora",
                version: "1.0.0",
                instructions: AgentInstructions.serverInstructions + AgentInstructions.projectNavigation,
                capabilities: .init(
                    resources: .init(subscribe: false, listChanged: false),
                    tools: .init(listChanged: true)
                )
            )
            await Self.registerTools(on: server, executor: toolExecutor)
            await Self.registerResources(on: server)
            return server
        }
        self.httpServer = httpServer
        do {
            try await httpServer.start()
            guard attempt == generation else { return }
            Log.mcp.notice("http server started port=\(port)")
            isRunning = true
        } catch {
            guard attempt == generation else { return }
            Log.mcp.error("http server failed to start: \(error.localizedDescription)")
            startError = error.localizedDescription
            isRunning = false
        }
    }

    func restart() async {
        await stop()
        await start()
    }

    func makeSessionToolExecutor() -> ToolExecutor {
        ToolExecutor(projectProvider: projectProvider)
    }

    func stop() async {
        generation += 1
        let server = httpServer
        httpServer = nil
        isRunning = false
        await server?.stop()
        Log.mcp.notice("http server stopped")
    }

    nonisolated static func registerTools(on server: Server, executor: ToolExecutor) async {
        let tools: [Tool] = ToolDefinitions.mcpServer.map { def in
            Tool(name: def.name.rawValue, description: def.description, inputSchema: def.mcpSchemaValue)
        }

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            await dispatchCall(params, executor: executor)
        }
    }

    // Convert args on the main actor so the non-Sendable dict never crosses the hop.
    private static func dispatchCall(_ params: CallTool.Parameters, executor: ToolExecutor) async -> CallTool.Result {
        let args = ToolArgsBridge.argsFromMCP(params.arguments ?? [:])
        let result = await executor.execute(name: params.name, args: args, source: "mcp")
        return result.toMCPResult()
    }

    private nonisolated static func registerResources(on server: Server) async {
        let resources = [
            Resource(
                name: "Video Models",
                uri: "lenora://models/video",
                description: "Available AI video generation models and their capabilities",
                mimeType: "application/json"
            ),
            Resource(
                name: "Image Models",
                uri: "lenora://models/image",
                description: "Available AI image generation models and their capabilities",
                mimeType: "application/json"
            ),
        ]

        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: resources)
        }

        await server.withMethodHandler(ReadResource.self) { params in
            await Self.readResource(uri: params.uri)
        }
    }

    @MainActor
    private static func readResource(uri: String) -> ReadResource.Result {
        switch uri {
        case "lenora://models/video":
            let json = ToolExecutor.jsonString(VideoModelConfig.allModels.map { ToolExecutor.videoModelInfo($0) }) ?? "[]"
            return .init(contents: [.text(json, uri: uri, mimeType: "application/json")])
        case "lenora://models/image":
            let json = ToolExecutor.jsonString(ImageModelConfig.allModels.map { ToolExecutor.imageModelInfo($0) }) ?? "[]"
            return .init(contents: [.text(json, uri: uri, mimeType: "application/json")])
        default:
            return .init(contents: [.text("Unknown resource: \(uri)", uri: uri)])
        }
    }

}
