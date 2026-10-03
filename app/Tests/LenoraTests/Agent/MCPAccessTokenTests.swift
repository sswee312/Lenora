import Foundation
import Testing
@testable import Lenora

struct MCPAccessTokenTests {
    @Test func generatesDistinct256BitTokens() {
        let a = MCPAccessToken.generate(), b = MCPAccessToken.generate()
        #expect(a != b)
        #expect(a.count == 43)
        #expect(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test(arguments: [
        ("Bearer tok", true), ("bearer tok", true), ("Bearer  tok", false), ("Bearer to", false),
        ("Bearer tokk", false), ("Basic tok", false), ("tok", false), ("", false),
    ])
    func authorizesOnlyExactBearer(header: String, expected: Bool) {
        #expect(MCPAccessToken.isAuthorized(header: header, token: "tok") == expected)
    }

    @Test func missingHeaderIsRejected() {
        #expect(!MCPAccessToken.isAuthorized(header: nil, token: "tok"))
    }

    @Test(arguments: [(nil, 19789), (8080, 8080), (80, 19789), (70000, 19789), (0, 19789)] as [(Int?, UInt16)])
    func resolvesPort(stored: Int?, expected: UInt16) {
        #expect(MCPPort.resolve(stored) == expected)
    }

    @Test func claudeCodeSnippetCarriesPortAndToken() {
        #expect(AgentConnectionSnippets.claudeCode(port: 19789, token: "abc")
                == #"claude mcp add --transport http lenora http://127.0.0.1:19789/mcp --header "Authorization: Bearer abc""#)
    }

    @Test func cursorSnippetIsValidJSON() throws {
        let json = try JSONSerialization.jsonObject(with: Data(AgentConnectionSnippets.cursor(port: 1234, token: "abc").utf8)) as? [String: Any]
        let server = (json?["mcpServers"] as? [String: Any])?["lenora"] as? [String: Any]
        #expect(server?["url"] as? String == "http://127.0.0.1:1234/mcp")
        #expect((server?["headers"] as? [String: String])?["Authorization"] == "Bearer abc")
    }

    @Test func codexSnippetNamesTheServer() {
        let toml = AgentConnectionSnippets.codex(port: 1234, token: "abc")
        #expect(toml.contains("[mcp_servers.lenora]") && toml.contains(#"url = "http://127.0.0.1:1234/mcp""#))
        #expect(toml.contains(#"Authorization = "Bearer abc""#))
    }
}
