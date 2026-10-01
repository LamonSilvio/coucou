# OpenAI Computer Use

**OFF by default.** Enable in Settings only after reading these limits. Coucou uses the current official structured Responses tool `{"type":"computer"}`, parses `computer_call.actions`, executes approved supported actions, and returns `computer_call_output` with an original-detail PNG screenshot. It does not use the deprecated singular preview-action contract, arbitrary generated scripts, terminal execution or a security bypass.

## Setup and platform capabilities

Select a computer-capable model in the shared capability catalog (currently `gpt-6.1-sol`), enable Computer Use and choose an already-open browser:

| Platform | Targets | Required local permissions |
|---|---|---|
| macOS normal source build | Safari, Chrome, Firefox, Edge bundle identifiers | Accessibility and Screen Recording in System Settings |
| macOS App Store build | None | Desktop Computer Use is rejected because of sandbox limitations |
| Windows native build | msedge, chrome, firefox process names | Interactive desktop, permitted input/capture; elevated/protected windows may reject input |

Only the primary display is supported. The selected browser must be identifiable and foregrounded; coordinates are checked against screen bounds and the actual target application/window. Actions outside that browser fail closed. Keep other applications and sensitive windows off the primary display. Screenshot capture covers the primary display, **not a redacted browser-only crop**.

## Supported actions and policy

Screenshot, wait, move, click, double-click, scroll, type, keypress and bounded drag paths are parsed explicitly. Clipboard, modifier shortcuts, shell/script actions and unknown action types are rejected. Only Enter/Tab/Escape/Backspace/arrows are accepted keys. Typed text is bounded and recognized secret patterns are blocked. Secure/password fields are rejected where the OS exposes their security attribute.

Waiting is SAFE. **All desktop input—including movement/scrolling—and each screenshot transmission are CRITICAL and require explicit approval.** Even a browser hover can trigger page code, so a server/page claim that an input is safe does not lower risk. Pending OpenAI safety checks require approval before any action. A separate, clearly labeled screenshot consent covers transmission; screenshot-only requests are not prompted twice for the same capture.

The executor cannot reliably recognize every site's financial/security semantics or a secret in an ordinary text field. Human CRITICAL review is therefore mandatory; Coucou does not promise semantic redaction of all pixels or isolation from a malicious browser page. Do not use it with logged-in payment, credential-management or other sensitive pages. Treat every screenshot, website and model instruction as untrusted; none can alter native policy.

## Runtime controls

The existing chat and Mochi approval views are reused. At most 20 actions are admitted per call and 32 Responses rounds per chat request. Each API request has a 120-second timeout; approvals expire after at most 110 seconds. Mac screen capture is bounded to 10 seconds; Windows fixed native helper processes to 45 seconds including cold .NET compilation. The separate user save dialog allows 600 seconds. Generated/captured PNGs are size/resolution bounded. No arbitrary model code is passed to PowerShell: Windows uses a fixed embedded script and newline-framed JSON on stdin; macOS uses native Accessibility/CoreGraphics and a fixed screenshot executable.

Cancel denies queued actions and invalidates the active request. No subsequent batch action or screenshot transmission may proceed after cancellation. An already-approved local action may finish within its bounded native timeout; cancellation is not rollback and cannot undo an already-approved remote effect. Temporary macOS screenshots are removed, and audit logs contain metadata only—not screenshots, typed text, commands or tokens.

Tests cover parsing, mocked native execution, safety ordering, denial, central timeout/one-shot behavior and full mocked Responses continuations. Windows also starts the fixed driver with `wait`, exercising script/bootstrap without controlling a desktop. Real screenshots, mouse/keyboard actions and OS permission dialogs require a supported interactive machine and explicit acceptance testing; they are not claimed as live PASS.

Official reference: [Computer use](https://developers.openai.com/api/docs/guides/tools-computer-use), checked 2026-09-30.
