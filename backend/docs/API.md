# Warrantra API reference (v1)

Base path: `/v1`. JSON in and out. Authenticated routes need
`Authorization: Bearer <supabase access token>`. Successful responses are wrapped
in `{ "data": ... }`. Errors look like
`{ "error": { "code", "message", "details?", "request_id" } }`.

Conventions:

- **Create endpoints that can be retried** take an `Idempotency-Key` header
  (8–128 characters `[A-Za-z0-9_-]`). A replay returns the original result and
  never double-charges usage.
- **Optimistic concurrency:** send `If-Match: "<version>"` on PATCH. A stale
  version returns `409 version_conflict`.
- **Signed URLs** are short-lived bearer credentials (default 300 s). Never log
  or cache them.
- **Private responses** carry `Cache-Control: no-store, private`. On sign-out or
  account switch, clear any local cache.

## Auth & account
| Method | Path | Notes |
|---|---|---|
| POST | `/auth/sign-up` | email + password (min 10 chars); responds the same whether or not the email exists |
| POST | `/auth/sign-in` | email + password |
| POST | `/auth/id-token` | native Google/Apple ID token → session |
| POST | `/auth/refresh` | refresh token → session |
| POST | `/auth/password-reset` | always 202 |
| POST | `/auth/sign-out` | `?scope=global` revokes every session |
| POST | `/auth/password` | needs a recent sign-in |
| GET | `/auth/identities` | linked providers |
| POST | `/auth/identities/link-intent` | needs a recent sign-in; then call `linkIdentity` in the app within 10 min |
| GET/PATCH | `/me` | profile, entitlement, usage; PATCH timezone/alert time/preferences (reminders reschedule) |
| POST | `/me/ai-consent` | explicit permission for third-party AI processing |
| GET | `/me/entitlement`, `/me/usage` | server-authoritative plan and quotas |
| GET | `/me/annual-summary?year=2026` | purchases tracked, returns and registrations completed, claims, user-reported refunds (never "money saved") |
| POST | `/me/restore-purchases` | reconcile with RevenueCat after a client restore |
| PUT/GET/DELETE | `/me/devices` | push installations; a token moves between accounts on account switch |
| POST/GET | `/me/exports`, `/me/exports/:id` | data + original-file export (never paywalled) |
| POST | `/me/deletion` → `/me/deletion/confirm` (`{"confirm":"DELETE MY ACCOUNT"}`) | durable deletion; `/me/deletion/cancel` before confirming |

## Public (no auth)
`POST /public/account-deletion`, `POST /public/account-deletion/verify` (the deletion route outside the app) ·
`POST /public/support` · `GET /public/retention-schedule` · `GET /public/plans`

## Home
`GET /action-center?horizon_days=60` returns the "Protect your first purchase" empty state when there are no items; otherwise overdue items first, then returns, registrations, coverage, claim follow-ups and maintenance. Missing information is listed separately.

## Purchases & items
| Method | Path | Notes |
|---|---|---|
| POST | `/purchases` | one receipt → lines → selected `track` items; tax/shipping/discount allocated in cents and labelled estimated; returns `warnings` |
| GET | `/purchases`, `/purchases/:id` | group + lines + items + documents |
| PATCH/DELETE | `/purchases/:id` | deleting keeps the items and the documents |
| POST | `/receipt-lines/:lineId/track` | track a line later |
| POST | `/items` | manual quick add (single line purchase) |
| GET | `/items` | `q, category_id, status(active_coverage/expired_coverage/return_soon/registration_pending/unconfirmed), lifecycle, archived, sort(purchase_date/created_at/coverage_urgency/value/name)` |
| GET/PATCH/DELETE | `/items/:id` | detail includes coverage, documents, claims and timeline; delete removes links, never a shared receipt |
| GET | `/items/:id/timeline`, `/items/:id/coverage`, `/items/:id/coverage-suggestions` | warranty, card-benefit, return-policy and registration suggestions; labelled and never applied automatically |
| POST | `/items/:id/warranties`, `/items/:id/return-windows`, `/items/:id/registrations` | `confirm: true` / `accept_estimate: true` are explicit |
| PATCH/DELETE | `/warranties/:id`, `/return-windows/:id`, `/registrations/:id` | editing a deadline supersedes old reminder versions |

