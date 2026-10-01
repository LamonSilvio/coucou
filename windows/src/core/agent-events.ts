// Public, provider-neutral event contract. Transport-specific payloads stay in adapters.
export type AgentEventKind = "sessionStarted" | "sessionEnded" | "statusChanged" | "fileRead" | "fileModified" |
  "commandRequested" | "commandStarted" | "commandCompleted" | "toolStarted" | "toolCompleted" |
  "permissionRequested" | "agentCompleted" | "agentFailed";
export interface AgentEvent {
  provider: "claudeCode" | "codex";
  session: string; kind: AgentEventKind; detail: string; requestId?: string | null;
}
export function claudeEvent(name: string, session: string, tool = ""): AgentEvent | null {
  const map: Record<string, AgentEventKind> = {SessionStart:"sessionStarted",SessionEnd:"sessionEnded",
    UserPromptSubmit:"statusChanged",PreToolUse:"toolStarted",PostToolUse:"toolCompleted",PermissionRequest:"permissionRequested",
    Stop:"agentCompleted",StopFailure:"agentFailed",PostToolUseFailure:"agentFailed"};
  let kind = map[name]; if (!kind) return null;
  if (name === "PreToolUse") {
    if (tool === "Read") kind = "fileRead";
    if (["Write","Edit","MultiEdit"].includes(tool)) kind = "fileModified";
    if (["Bash","PowerShell"].includes(tool)) kind = "commandStarted";
  }
  return {provider:"claudeCode",session,kind,detail:tool};
}
export type SecurityLevel = "safe" | "confirm" | "critical";
export function permits(level: SecurityLevel, explicitConfirmation: boolean): boolean {
  return level === "safe" || explicitConfirmation;
}
