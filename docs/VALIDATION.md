# Validation record

## Baseline and automated checks

Original main: `5ae7bd946ab51493b5ddaebdc5f449f269ebb421`.

Native checks run on GitHub-hosted macOS and Windows runners; this editing environment lacks Xcode and Rust. The [multi-provider workflow](../.github/workflows/multiprovider.yml) builds the original baseline and candidate separately. The original macOS and Windows builds and original Rust tests passed. No baseline branch or main file was edited.

The candidate at `45eef52b0b6177ac85e236d57117884555872961` passed [run 36780331417](https://github.com/LamonSilvio/coucou/actions/runs/36780331417):

| Check | Result |
|---|---|
| macOS checked-in Xcode project, Debug app | PASS |
| macOS regenerated project, Debug app | PASS |
| macOS App Store target, Debug app | PASS |
| Swift XCTest | 13 passed, 0 failed |
| Windows TypeScript/Vite production build | PASS |
| Windows Tauri native production build, no bundle | PASS |
| Rust workspace tests | 19 passed, 0 failed |
| TypeScript agent/permission tests | 16 passed, 0 failed |
| Shared Python configuration checks | 3 passed, 0 failed |

Total: **51 tests passed, 0 failed** at that revision, counting each suite once rather than repeated CI runs. The final code revision below also passed these checks. Original release macOS CI also builds the PR.

The first candidate runs exposed a mismatched macOS XCTest host product name and Tauri's requirement for an explicit Result in the asynchronous chat-reset command. Both were fixed and later native runs passed. These earlier failures are retained in Actions history.

## Coverage and limits

Swift tests execute provider selection, switch/reset routing, Claude hook translation, permission policy, real temporary Keychain read/write/delete, file and PDF request handling, sanitized errors, mocked multi-turn Responses history/rollback, model/tool capability rejection, artifact ID validation, Codex scoped decision contracts and a mocked function-call continuation.

Rust tests cover the original Claude/base64 and hook tests, provider resolution, Responses request tools/privacy/capabilities, source URL filtering/error messages, text-file limits, the secret whitelist, a real temporary Windows Credential Manager round trip, unknown function names/arguments and official scoped Codex decision contracts. TypeScript tests cover Claude hook/tool translation and all three permission levels. Python checks catalog consistency, absence of catalog credentials and preserved licenses.

These checks **do not establish full Claude regression or live OpenAI/Codex operation**. No paid API request, authenticated Codex session or physical desktop Allow/Deny click was made in CI. File/PDF/vision tests validate production request construction, not API acceptance. Hosted tool requests validate their contracts, not account availability or returned artifacts. Codex transport was compiled and its scope/decision helpers tested; lifecycle and approvals still require the real app-server.

## Reproduce

macOS:

```sh
cd NotchBuddy
xcodegen
xcodebuild -project NotchBuddy.xcodeproj -scheme NotchBuddy -configuration Debug build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
xcodebuild -project NotchBuddy.xcodeproj -scheme CoucouAppStore -configuration Debug build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
xcodebuild -project NotchBuddy.xcodeproj -scheme NotchBuddy -configuration Debug test CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Windows, with Node 22, Rust and Tauri prerequisites:

```sh
cd windows
npm ci
npm run build
node --test tests/*.test.mjs
cargo test --workspace
npm run tauri build -- --no-bundle
```

Shared checks: `python3 -m unittest discover -s tests -v`. A source scan found no recognizable OpenAI/GitHub key or private-key patterns; pattern scans are not a guarantee against all secrets.

## Credentialed acceptance still required

Configure keys in the app's secure Settings, authenticate with `codex login`, and explicitly authorize API/tool costs before running live checks. Do not submit keys in chat or source. On macOS and Windows verify:

1. Claude multi-turn chat, original file/context actions, search and all installed Claude Code hooks. Request both accepted and denied permissions; verify session completion and existing terminal navigation where available.
2. OpenAI two-turn conversation recalling a synthetic fact, provider switching and new conversation. Verify an invalid key, quota/rate-limit and network failure present sanitized errors without exposing request content.
3. A small synthetic TXT/CSV, valid PDF, Office document and image dropped through the existing UI; verify the assistant actually describes their content. Reattach a changed file and verify changed context.
4. Enable Web Search; verify returned citations can be opened and the active tool indicator appears. Enable Code Interpreter; request CSV analysis and a generated chart, save the returned artifact and inspect it without automatic execution.
5. Start an owned Codex session in a disposable project. Verify initialization, command/file/tool events, complete/error states and one-shot Allow/Deny. Test timeout, stopping/restarting, concurrent Claude approval, unknown client request and wrong session scope. Verify no terminal button for Codex.
6. Verify original Mochi interactions, sounds/animations, integration pills and OS context permissions. Windows does not gain a window-capture feature in this branch.

7. With Computer Use enabled, a disposable browser profile and no sensitive display content, verify native OS permission denial, each input approval, screenshot-transmission Deny/Allow, timeout and Cancel. No payments, real credentials, production changes or irreversible tasks are appropriate for this acceptance test.
8. Configure a trusted MCP test server and token in secure Settings. Verify discovery-only empty allowlist, permitted tool approval/denial, authentication errors and reconnect after configuration changes. Verify no old approval is replayed on another turn.
9. Enable image generation, generate a synthetic image, edit a dropped image, verify Vision still handles analysis-only prompts, then preview/save/cancel export through the native dialog. These API requests can incur charges.
10. Use sandbox/test integrations and disposable content for external writes. Inspect destination/parameters/risk, Deny and timeout before testing Allow. Do not perform real refunds, email delivery, production deployment or irreversible operations merely to validate this branch.

Computer Use, remote Responses MCP, image generation/editing and registered external writes now have production code and mock coverage. Persistent file search is still outside this branch. Live and physical acceptance remain unexecuted, so the full end-to-end Definition of Done is not asserted.

## Previous implementation checkpoint

Revision `dff517898532c099f1cb845383e2d94afea36342` passed [run 36781112805](https://github.com/LamonSilvio/coucou/actions/runs/36781112805), all baseline/candidate builds and 51 tests. This is historical evidence for the initial multi-provider implementation, not validation of the tools subsequently added.

## Tools completion validation

The new suites cover FIFO authorization, SAFE/CONFIRM/CRITICAL, Allow/Deny, expiry/cancel, duplicate execution claims, forged risk, redaction, shared Claude/Codex presentation, current computer action parsing, injected execution and safety ordering, mocked Responses computer continuations, MCP discovery/authentication/approval/one-shot grant consumption, strict configuration rejection, secure credential round trips, image requests/edit intent/PNG parsing/chosen save, all seven integration write request plans and approved mock transports. Search/interpreter, provider switch, file/vision context and previous agent contracts remain tested. Windows additionally boots the fixed PowerShell driver with `wait` without any desktop input/capture.

An initial Windows native bootstrap test exceeded the 15-second limit. The driver now accepts newline-framed JSON and allows bounded 45-second cold startup. The failed run is retained as [36793819347](https://github.com/LamonSilvio/coucou/actions/runs/36793819347), not concealed or counted as a pass.

Live tests: **NOT EXECUTED — credentials required**, plus explicit authorization for API costs/external effects. Physical mouse/keyboard/screenshot and save-dialog acceptance require interactive macOS/Windows machines and OS permissions not available in this editing runtime. Mock tests and native builds do not replace those checks. No live email, financial operation, production deployment, remote cancellation or irreversible change was performed. App Store native Computer Use and Codex launch are explicitly unavailable; the app target still builds.

Final application code: `447d653457bd563c5534ce1de64c2a46063737fa` (local equivalent `32e369e`). [Native run 36794605129](https://github.com/LamonSilvio/coucou/actions/runs/36794605129) passed both candidate jobs: checked-in and regenerated macOS Debug app, App Store target, XCTest, Windows frontend and Tauri native production build. Suite counts, each counted once: **55 Swift + 50 Rust (47 app, 3 hook) + 21 TypeScript + 3 Python = 129 passed, 0 failed, 0 skipped**. The harmless Windows driver bootstrap passed. No physical browser input or capture test was performed. Subsequent changes are documentation only. Main remains at the original baseline; no merge or binary release is performed.
