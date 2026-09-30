# Security review: OpenAI and Codex additions

This is a code review and automated-test record, not a penetration-test certification. Live API, authenticated Codex and physical desktop interactions require further validation.

## Trust boundaries and controls

- Keys stay in the existing macOS Keychain / Windows Credential Manager. Preferences and the capability catalog contain no secret. Keychain access remains WhenUnlockedThisDeviceOnly, non-synchronizing. Save failure does not update the in-memory key cache, and an update failure does not delete the old macOS key.
- API request and generated-file endpoints are fixed to OpenAI HTTPS. Redirects are disabled so bearer credentials cannot follow a model-provided URL. Authentication/quota/incompatibility/network messages are sanitized; API bodies are not shown or logged.
- Web results, window metadata, documents, repository content and MCP output are untrusted. Instructions explicitly describe this boundary, but prompt text alone is not treated as a security control. Only the strict registered read-only status function can execute in Responses chat. Unknown tool names and unexpected arguments cannot become shell commands, URLs or external actions.
- Confirm/critical actions cannot use model-provided claims of consent. Computer use and Responses remote MCP are unavailable, so no prompt can enable them. Adding external write tools requires an approval executor tied to concrete action parameters; the present registry has none.
- File inputs are bounded regular files, with model capability checks. There is no automatic vector-store or persistent upload creation. `store:false` avoids stored Responses objects; it does not promise zero provider retention or exempt content from OpenAI's policies.
- Citations admit HTTP(S) without embedded credentials. Pages opened by the user remain untrusted and may be malicious; Coucou does not fetch source pages itself with API credentials. No generated HTML or Markdown is interpreted as application code.
- Generated files require a citation registered in the current conversation and safe container/file IDs. Downloads have a 50 MB limit, disable redirects and use a fixed authenticated origin. macOS requires a save-panel choice; Windows generates a basename-only unique path with create-new semantics. Files are never automatically opened/executed. Model-produced files remain untrusted.
- Codex starts only an explicitly configured absolute executable with a project folder and fixed `app-server` argument, without shell interpolation. The executable/workspace selected by the user is a trust boundary. The initial official policy is readOnly/untrusted; requested expansion uses app-server approvals, without bypassing the sandbox.
- Codex JSONL frames are bounded. Approvals are scoped to the owned thread, active turn, request ID and process generation; duplicates, unavailable UI, unsupported requests, absent diffs and oversized proposals cannot obtain silent approval. One-shot decisions expire after 110 seconds. There is no Always option for Codex.
- Claude approvals retain their original mechanism. Original hook diagnostics no longer print full command/tool input. Added diagnostics/events contain provider/status metadata; private document bodies, auth headers and raw API errors are not logged. Commands/diffs shown in the approval UI are deliberately reviewable local content, not diagnostics.

## Checks and residual risks

Tests exercise capability rejection, provider selection/switch resets, failed-request rollback, text/PDF input limits, secure-store round trips, unknown tool rejection, official approval decisions and wrong-thread/turn rejection. Source review covered prompt injection, malicious URLs/paths, credential forwarding, shell execution, MCP approvals and conversation cross-provider leakage.

Remaining limitations: native UI approvals and actual Codex behavior have not been exercised with an authenticated installation; no general risk classifier or computer-use executor exists; the legacy Claude reducers still own their established behavior. Existing integration clients and hook security are preserved rather than comprehensively rewritten. A malicious selected executable is not sandboxed by Coucou itself. Hosted code interpreter executes in OpenAI's container, not the local machine.

For credentialed tests, enter API keys only in application Settings on the supported OS. Authenticate Codex through its official CLI. Do not paste credentials into chats, PRs, CI logs or source files. CI uses synthetic test values and temporary credential entries that tests delete.
