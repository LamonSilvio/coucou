# OpenAI and Codex setup

This fork adds OpenAI alongside Anthropic. Claude chat, Claude Code hooks and their existing approvals remain available. This is a development implementation; see [VALIDATION.md](VALIDATION.md) for what has actually been tested.

## Credentials and provider

In Settings, save **Anthropic API Key** and **OpenAI API Key** separately. macOS uses the existing Keychain service with a new `openai-api-key` account; Windows uses the existing Windows Credential Manager service. Do not put keys in configuration files, screenshots, issues, commits or terminal arguments.

Choose **Anthropic**, **OpenAI** or **Auto**. Auto prefers Anthropic when its key exists, otherwise OpenAI. It does not retry a failed request with another provider or transmit the conversation to a fallback service. A provider change clears both backend histories before the next request. New conversation clears local history. History is in memory and does not survive app restart.

ChatGPT subscriptions and OpenAI API billing are separate. API calls, hosted tools and Codex authentication can incur charges under their respective billing arrangements. Coucou has no subscription-based API entitlement. Use your OpenAI project limits and billing controls.

## Models and tools

Select a model by its API identifier. Capability configuration is shared by both platforms in `NotchBuddy/Resources/OpenAIModels.json`, bundled on macOS and compiled into Windows. The default is `gpt-4.1`; `gpt-5` adds configurable reasoning. An unknown model can be used for text, but optional tools, PDF/vision and reasoning are rejected unless its capabilities are registered. This is a conservative maintained catalog, not automatic server-side capability detection. An API model listing alone does not establish tool capabilities.

Settings expose model, reasoning effort, maximum output tokens, Web Search, Code Interpreter, read-only integration status, external writes, image generation/editing, and Computer Use. Computer Use and new optional tools are OFF by default. The catalog includes `gpt-6.1-sol` with the structured computer tool. Image model, size and transparency are configured separately. Incompatible tools fail clearly instead of being silently removed. These settings are independent of the Anthropic model.

The client uses **Responses API**, `store:false`, and replays completed history for multi-turn context. Generated images become inline image inputs so editing does not depend on stored responses. Consumed MCP approval grants are removed; prior MCP results become bounded untrusted text, not reusable authorization objects. Reasoning requests encrypted content when an effort is selected. Failed/incomplete requests leave successful history intact. Context is attached initially or when changed. Requests use a fixed OpenAI HTTPS origin, disable redirects and use a 120-second resource timeout.

## Files, vision and window context

Drop a file using the existing island interaction. Images (PNG, JPEG, WebP, GIF) use image input; PDFs and recognized Office formats use direct base64 file input. UTF-8 TXT, Markdown, CSV, JSON and source code use text input. The local limit is 20 MB per file and 200 KB for text. There are no persistent Files API uploads or vector stores. OpenAI retention rules still apply to transmitted content even with `store:false`.

PDF analysis requires a vision-capable model. Office rendering, spreadsheet truncation and supported extensions follow OpenAI's file-input support; sending a recognized extension does not guarantee a malformed document will be accepted. For large datasets or knowledge collections, persistent file search is not implemented.

macOS reuses the existing window capture with the same OS permissions: app name, title and optional URL, not a new screen capture mechanism. The Windows frontend retains the original file context; it does not currently capture window context. Do not drag sensitive files you do not want to transmit to the selected provider.

## Search, analysis and generated files

Web Search uses the official `web_search` tool. Returned URL citations appear as clickable sources. Only HTTP(S) URLs without embedded credentials are admitted. Source pages are untrusted content.

Code Interpreter uses an automatic OpenAI-hosted container. The chat shows tool activity during streaming. Container file citations expose an explicit Save action. macOS asks for a destination; Windows saves into the existing inbox's `generated` folder with a fresh filename and reports the path. Downloads require an artifact registered in the current conversation, use the fixed OpenAI container-file endpoint, cap size at 50 MB and never open or execute the result. Files can expire with the container.

## Function calling, integrations and MCP

The optional `list_integrations` function is a strict, empty-argument, read-only tool. It returns enabled integration names and whether credentials are configured. It shares the existing GitHub, Notion, n8n, Stripe, Vercel, Resend and Cal.com settings; it never returns credentials or performs external actions. Unknown names and extra arguments are rejected. Tool loops are bounded to eight Responses requests, or 32 with Computer Use enabled, and only commit history after a usable final text/image answer.

