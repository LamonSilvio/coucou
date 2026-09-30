import Foundation

struct RemoteMCPServer: Codable {
    let name: String; let endpoint: String; let enabled: Bool; let tools: [String]
    func valid() -> Bool {
        OpenAIService.safeID(name) && name.count <= 32 && !tools.isEmpty && tools.allSatisfy { OpenAIService.safeID($0) }
            && URL(string: endpoint).map { $0.scheme == "https" && $0.host != nil && $0.user == nil && $0.password == nil && $0.query == nil && $0.fragment == nil } == true
    }
    func tool(token: String?) throws -> [String: Any] {
        guard valid() else { throw OpenAIError.message("Invalid MCP server configuration.") }
        var result: [String: Any] = ["type": "mcp", "server_label": name, "server_url": endpoint, "require_approval": "always", "allowed_tools": tools]
        if let token, !token.isEmpty { result["authorization"] = token }
        return result
    }
}
enum RemoteMCP {
    static func servers(_ defaults: UserDefaults) throws -> [RemoteMCPServer] {
        let raw = defaults.string(forKey: "mcpServers") ?? "[]"
        guard let data = raw.data(using: .utf8), data.count < 24000 else { throw OpenAIError.message("Invalid MCP configuration.") }
        let servers = try JSONDecoder().decode([RemoteMCPServer].self, from: data)
        guard servers.count <= 8, Set(servers.map(\.name)).count == servers.count, servers.allSatisfy({ $0.valid() }) else { throw OpenAIError.message("Invalid MCP configuration; names must be unique.") }
        return servers.filter(\.enabled)
    }
    static func discovery(_ output: [[String: Any]]) -> String {
        output.filter { $0["type"] as? String == "mcp_list_tools" }.map { item in
            let names = (item["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            return "\(item["server_label"] as? String ?? "MCP"): \(names.joined(separator: ", "))" + (item["error"] == nil ? "" : " — connection failed")
        }.joined(separator: "\n")
    }
    @MainActor static func approval(_ item: [String: Any], servers: [RemoteMCPServer], approvals: ActionApprovalCenter = .shared) async -> [String: Any] {
        let id = item["id"] as? String ?? ""
        let server = item["server_label"] as? String ?? ""
        let tool = item["name"] as? String ?? ""
        let raw = item["arguments"] as? String ?? "{}"
        var allowed = false
        if !id.isEmpty, servers.contains(where: { $0.name == server && $0.tools.contains(tool) }), SecretRedaction.text(raw) == raw,
           let data = raw.data(using: .utf8), let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            allowed = await approvals.authorize(ActionRequest(id: id, provider: "openai", integration: "mcp", operation: tool, parameters: ["server": server, "tool": tool, "arguments": args], risk: .critical))
        }
        return ["type": "mcp_approval_response", "approval_request_id": id, "approve": allowed]
    }
}
