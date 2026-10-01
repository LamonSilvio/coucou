# Approved integration writes

Enable OpenAI → External writes and the relevant existing integration. Coucou reuses integration enablement and OS-secured credential accounts; it does not duplicate pollers. The strict `external_action` function is validated against the shared `NotchBuddy/Resources/ExternalActions.json` manifest. The model proposes integration/operation and JSON parameters; it never calls a client directly.

The pipeline is registered tool → fixed request plan → native local risk → FIFO approval → one-shot execution → sanitized result. Unknown fields, unregistered operations, credential-bearing parameters, path traversal and arbitrary destinations fail closed. Approval shows the actual HTTP method/destination and relevant parameters. Credentials are loaded only after consent. Requests disallow redirects, use 45-second resource timeouts and 2 MB response limits. Returned results contain only success, ID and HTTP status; raw vendor errors and private bodies are not logged.

| Integration | Registered operation | Risk | Credential account |
|---|---|---|---|
| GitHub | create_issue, comment_issue (issues or PRs) | CONFIRM | github-token |
| Notion | create_page, append_content | CONFIRM | notion-api-key |
| n8n | run_workflow through fixed configured webhook | CRITICAL (unknown workflow effects) | n8n-webhook-token |
| Vercel | preview_deploy | CONFIRM | vercel-token |
| Vercel | production_deploy | CRITICAL | vercel-token |
| Resend | send_email, plain text | CRITICAL | resend-api-key |
| Stripe | refund, explicit payment_intent and positive amount | CRITICAL | stripe-api-key |
| Cal.com | create_booking, reschedule_booking | CONFIRM | calcom-api-key |
| Cal.com | cancel_booking | CRITICAL | calcom-api-key |

CONFIRM and CRITICAL both require an explicit decision; CRITICAL is emphasized in Mochi. Local policy is authoritative regardless of prompts/server metadata. Always is not offered for these writes. SAFE automatic routing is currently reserved for registered read-only integration status and computer waiting. Original Claude Code/owned Codex approvals use the shared queue but retain their official protocol semantics.

## Configuration and operation contracts

- **GitHub:** repositories/issues access must be authorized by the stored token. Create uses owner/repo/title/body; comments add number. No branch/file updates, repository deletion or merge endpoint is registered.
- **Notion:** share the target parent/page with the integration. Creation takes official parent/properties and optional children JSON; append takes block_id/children. The existing compatible `Notion-Version:2022-06-28` pin is retained. Direct page-property/block replacement and deletions are not registered.
- **n8n:** Settings configures one fixed production Webhook node URL, with HTTPS and no embedded token. Configure header authentication `Authorization: Bearer <token>` in n8n; save the matching token separately in Coucou. This is distinct from the original polling API key. Parameters workflow/effect are review labels and input is sent as the webhook body. The displayed fixed destination is authority, not the AI's workflow name/effect claim. The official public API has no fabricated generic `/run` endpoint here; use your configured production webhook. Because that workflow can have arbitrary effects, it is CRITICAL.
- **Vercel:** name, official gitSource and optional project are admitted at `/v13/deployments`; target is forced locally to preview or production, never accepted from arbitrary parameters. Production cannot be executed automatically. File uploads/environment-variable configuration and deletion are not exposed.
- **Resend:** preview includes from/to/subject/text. Real sending requires CRITICAL Allow. Draft composition is ordinary chat, not a send. HTML, attachments, scheduling and batch mail are not registered.
- **Stripe:** refunds only, with a positive integer in the currency's smallest unit and a payment_intent identifier. Every Stripe write is CRITICAL. No automatic charge, transfer, balance modification, credential operation or deletion is registered. Tests never issue financial requests.
- **Cal.com:** create takes start/eventTypeId/attendee; reschedule takes bookingUid/start/reschedulingReason; cancel takes bookingUid/cancellationReason. The official `cal-api-version:2026-02-25` is pinned. Seated/recurring cancellation may affect multiple attendees; review the actual booking carefully. Limit overrides, guest secrets and bulk operations are not exposed.

Enter keys only in the existing secure Settings fields. Remote account scope, project sharing, verified email sender, booking eligibility and balances remain service-side checks, not promises made by a build.

## Queue, idempotence and audit

The shared queue never overwrites an earlier request. Each ID can be decided and claimed only once; stale/out-of-order Allow, repeated clicks, expiry and cancel cannot execute it. Claude expiry still falls back to its official terminal permission flow. Native Codex decisions remain scoped to its current owned thread/turn/generation.

Resend and Stripe receive a stable `Idempotency-Key` from the call ID. Other services do not get an invented idempotency guarantee: one-shot local claims and no automatic retry prevent duplicate delivery by the app, but they are not durable exactly-once delivery after a crash or uncertain network outcome. A new model call needs a new human decision. Verify an uncertain email/workflow/deploy/booking/refund before manually retrying.

Local `actions-audit.jsonl` records timestamp/provider/integration/operation/risk/decision/outcome. macOS: Application Support/Coucou (file mode 0600); Windows: LOCALAPPDATA/Coucou under user-profile ACLs. No action parameters, payloads, document bodies, cookies or credentials are recorded. A failure can mean an unconfirmed remote result, not rollback. Coding-agent approval delivery is not proof of successful command execution. Logs are local diagnostics, not tamper-proof compliance records, and do not rotate automatically.

Mock tests exercise request construction and approved/denied routing for every integration. No live email, refund, production deploy, cancellation or irreversible action is performed by CI. Live tests require securely configured credentials **and explicit cost/effect authorization**.

## Primary API references checked

[GitHub issues/comments](https://docs.github.com/en/rest/issues/issues), [official Notion SDK page/block contracts](https://github.com/makenotion/notion-sdk-js/tree/main/src/api-endpoints), [n8n Webhook](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.webhook/), [Vercel deployments](https://vercel.com/docs/rest-api/reference/endpoints/deployments/create-a-new-deployment), [Resend send](https://resend.com/docs/api-reference/emails/send-email), [Resend idempotency](https://resend.com/docs/dashboard/emails/idempotency-keys), [Stripe refunds](https://docs.stripe.com/api/refunds/create), [Cal.com bookings](https://cal.com/docs/api-reference/v2/bookings/create-a-booking), [reschedule](https://cal.com/docs/api-reference/v2/bookings/reschedule-a-booking), [cancel](https://cal.com/docs/api-reference/v2/bookings/cancel-a-booking). Checked 2026-09-30; expand only after verifying official contracts and native policy/tests.
