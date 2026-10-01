# Remote MCP

Coucou uses OpenAI's official Responses-hosted remote MCP mechanism, not a custom protocol proxy. OpenAI handles the configured server's supported HTTP/SSE transport, import/discovery and actual tool execution. Coucou validates configuration, supplies authorization from OS secure storage, parses discovery/results, and mediates every approval before returning `mcp_approval_response`. This feature is currently offered through the OpenAI chat adapter, not injected into Claude's existing client.

## Configuration

In Settings → Remote MCP, save JSON containing only these fields:

```json
[
  {
    "name": "my_server",
    "endpoint": "https://your-server.example/mcp",
    "enabled": true,
    "tools": []
  }
]
```

Replace the example with your trusted server. Names are unique, up to 32 ASCII letters/digits/underscore/hyphen. At most eight servers are accepted. Tool names use the same safe identifier alphabet (up to 200 characters). HTTPS endpoints must have no user/password, query or fragment. Unknown fields—including inline tokens/authorization—are rejected before saving. Configuration is nonsecret preferences; tokens never belong in it.

An empty `tools` list is **discovery-only**: ask OpenAI chat to list this server's tools. The request uses `require_approval:always`; all attempted calls are locally denied while the allowlist is empty. `mcp_list_tools` results list names in chat. Add selected names to `tools`, save, then request a tool call. Nonempty allowlists are also sent through the official `allowed_tools` field. A model cannot add a server, change its endpoint or expand its allowlist.

Public servers need no token. For authenticated servers, obtain the server's appropriately scoped OAuth/access token through its own authorization procedure; enter it in the separate password field and save under the server name. Accounts are `mcp-token-<name>` in macOS Keychain or Windows Credential Manager. The value is supplied as the official `authorization` parameter on every Responses request and is not written into chat history or logs. Coucou does not implement interactive OAuth registration/refresh; replace expired tokens securely in Settings. No provider credential is substituted for a missing MCP token.

## Permission and connection lifecycle

Every call is conservatively **CRITICAL**, even when a server advertises `readOnlyHint`. Server descriptions, annotations, output and instructions are untrusted data, not policy. Mochi shows provider, server, tool, redacted arguments and risk, then Deny/Allow. Unknown servers/tools, sensitive arguments and oversized previews fail closed. Denial is returned through the official approval response; it does not invoke a local bypass executor.

Approvals are queued, expire, cancel and cannot be reused. Forwarded grants are removed after the API response; later history contains only bounded untrusted result text, preventing replay of an earlier authorization. The native audit records decision and observed tool success/failure without parameters or output bodies.

Connections are request-scoped through Responses. Saving configuration cancels pending actions and reconnects on the next request; disabling a server prevents future access. Disconnect/cancel closes the local request chain; it cannot revoke a remote action already approved and executing. There are no silent write retries. OpenAI request timeouts are 120 seconds; server failures are represented in discovery/results or sanitized chat errors. Verify any uncertain remote write before requesting another one.

Authentication, reachability, server policy and model access still need live acceptance tests. Mock discovery/approval/continuation and secure-store tests do not prove a specific remote server works.

Official reference: [MCP servers](https://developers.openai.com/api/docs/guides/tools-connectors-mcp), checked 2026-09-30.