## Vault
| Method | Path | Notes |
|---|---|---|
| POST | `/attachments` | reserve bytes + pending record → signed upload URL/token |
| POST | `/attachments/:id/complete` | server verifies size, real MIME, PDF pages and active content, checksum → ready/quarantined/failed; returns `duplicate_of` (account-local) |
| GET | `/vault` | documents with link info (empty-state copy included) |
| GET | `/attachments/:id/url` | `?preview_width=` (optimized image preview), `?download=true` |
| GET | `/attachments/:id/impact` | everything a deletion would affect |
| DELETE | `/attachments/:id?confirm=true` | `409 confirmation_required` if linked and not confirmed |
| POST/DELETE | `/attachments/:id/links`, `/attachments/:id/links/:target/:targetId` | link to an item, purchase or claim |

## AI extraction & capture
| Method | Path | Notes |
|---|---|---|
| POST | `/scans` | `{attachment_id}` or `{ocr_text}`; atomic reservation; 202 → poll |
| GET | `/scans/:id` | `review_draft`: every field with evidence/status and warnings; save through `POST /purchases` with `scan_job_id` |
| POST | `/scans/:id/discard` | |
| POST/GET | `/capture-drafts`, `/capture-drafts/:id/discard` | share-to-app drafts (`auto_scan` optional) |
| GET/POST | `/email-forwarding`, `/email-forwarding/rotate`, `/email-forwarding/disable`, `/email-forwarding/log` | forwarding address (Pro) |

## Reminders
`GET /reminders?upcoming=true` · `POST /reminders` (custom) · `POST /reminders/:id/cancel` ·
`GET /notification-deliveries` · `POST /notification-deliveries/:id/opened`

## Claims & outcomes
| Method | Path | Notes |
|---|---|---|
| POST | `/claims` | creates a draft with *proposed* facts |
| GET | `/claims/:id/facts` | proposed vs reviewed facts |
| PUT | `/claims/:id/snapshot` | the user-reviewed facts (required before packs or a ready status) |
| POST | `/claims/:id/packs` | `{format: text/pdf}`; Free gets the basic template, Pro the assembled evidence package |
| GET | `/claim-packs/:packId/url` | |
| POST | `/claims/:id/ai-draft` | Pro; bounded; counts as one AI action; a failure releases it |
| PATCH/DELETE | `/claims/:id` | status history recorded automatically |
| POST/GET/PATCH/DELETE | `/outcomes`, `/outcomes/summary` | one outcome per case; refunds are user-reported, never "money saved" |

## Cards & reference
`/payment-cards` (labels only; card numbers are rejected) · `/reference/categories` · `/reference/brands?q=` · `/reference/card-benefits`

## Household / business portfolio
`/workspaces` (create needs the owner's plan) · `/workspaces/:id` · `/workspaces/:id/invitations` ·
`/workspaces/invitations/accept` · `/workspaces/:id/members/:userId` (role/revoke) · `/workspaces/:id/leave` ·
`/workspaces/:id/items` (owner shares; read-only for members) · `/workspaces/:id/locations` ·
`/workspaces/:id/assignments` · `/workspaces/:id/assets` · `/service-records` · `/items/:id/service-records` ·
`/maintenance-tasks` (+ `/:id/complete`)

## Partners, support, analytics
`/partners`, `/partner-consents` (explicit, revocable) · `/support/tickets` (+ messages) ·
`POST /analytics/events` (allow-listed events and properties only, with consent)

## Webhooks & internal
`POST /webhooks/revenuecat` · `POST /webhooks/inbound-email` · `POST /internal/cron/:task` (`X-Cron-Secret`; tasks: reminders, cleanup, uploads, billing_reconcile, storage_backup, profitability, monthly_digest, retention)

## Admin (`/v1/admin`, admin_users + MFA, audited)
`/health` · `/jobs` (+ retry/cancel) · `/notification-deliveries/failed` · `/scans/failed` · `/users/:id`
(+ `/reconcile-entitlements`, `/promotional-entitlement`) · `/audit-events` · `/settings/:key` (kill switches/budgets) ·
`/plan-limits` (versioned) · `/support/tickets` · `/reference/:table` (+ `/:id/review`) · `/metrics?from&to` ·
`/profitability` (+ `/snapshot`, `/costs`, `/acquisition-spend`, `/settings`, `/calculator`, `/alerts/:id/ack`) ·
`/backups` (+ `/run`, `/restore-drill`) · `/partners` (+ referral codes, consented share)
