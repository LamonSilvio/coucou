# OpenAI and Codex setup

This fork adds OpenAI alongside Anthropic. Claude chat, Claude Code hooks and their existing approvals remain available. This is a development implementation; see [VALIDATION.md](VALIDATION.md) for what has actually been tested.

## Credentials and provider

In Settings, save **Anthropic API Key** and **OpenAI API Key** separately. macOS uses the existing Keychain service with a new `openai-api-key` account; Windows uses the existing Windows Credential Manager service. Do not put keys in configuration files, screenshots, issues, commits or terminal arguments.

Choose **Anthropic**, **OpenAI** or **Auto**. Auto prefers Anthropic when its key exists, otherwise OpenAI. It does not retry a failed request with another provider or transmit the conversation to a fallback service. A provider change clears both backend histories before the next request. New conversation clears local history. History is in memory and does not survive app restart.

ChatGPT subscriptions and OpenAI API billing are separate. API calls, hosted tools and Codex authentication can incur charges under their respective billing arrangements. Coucou has no subscription-based API entitlement. Use your OpenAI project limits and billing controls.

## Models and tools

Select a model by its API identifier. Capability configuration is shared by both platforms in `NotchBuddy/Resources/OpenAIModels.json`, bundled on macOS and compiled into Windows. The default is `gpt-4.1`; `gpt-5` adds configurable reasoning. An unknown model can be used for text, but optional tools, PDF/vision and reasoning are rejected unless its capabilities are registered. This is a conservative maintained catalog, not automatic server-side capability detection. An API model listing alone does not establish tool capabilities.

Settings expose model, reasoning effort, maximum output tokens, Web Search, Code Interpreter and read-only integration status. An incompatible configured tool fails with an actionable message instead of silently removing it. These settings are independent of the Anthropic model.

The client uses **Responses API**, `store:false`, and replays all completed output items for multi-turn context. Reasoning responses request encrypted reasoning content when an effort is selected. Failed or incomplete requests leave successful history intact. Files/window context are attached on the first turn or when changed. Requests use a fixed OpenAI HTTPS origin, disable redirects and use a 120-second timeout.

## Files, vision and window context

Drop a file using the existing island interaction. Images (PNG, JPEG, WebP, GIF) use image input; PDFs and recognized Office formats use direct base64 file input. UTF-8 TXT, Markdown, CSV, JSON and source code use text input. The local limit is 20 MB per file and 200 KB for text. There are no persistent Files API uploads or vector stores. OpenAI retention rules still apply to transmitted content even with `store:false`.

PDF analysis requires a vision-capable model. Office rendering, spreadsheet truncation and supported extensions follow OpenAI's file-input support; sending a recognized extension does not guarantee a malformed document will be accepted. For large datasets or knowledge collections, persistent file search is not implemented.

macOS reuses the existing window capture with the same OS permissions: app name, title and optional URL, not a new screen capture mechanism. The Windows frontend retains the original file context; it does not currently capture window context. Do not drag sensitive files you do not want to transmit to the selected provider.

## Search, analysis and generated files

Web Search uses the official `web_search` tool. Returned URL citations appear as clickable sources. Only HTTP(S) URLs without embedded credentials are admitted. Source pages are untrusted content.

Code Interpreter uses an automatic OpenAI-hosted container. The chat shows tool activity during streaming. Container file citations expose an explicit Save action. macOS asks for a destination; Windows saves into the existing inbox's `generated` folder with a fresh filename and reports the path. Downloads require an artifact registered in the current conversation, use the fixed OpenAI container-file endpoint, cap size at 50 MB and never open or execute the result. Files can expire with the container.

## Function calling, integrations and MCP

The optional `list_integrations` function is a strict, empty-argument, read-only tool. It returns enabled integration names and whether credentials are configured. It shares the existing GitHub, Notion, n8n, Stripe, Vercel, Resend and Cal.com settings; it never returns credentials or performs external actions. Unknown names and extra arguments are rejected. Tool loops are limited to eight Responses requests and only commit history after a usable final answer.

The existing integration pollers keep their original behavior. This implementation does not add payment, deployment, email, repository modification or arbitrary shell tools to OpenAI chat. A three-level permission contract (`safe`, `confirm`, `critical`) reserves explicit user confirmation for effects. Remote Responses MCP servers and their approval requests are not configured; no model-supplied MCP URL can be contacted. Codex-owned MCP item activity may be displayed, but unsupported client approval requests fail closed.

## Codex and Allow / Deny

Install the official Codex CLI and authenticate using `codex login` in your terminal. In Settings, enable the optional integration, enter the absolute executable path and existing project folder, write a task and choose Start Codex. On Windows use the native executable, not a shell command or `.cmd` launcher. Coucou starts its own `codex app-server` over stdio, initializes the connection, starts a thread with `sandbox:readOnly` and `approvalPolicy:untrusted`, then starts a turn. Stop ends only that owned process. No credentials are intercepted.

Command/file approval JSON-RPC requests from the current thread and turn appear in the existing Mochi approval UI. **Allow** sends official `accept`; **Deny** sends `decline`. Decisions are one request at a time, expire after 110 seconds and do not enable session-wide or permanent consent. File changes require an available reviewable diff; proposals over 20,000 characters are denied. Network-specific approvals show the requested host. Unknown server requests return an unsupported-method error. Existing Claude Allow, Deny and Always behavior is unchanged.

Codex monitoring includes session, turn, command, file-change and generic tool activity, completion and errors when supplied by app-server. It does not observe unrelated CLI sessions, invent universal file-read events or offer Jump to Terminal without a reliable terminal identity. Claude retains its existing terminal navigation. The macOS App Store target cannot launch Codex because of its sandbox; the normal source build can.

## Computer use and other limits

Computer use is unavailable and disabled. There is no local screen/keyboard executor or way to enable one through prompts. OpenAI image generation, persistent file search, external write tools, remote MCP authorization and attachment to pre-existing Codex terminal sessions remain unimplemented. Vision is implemented separately from image generation.

Live OpenAI/Anthropic/Codex validation requires credentials and authenticated runtimes on a supported OS. Automated request/adapter tests do not establish that paid API features work for your account.

## Official references checked for this implementation

- [Responses API and migration](https://developers.openai.com/api/docs/guides/migrate-to-responses)
- [Conversation state](https://developers.openai.com/api/docs/guides/conversation-state)
- [File inputs](https://developers.openai.com/api/docs/guides/pdf-files)
- [Images and vision](https://developers.openai.com/api/docs/guides/images-vision)
- [Web Search](https://developers.openai.com/api/docs/guides/tools-web-search)
- [Code Interpreter](https://developers.openai.com/api/docs/guides/tools-code-interpreter)
- [Function calling](https://developers.openai.com/api/docs/guides/function-calling)
- [Remote MCP](https://developers.openai.com/api/docs/guides/tools-remote-mcp)
- [Computer use](https://developers.openai.com/api/docs/guides/tools-computer-use)
- [Image generation](https://developers.openai.com/api/docs/guides/tools-image-generation)
- [Codex app-server](https://developers.openai.com/codex/app-server)

Checked on 2026-09-30. Availability, model access and billing vary; check the official documentation before expanding the catalog or enabling new executors.
