import Foundation

struct ActionRequest: Identifiable {
    let id: String
    let provider: String
    let integration: String
    let operation: String
    let parameters: [String: Any]
    let risk: SecurityLevel
    var preview: String {
        let data = (try? JSONSerialization.data(withJSONObject: SecretRedaction.value(parameters), options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return "Provider: \(provider)\nServer / Integration: \(integration)\nAction: \(operation)\nRisk: \(risk.rawValue.uppercased())\n" + SecretRedaction.text(String(data: data, encoding: .utf8) ?? "{}")
    }
}

enum ActionRiskEvaluator {
    static func risk(integration: String, operation: String) -> SecurityLevel {
        if integration == "computer" { return operation == "wait" ? .safe : .critical }
        if integration == "mcp" || integration == "codex" { return .critical } // Server annotations are not authority.
        if ["stripe", "n8n"].contains(integration) || ["send_email", "production_deploy", "cancel_booking"].contains(operation) { return .critical }
        if operation == "list_integrations" { return .safe }
        return .confirm
    }
}

enum SecretRedaction {
    static func value(_ input: Any) -> Any {
        if let object = input as? [String: Any] {
            return object.mapValues { value in Self.value(value) }.reduce(into: [String: Any]()) { result, pair in
                let key = pair.key.lowercased()
                result[pair.key] = key == "key" || ["password", "token", "secret", "authorization", "cookie", "api_key", "api-key", "apikey"].contains(where: key.contains) ? "[REDACTED]" : pair.value
            }
        }
        if let array = input as? [Any] { return array.map(Self.value) }
        if let string = input as? String { return text(string) }
        return input
    }
    static func sensitive(_ input: [String: Any]) -> Bool {
        guard let original = try? JSONSerialization.data(withJSONObject: input, options: .sortedKeys), let redacted = try? JSONSerialization.data(withJSONObject: value(input), options: .sortedKeys) else { return true }
        return original != redacted
    }
    static func text(_ text: String) -> String {
        var result = text
        for pattern in [#"(?i)(sk-[\w-]{8,}|gh[pousr]_[\w]{8,}|Bearer\s+[^\s\"]+)"#, #"(?i)\"[^\"]*(?:password|token|secret|authorization|cookie|api.?key)[^\"]*\"\s*:\s*\"[^\"]*\""#] {
            result = result.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
        }
        return result
    }
}

@MainActor
final class ActionApprovalCenter {
    static let shared = ActionApprovalCenter()
    struct Pending { let action: ActionRequest; let finish: (String) -> Void }
    private(set) var queue: [Pending] = []
    private var decided: Set<String> = []
    private var executed: Set<String> = []
    private var approved: Set<String> = []
    private(set) var generation = 0
    private var legacy: [String: ApprovalInfo] = [:]
    private let present: (ActionRequest) -> Void
    private let available: () -> Bool
    private let clear: (String) -> Void
    private let audit: (ActionRequest, String) -> Void
    init(present: ((ActionRequest) -> Void)? = nil, available: (() -> Bool)? = nil, clear: ((String) -> Void)? = nil, audit: ((ActionRequest, String) -> Void)? = nil) {
        self.present = present ?? { action in
            let state = AppState.shared
            state.pendingApproval = ApprovalInfo(sessionId: "", tool: action.integration, command: action.preview, provider: "actions", requestID: action.id)
            state.isPinned = true; state.view = .approval
            NotificationCenter.default.post(name: .hookExpand, object: IslandView.approval)
        }
        self.available = available ?? { AppState.shared.pendingApproval == nil && AppState.shared.isPresent }
        self.clear = clear ?? { id in
            let state = AppState.shared
            if state.pendingApproval?.requestID == id {
                state.pendingApproval = nil; state.isPinned = false; state.view = .prompt
            }
        }
        self.audit = audit ?? Self.writeAudit
    }
    func authorize(_ action: ActionRequest, timeout: Duration = .seconds(110)) async -> Bool {
        guard action.risk == ActionRiskEvaluator.risk(integration: action.integration, operation: action.operation), !decided.contains(action.id), !queue.contains(where: { $0.action.id == action.id }), action.preview.count <= 24000 else { return false }
        if action.risk == .safe { decided.insert(action.id); approved.insert(action.id); audit(action, "approved"); return true }
        return await withCheckedContinuation { continuation in
            queue.append(Pending(action: action, finish: { continuation.resume(returning: $0 == "allow") }))
            pump()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resolve(action.id, allow: false)
            }
        }
    }
    func resolve(_ id: String, allow: Bool) {
        resolve(id, decision: allow ? "allow" : "deny")
    }
    func enqueueLegacy(_ action: ActionRequest, info: ApprovalInfo, finish: @escaping (String) -> Void) {
        guard !decided.contains(action.id), !queue.contains(where: { $0.action.id == action.id }) else { finish("deny"); return }
        legacy[action.id] = info
        queue.append(Pending(action: action, finish: finish)); pump()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(110))
            self?.resolve(action.id, decision: info.provider == "claudeCode" ? "ask" : "deny")
        }
    }
    func resolve(_ id: String, decision: String) {
        let allow = decision == "allow" || (decision == "always" && legacy[id]?.provider == "claudeCode")
        if allow && queue.first?.action.id != id { return }
        guard !decided.contains(id), let index = queue.firstIndex(where: { $0.action.id == id }) else { return }
        let pending = queue.remove(at: index); decided.insert(id)
        if allow { approved.insert(id) }
        legacy.removeValue(forKey: id)
        clear(id); audit(pending.action, allow ? "approved" : "denied")
        pending.finish(allow ? decision : decision == "ask" ? "ask" : "deny"); pump()
    }
    func cancelAll() {
        generation += 1
        approved.formIntersection(executed) // Revoke Allow decisions whose executor has not started.
        for id in queue.map({ $0.action.id }) { resolve(id, allow: false) }
    }
    func claimExecution(_ id: String) -> Bool { approved.contains(id) && executed.insert(id).inserted }
    func record(_ action: ActionRequest, outcome: String) { audit(action, outcome) }
    func execute(_ action: ActionRequest, executor: () async throws -> String) async -> String {
        guard await authorize(action), claimExecution(action.id) else { return #"{"error":"Action denied, expired or already executed."}"# }
        do { let result = try await executor(); audit(action, "success"); return result }
        catch { audit(action, "failure"); return #"{"error":"Action failed. Check integration configuration; do not retry an uncertain write without verifying its outcome."}"# }
    }
    private func pump() {
        guard let action = queue.first?.action else { return }
        if available() { present(action); if let info = legacy[action.id] { AppState.shared.pendingApproval = info } }
        else { Task { @MainActor [weak self] in try? await Task.sleep(for: .milliseconds(200)); self?.pump() } }
    }
    private static func writeAudit(_ action: ActionRequest, _ outcome: String) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Coucou", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("actions-audit.jsonl")
            let row: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()), "provider": action.provider, "integration": action.integration, "action": action.operation, "risk": action.risk.rawValue, "outcome": outcome]
            var data = try JSONSerialization.data(withJSONObject: row); data.append(10)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
            try file.seekToEnd(); try file.write(contentsOf: data)
        } catch { /* No sensitive error details are logged. */ }
    }
}
