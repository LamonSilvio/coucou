# Multi-provider architecture

## Repository map and compatibility boundary

The repository has two implementations: `NotchBuddy/Sources/App` is a SwiftUI macOS app; `windows/src` is the Tauri TypeScript frontend and `windows/src-tauri/src` is its Rust backend. The existing macOS App Store target has stricter sandbox limitations. `project.yml` is the authoritative XcodeGen specification; regenerate the project before running the new test target. The checked-in Xcode project also includes the new app sources and model resource for both app targets.

Before implementation, the original main revision `5ae7bd946ab51493b5ddaebdc5f449f269ebb421` was inspected: README, code and asset licenses, all app/backend/frontend source areas, hook scripts, integration pollers, secure stores, build specifications and workflows. Native baseline builds are reproduced in CI from that exact revision rather than conflated with candidate results.

| Area | Existing macOS | Existing Windows | Extension |
|---|---|---|---|
| Chat | ClaudeService, Anthropic Messages, history and hosted tools | claude.rs, Anthropic client | AIChatRouter / ai::Router delegates to original Claude client or Responses client |
| Settings/secrets | AppStorage preferences; KeychainStore cache | persisted Settings; Credential Manager | separate OpenAI key, provider/model/tool preferences |
| Coding agent | HookServer, Claude Code scripts, sessions and pending approvals | hooks.rs listener and hooks.ts state handling | owned Codex stdio app-server, scoped JSON-RPC decisions |
| Context | FileDropView and WindowContextCapture | native inbox/files and frontend drop state | same UI context translated to Responses input |
| Integrations | seven dedicated pollers | integrations.rs and frontend integration state | same settings; allowlisted read-only function registry |
| UI | AppState, IslandTypes, island state machine, Mochi canvases, sound engines | State, canvas/bot/sound and island views | provider labels, sources/artifact buttons, tool activity and Codex task |

ClaudeService was not rewritten. Its protocol conformance adapts it to the router. The Windows router contains provider dispatch in one place. The original hooks, Claude request format, integrations, character/assets, sound/animation and terminal navigation remain in their compatibility boundary. Credential saves now report failure; macOS updates a key atomically before considering an insertion.

## Chat

`AIProvider` defines chat and conversation reset on macOS. `AIChatRouter` chooses the provider, serializes sends and clears both histories on a provider switch. Rust `ai::Router` provides the equivalent interface under a Tauri async mutex. Both use Anthropic-first Auto selection by secure key presence, without network fallback.

`OpenAIService` / `openai::Chat` own in-memory Responses history and generated-artifact registries. Requests preserve output items, including function calls and encrypted reasoning. A request chain stages state until a complete textual response succeeds. Changed context is reattached; repeated context is retained through history. Explicit new conversation and provider switches invalidate artifact downloads too.

The model capability JSON is shared; settings contain no API keys. Hosted web search and code interpreter are capability-checked; function calls are executed only by the fixed ToolManager registry. Runtime API incompatibility produces a sanitized error. Transport timeout, failed stream and incomplete output never commit partial history.

## Agent events and permissions

`AgentEvent` carries provider, session, kind and display detail; Windows transport adds an optional request identifier. Event names are aligned on both platforms: sessionStarted/Ended, statusChanged, fileRead/Modified, commandRequested/Started/Completed, toolStarted/Completed, permissionRequested, agentCompleted/Failed.

Claude adapters translate hook names and tool categories into the common contract. Existing Claude UI reducers continue alongside this event emission to avoid replacing mature session/permission behavior. Thus Claude UI migration to an exclusively common reducer is **not complete**. Codex uses common events to update the existing task/approval views.

CodexAdapter and codex.rs own one child process, its pipes, thread/turn identity, bounded JSONL frames and pending approval IDs. They implement official initialize/initialized, thread/start and turn/start. Generation tokens prevent stale process output and timers from acting on restarted sessions. Unsupported server requests fail closed; no custom permissions or credential scraping are used. File changes show the diff received in item events; absent or oversized previews are denied. Approvals use exact IDs and scope, never a command-name heuristic.

`safe` permits registered read-only tools. `confirm` and `critical` require an explicit UI decision. The current Responses registry contains only a safe status tool. Codex decisions pass through its own official sandbox/approval protocol. Computer use has no executor and stays disabled.

## Platform differences

macOS reuses native window context and terminal navigation. Windows retains its original file-only chat context and uses native process/credential APIs. Codex has no terminal navigation on either platform because the process is owned through pipes, not an identifiable terminal window. macOS App Store builds explicitly refuse Codex launch. Neither implementation monitors arbitrary existing Codex CLI sessions.

See [OPENAI.md](OPENAI.md), [SECURITY.md](SECURITY.md) and [VALIDATION.md](VALIDATION.md). The source remains MIT; original branding/artwork has the separate restrictions in `LICENSE-ASSETS.md`. Building privately and opening a PR are permitted; publishing binaries with the original names/character/icons/sounds requires written permission or rebranding and asset replacement. No release publishing is part of this branch.
