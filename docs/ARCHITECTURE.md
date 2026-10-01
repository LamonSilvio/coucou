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
| Integrations | seven dedicated pollers | integrations.rs and frontend integration state | original polling preserved; manifest-driven write adapters behind central approval |
| UI | AppState, IslandTypes, island state machine, Mochi canvases, sound engines | State, canvas/bot/sound and island views | provider labels, sources/artifact buttons, tool activity and Codex task |

ClaudeService was not rewritten. Its protocol conformance adapts it to the router. The Windows router contains provider dispatch in one place. The original hooks, Claude request format, integrations, character/assets, sound/animation and terminal navigation remain in their compatibility boundary. Credential saves now report failure; macOS updates a key atomically before considering an insertion.

## Chat

`AIProvider` defines chat and conversation reset on macOS. `AIChatRouter` chooses the provider, serializes sends and clears both histories on a provider switch. Rust `ai::Router` provides the equivalent interface under a Tauri async mutex. Both use Anthropic-first Auto selection by secure key presence, without network fallback.

`OpenAIService` / `openai::Chat` own in-memory Responses history and generated-artifact registries. Requests preserve output items, including function calls and encrypted reasoning; consumed MCP grants and generated images receive the safer history treatment described below. A request chain stages state until a complete textual or generated-image response succeeds. Changed context is reattached; repeated context is retained through history. Explicit new conversation and provider switches invalidate artifact downloads too.

The model capability JSON is shared; settings contain no API keys. Hosted web search and code interpreter are capability-checked; function calls are executed only by the fixed ToolManager registry. Runtime API incompatibility produces a sanitized error. Transport timeout, failed stream and incomplete output never commit partial history.

## Agent events and permissions

`AgentEvent` carries provider, session, kind and display detail; Windows transport adds an optional request identifier. Event names are aligned on both platforms: sessionStarted/Ended, statusChanged, fileRead/Modified, commandRequested/Started/Completed, toolStarted/Completed, permissionRequested, agentCompleted/Failed.

Claude adapters translate hook names and tool categories into the common contract. Existing Claude UI reducers continue alongside this event emission to avoid replacing mature session/permission behavior. Thus Claude UI migration to an exclusively common reducer is **not complete**. Codex uses common events to update the existing task/approval views.

CodexAdapter and codex.rs own one child process, its pipes, thread/turn identity, bounded JSONL frames and pending approval IDs. They implement official initialize/initialized, thread/start and turn/start. Generation tokens prevent stale process output and timers from acting on restarted sessions. Unsupported server requests fail closed; no custom permissions or credential scraping are used. File changes show the diff received in item events; absent or oversized previews are denied. Approvals use exact IDs and scope, never a command-name heuristic.

## Central action pipeline

`ActionApprovalCenter` (Swift) and `actions::Approvals` (Rust) own the policy, FIFO pending queue, expiration, cancellation generation and one-shot approval/execution claims. `core/approvals.ts` presents native approvals and original Claude hook cards in one FIFO UI. Risk is recomputed locally; model/server risk declarations cannot lower it. SAFE permits the registered integration status read and computer wait; CONFIRM requires Allow; CRITICAL requires Allow with a prominent risk label. Every desktop input and screenshot upload, every MCP call, unknown workflow effects, email sending, production deployment and financial action is CRITICAL.

Claude retains its official hook response semantics, including Always; each socket is captured by its own queued continuation rather than replaced by another request. Codex approvals enter this same queue, then forward only the official scoped decision to its owned app-server. There is no Always or sandbox bypass for Codex. A single Allow can claim at most one execution. Metadata-only local audit records contain neither parameters nor tool output. Cancellation denies pending approvals and stops subsequent steps; an already approved in-flight remote or native action cannot be undone.

`ExternalActions.json` is the shared operation/parameter catalog. Native adapters construct fixed method/origin/path plans before approval and load the selected integration's secure key only after approval. Pollers are not duplicated. OpenAI calls the strict registered `external_action` function, never arbitrary HTTP or shell clients. See [TOOLS.md](TOOLS.md) for the exact operation list and limits.

`RemoteMCP` / `remote_mcp` build official Responses-hosted MCP tools with `require_approval: always`. Server configuration is nonsecret and locally validated; credentials come from OS secure storage. Imported tool metadata is displayed, not trusted as policy. Empty tool allowlists permit discovery only. Every call requires the central approval queue. Forwarded grants are removed from staged conversation history after that response, preventing later turns from replaying old approval responses. See [MCP.md](MCP.md).

`ComputerUse` / `computer_use` parse current `computer_call.actions[]` and run bounded multi-step Responses continuations. Logical execution and policy are injectable for tests. The Mac executor uses AppKit/Accessibility/CGEvent and permission-gated screenshots; the Windows executor uses fixed PowerShell/.NET code with JSON over stdin, not model-generated scripts. Both restrict inputs to configured browser targets and fail closed on focus/coordinate violations. Screenshot transmission requires a separate critical approval. See [COMPUTER_USE.md](COMPUTER_USE.md).

`ImageWorkflow` / `image_workflow` build current `image_generation` tool requests, parse bounded PNG/base64 results, and classify generation/editing intent separately from vision analysis. Generated images render in existing chat and are replayed as image context for later edits. Native user-selected save dialogs authorize export; no automatic arbitrary filesystem write occurs. Model, size and transparency configuration are centralized.

## Platform differences

macOS reuses native window context and terminal navigation. Windows retains its original file-only chat context and uses native process/credential APIs. Codex has no terminal navigation on either platform because the process is owned through pipes, not an identifiable terminal window. macOS App Store builds explicitly refuse Codex launch and native Computer Use. Both standard desktop targets implement image preview/export, remote MCP and write adapters. Neither implementation monitors arbitrary existing Codex CLI sessions. Automated native builds are not proof of physical desktop permissions or live account capabilities.

See [OPENAI.md](OPENAI.md), [SECURITY.md](SECURITY.md) and [VALIDATION.md](VALIDATION.md). The source remains MIT; original branding/artwork has the separate restrictions in `LICENSE-ASSETS.md`. Building privately and opening a PR are permitted; publishing binaries with the original names/character/icons/sounds requires written permission or rebranding and asset replacement. No release publishing is part of this branch.
