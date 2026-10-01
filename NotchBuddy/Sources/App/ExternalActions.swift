import Foundation

struct ExternalPlan {
    let integration: String; let operation: String; let key: String
    var request: URLRequest
    let parameters: [String: Any]
    static func build(integration: String, operation: String, parameters: [String: Any], webhook: String = "", id: String) throws -> Self {
        guard let url = Bundle.main.url(forResource: "ExternalActions", withExtension: "json"),
              let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [String: Any]],
              let definition = catalog[integration + "." + operation],
              let fields = definition["fields"] as? [String], let required = definition["required"] as? [String],
              Set(parameters.keys).isSubset(of: Set(fields)), required.allSatisfy({ parameters[$0] != nil }) else {
            throw OpenAIError.message("Unsupported external action or parameters.")
        }
        let data = try JSONSerialization.data(withJSONObject: parameters)
        guard data.count <= 12000, !SecretRedaction.sensitive(parameters) else { throw OpenAIError.message("Action contains sensitive or oversized parameters.") }
        var path = definition["path"] as? String ?? ""
        for field in ["owner", "repo", "number", "block_id", "bookingUid"] where path.contains("{\(field)}") {
            let value = String(describing: parameters[field] ?? "")
            guard !value.isEmpty, value != ".", value != "..", value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) }) else { throw OpenAIError.message("Invalid resource identifier.") }
            path = path.replacingOccurrences(of: "{\(field)}", with: value)
        }
        let endpoint = integration == "n8n" ? webhook : (definition["origin"] as! String) + path
        guard let endpointURL = URL(string: endpoint), endpointURL.scheme == "https", endpointURL.host != nil, endpointURL.user == nil, endpointURL.password == nil, endpointURL.query == nil, endpointURL.fragment == nil else { throw OpenAIError.message("Configure a clean HTTPS endpoint without embedded secrets.") }
        var body = parameters.filter { (definition["bodyFields"] as? [String] ?? []).contains($0.key) }
        if integration == "n8n" { guard let input = parameters["input"] as? [String: Any] else { throw OpenAIError.message("Workflow input must be an object.") }; body = input }
        if integration == "vercel" { body["target"] = operation == "production_deploy" ? "production" : "preview" }
        var request = URLRequest(url: endpointURL); request.httpMethod = definition["method"] as? String; request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Coucou", forHTTPHeaderField: "User-Agent")
        if integration == "notion" { request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version") }
        if integration == "calcom" { request.setValue("2026-02-25", forHTTPHeaderField: "cal-api-version") }
        if ["resend", "stripe"].contains(integration) { request.setValue(id, forHTTPHeaderField: "Idempotency-Key") }
        if integration == "stripe" {
            guard let amount = parameters["amount"] as? Int, amount > 0, let intent = parameters["payment_intent"] as? String, OpenAIService.safeID(intent) else { throw OpenAIError.message("Invalid refund parameters.") }
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("payment_intent=\(intent)&amount=\(amount)".utf8)
        } else { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return Self(integration: integration, operation: operation, key: definition["key"] as! String, request: request, parameters: parameters)
    }
}

@MainActor
enum ExternalActions {
    static let tool: [String: Any] = ["type": "function", "name": "external_action", "description": "Propose a Coucou integration write. User approval is required. Supported: github create_issue/comment_issue, notion create_page/append_content, n8n run_workflow, vercel preview_deploy/production_deploy, resend send_email, stripe refund, calcom create_booking. parameters is a JSON object encoded as a string. No credentials or arbitrary URLs.", "strict": true,
        "parameters": ["type": "object", "properties": ["integration": ["type": "string"], "operation": ["type": "string"], "parameters": ["type": "string"]], "required": ["integration", "operation", "parameters"], "additionalProperties": false]]
    static func configuredTool() throws -> [String: Any] {
        guard let url = Bundle.main.url(forResource: "ExternalActions", withExtension: "json"), let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [String: Any]] else { throw OpenAIError.message("Action catalog missing.") }
        var result = tool
        let contracts = catalog.keys.sorted().map { name in
            let definition = catalog[name]!
            return name + " required=" + (definition["required"] as? [String] ?? []).joined(separator: ",") + " allowed=" + (definition["fields"] as? [String] ?? []).joined(separator: ",")
        }.joined(separator: "; ")
        result["description"] = (tool["description"] as! String) + " Contracts: " + contracts + ". Nested parent/properties/children, gitSource and attendee follow the official integration API JSON shapes. Workflow name and effect are review labels; only the user's fixed webhook is contacted. Never claim that model text constitutes human consent."
        return result
    }
    static func execute(arguments: String, id: String, settings: UserDefaults, state: AppState, approvals: ActionApprovalCenter = .shared, keyProvider: (String) -> String? = { KeychainStore.shared.get($0) }, transport: ((URLRequest) async throws -> (Data, HTTPURLResponse))? = nil) async -> String {
        do {
            guard OpenAIService.safeID(id), id.count <= 256 else { throw OpenAIError.message("Invalid action identifier.") }
            guard let data = arguments.data(using: .utf8), let args = try JSONSerialization.jsonObject(with: data) as? [String: String], Set(args.keys) == Set(["integration", "operation", "parameters"]),
                  let integration = args["integration"], let operation = args["operation"], let encoded = args["parameters"]?.data(using: .utf8), let parameters = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
                  state.activeIntegrations.contains("integration_" + integration) else { throw OpenAIError.message("Integration unavailable.") }
            let plan = try ExternalPlan.build(integration: integration, operation: operation, parameters: parameters, webhook: settings.string(forKey: "n8nWebhook") ?? "", id: id)
            var preview = parameters
            preview["destination"] = plan.request.url!.absoluteString
            preview["method"] = plan.request.httpMethod ?? ""
            let action = ActionRequest(id: id, provider: "openai", integration: integration, operation: operation, parameters: preview, risk: ActionRiskEvaluator.risk(integration: integration, operation: operation))
            return await approvals.execute(action) {
                var request = plan.request
                guard let key = keyProvider(plan.key), !key.isEmpty else { throw OpenAIError.message("Missing integration credential.") }
                request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
                let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForResource = 45
                let session = URLSession(configuration: configuration, delegate: NoAIRedirects(), delegateQueue: nil); defer { session.invalidateAndCancel() }
                let data: Data; let response: HTTPURLResponse
                if let transport { (data, response) = try await transport(request) }
                else { (data, response) = try await Self.send(session, request) }
                guard (200..<300).contains(response.statusCode), data.count <= 2_000_000 else { throw OpenAIError.message("Integration write failed.") }
                let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                return String(data: try JSONSerialization.data(withJSONObject: ["success": true, "id": result["id"] ?? (result["data"] as? [String: Any])?["uid"] ?? "", "status": response.statusCode]), encoding: .utf8)!
            }
        } catch { return #"{"error":"External action rejected. Check supported fields and enabled integrations."}"# }
    }
    private static func send(_ session: URLSession, _ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        for try await byte in bytes { guard data.count < 2_000_000 else { throw OpenAIError.message("Integration response exceeds limit.") }; data.append(byte) }
        guard let http = response as? HTTPURLResponse else { throw OpenAIError.message("Invalid integration response.") }; return (data, http)
    }
}
