import Foundation

@MainActor
enum ToolManager {
    static var integrationTool: [String: Any] { [
        "type": "function", "name": "list_integrations", "description": "List enabled Coucou integrations and whether credentials are configured. Does not retrieve credentials or perform external actions.",
        "strict": true, "parameters": ["type": "object", "properties": [String: Any](), "required": [String](), "additionalProperties": false],
    ] }

    static func execute(name: String, arguments: String, state: AppState) -> String {
        guard name == "list_integrations", let data = arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any], args.isEmpty,
              ToolPermission(level: .safe).permits(explicitConfirmation: false) else {
            return #"{"error":"Tool unavailable or explicit approval required."}"#
        }
        let mapping = ["resend": "resend-api-key", "n8n": "n8n-api-key", "vercel": "vercel-token", "github": "github-token", "stripe": "stripe-api-key", "notion": "notion-api-key", "calcom": "calcom-api-key"]
        let integrations = AgentTask.integrationAgents.compactMap { agent -> [String: Any]? in
            let id = agent.id.replacingOccurrences(of: "integration_", with: "")
            guard let key = mapping[id], state.activeIntegrations.contains(agent.id) else { return nil }
            return ["name": agent.name, "configured": !(KeychainStore.shared.get(key) ?? "").isEmpty]
        }
        guard let output = try? JSONSerialization.data(withJSONObject: ["integrations": integrations]) else { return #"{"error":"Tool unavailable."}"# }
        return String(data: output, encoding: .utf8) ?? "{}"
    }
}