Existing integration pollers keep their behavior and credentials. The strict optional `external_action` function proposes allowlisted writes documented in [TOOLS.md](TOOLS.md). Native validation, risk evaluation and the shared queue run before reading a write credential or contacting an integration. No arbitrary URL/shell function is registered. MCP uses the official Responses-hosted remote MCP tool, always requires approval, and accepts only locally configured endpoints/tools; see [MCP.md](MCP.md). Tool loops use at most eight Responses requests, or 32 when Computer Use is enabled.

## Codex and Allow / Deny

Install the official Codex CLI and authenticate using `codex login` in your terminal. In Settings, enable the optional integration, enter the absolute executable path and existing project folder, write a task and choose Start Codex. On Windows use the native executable, not a shell command or `.cmd` launcher. Coucou starts its own `codex app-server` over stdio, initializes the connection, starts a thread with `sandbox:readOnly` and the official wire value `approvalPolicy:unlessTrusted`, then starts a turn. The CLI spelling `untrusted` is not the app-server enum. Stop ends only that owned process. No credentials are intercepted.

Command/file approval JSON-RPC requests from the current thread and turn enter the shared Mochi approval queue. **Allow** forwards official `accept`; **Deny** forwards `decline`. Decisions expire after 110 seconds and do not enable session-wide or permanent consent. Available file diffs are reviewed; absent diffs or proposals over 20,000 characters are denied. Network-specific approvals show the host. Unknown server requests fail closed. Existing Claude Allow/Deny and macOS Always wire semantics are preserved; queued Claude expiry returns control to its terminal instead of inventing permission events.

Codex monitoring includes session, turn, command, file-change and generic tool activity, completion and errors when supplied by app-server. It does not observe unrelated CLI sessions, invent universal file-read events or offer Jump to Terminal without a reliable terminal identity. Claude retains its existing terminal navigation. The macOS App Store target cannot launch Codex because of its sandbox; the normal source build can.

## Computer use and other limits

Computer Use has logical/native executors on macOS and Windows, is OFF by default, and controls only the configured supported browser. Every desktop input event and screenshot transmission requires explicit CRITICAL approval; only waiting is SAFE. The App Store target cannot use desktop Computer Use. See [COMPUTER_USE.md](COMPUTER_USE.md).

Enable **Image generation / editing** to use the official Responses `image_generation` tool. Image models are configured once in the shared catalog (default `gpt-image-2.5-sunburst`). Sizes: auto, 1024x1024, 1536x1024, 1024x1536; transparent background and PNG output are configurable. Text creation and dropped-image edits use generate/edit intent when recognized, otherwise the official auto mode. Image questions remain vision requests. Completed base64 PNG results are bounded/validated, previewed in the existing chat, and saved only through the user's native save dialog. Follow-up edits reuse inline image context. Cancel stops the request chain; it cannot reverse a provider call already underway. There is no automatic arbitrary-directory save.

Persistent file search/vector stores, arbitrary-desktop/code executors and attachment to unrelated Codex terminal sessions remain outside this implementation. See the precise adapter/platform limits in the linked guides.

Live OpenAI/Anthropic/Codex validation requires credentials and authenticated runtimes on a supported OS. Automated request/adapter tests do not establish that paid API features work for your account.

## Official references checked for this implementation

- [Responses API and migration](https://developers.openai.com/api/docs/guides/migrate-to-responses)
- [Conversation state](https://developers.openai.com/api/docs/guides/conversation-state)
- [File inputs](https://developers.openai.com/api/docs/guides/pdf-files)
- [Images and vision](https://developers.openai.com/api/docs/guides/images-vision)
- [Web Search](https://developers.openai.com/api/docs/guides/tools-web-search)
- [Code Interpreter](https://developers.openai.com/api/docs/guides/tools-code-interpreter)
- [Function calling](https://developers.openai.com/api/docs/guides/function-calling)
- [Remote MCP](https://developers.openai.com/api/docs/guides/tools-connectors-mcp)
- [Computer use](https://developers.openai.com/api/docs/guides/tools-computer-use)
- [Image generation](https://developers.openai.com/api/docs/guides/tools-image-generation)
- [Codex app-server](https://developers.openai.com/codex/app-server)

Checked on 2026-09-30. Availability, model access and billing vary; check the official documentation before expanding the catalog or enabling new executors.
