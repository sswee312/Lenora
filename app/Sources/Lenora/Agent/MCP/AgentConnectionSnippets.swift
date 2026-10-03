import Foundation

enum AgentConnectionSnippets {
    private static func url(_ port: UInt16) -> String { "http://127.0.0.1:\(port)/mcp" }

    static func claudeCode(port: UInt16, token: String) -> String {
        #"claude mcp add --transport http lenora \#(url(port)) --header "Authorization: Bearer \#(token)""#
    }

    static func cursor(port: UInt16, token: String) -> String {
        """
        {
          "mcpServers": {
            "lenora": {
              "url": "\(url(port))",
              "headers": { "Authorization": "Bearer \(token)" }
            }
          }
        }
        """
    }

    static func codex(port: UInt16, token: String) -> String {
        """
        [mcp_servers.lenora]
        url = "\(url(port))"
        http_headers = { Authorization = "Bearer \(token)" }
        """
    }
}
