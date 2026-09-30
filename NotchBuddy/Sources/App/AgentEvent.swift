import Foundation

enum AgentEventKind: String, Codable, Sendable {
    case sessionStarted, sessionEnded, statusChanged, fileRead, fileModified
    case commandRequested, commandStarted, commandCompleted, toolStarted, toolCompleted
    case permissionRequested, agentCompleted, agentFailed
}

struct AgentEvent: Codable, Sendable {
    var provider: String
    var session: String
    var kind: AgentEventKind
    var detail: String
}

enum ClaudeCodeAdapter {
    static func event(_ name: String, session: String, tool: String = "") -> AgentEvent? {
        let map: [String: AgentEventKind] = ["SessionStart": .sessionStarted, "SessionEnd": .sessionEnded,
            "UserPromptSubmit": .statusChanged, "PreToolUse": .toolStarted, "PostToolUse": .toolCompleted,
            "PermissionRequest": .permissionRequested, "Stop": .agentCompleted, "StopFailure": .agentFailed,
            "PostToolUseFailure": .agentFailed]
        guard var kind = map[name] else { return nil }
        if name == "PreToolUse" {
            if tool == "Read" { kind = .fileRead }
            if ["Edit", "Write", "MultiEdit"].contains(tool) { kind = .fileModified }
            if ["Bash", "PowerShell"].contains(tool) { kind = .commandStarted }
        }
        return AgentEvent(provider: "claudeCode", session: session, kind: kind, detail: tool)
    }
}

enum SecurityLevel: String, Codable { case safe, confirm, critical }

// Only registered tools may execute. A model's claimed risk or consent is never trusted.
struct ToolPermission {
    let level: SecurityLevel
    func permits(explicitConfirmation: Bool) -> Bool { level == .safe || explicitConfirmation }
}
