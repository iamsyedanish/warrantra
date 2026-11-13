# Spec coverage — `warrantra-v4-profit-first-spec.md`

Every module in §2 (P0, P1 and P2) is implemented, as requested. Where v4 and the
v2 appendix conflict, v4 wins (for example: nullable warranty end dates, reminder
uniqueness, no `required` boolean on registrations).

## Modules (§2)

| Module | Priority | Implementation | Tests |
|---|---|---|---|
| Accounts & identity | P0 | `services/auth.service.ts`; migration 0002 (profiles, `guard_identity_linking` blocks email-only merges, `register_device` moves tokens on account switch); `noStore` + `Vary: Authorization` | SQL §8 identity merge; HTTP 401s |
| Purchase groups & lines | P0 | migration 0006; `create_purchase` RPC (0017); `purchase.service.ts` cents allocation | SQL §2–3; unit allocation |
| Capture & confirmation | P0 | manual `/items`, uploads, `/scans` → `review_draft` → user saves via `/purchases` | unit AI validation |
| Coverage evidence | P0 | migration 0007: `term_kind`, `date_certainty`, sources, `estimate_accepted_at`, `contract_state`; `coverage_status` view (time status kept separate; statutory disclaimer) | SQL §4 |
| Return & registration actions | P0 | anchors (purchase/delivery/custom), `deadline_basis`, progress states, partial-return quantity, `requirement_state`, "link opened ≠ completed" | SQL §3, §4, §5 |
| Document vault | P0 | migrations 0005/0011/0016; `attachment.service.ts` (reserve → signed upload → verify → ready/quarantine; impact; account-local dupes) | SQL §1 storage, §2; unit screening |
| Reminder service | P0 | migration 0010 (versioned schedule, IANA timezone and local alert time, catch-up, cancellation); `reminder.service.ts` dispatcher; FCM provider; health RPC | SQL §5 |
| Billing & entitlements | P0 | migration 0004; `billing/*` (immutable events, replay-safe, authoritative reconciliation, delayed-event guard, grace/refund/transfer/restore, sandbox isolation) | SQL §6; unit reconcile |
| Usage & AI budget ledger | P0 | migration 0011 (`reserve_ai_action`, settle/release, kill switch, global and per-account budgets, rate limit, consent) | SQL §2 |
| Basic claim pack | P0 | migration 0009; `claim.service.ts` (reviewed snapshot, deterministic text/PDF, Pro assembled pack, bounded AI draft) | unit template |
| Export & deletion | P0 | migration 0013; `export.service.ts`, `deletion.service.ts` (manifest outside the cascade, retries, verification, tombstones, web route) | SQL §7 |
| Support & administration | P0 | migration 0014; `admin.controller.ts` (MFA, roles, audit, failed jobs/deliveries/scans); `support.service.ts` | — |
| Profitability & cohort monitoring | P0 | migration 0015; `profitability/*` (spec formula, recognised revenue, CAC amortization without double counting, F/N, after-tax, cohort payback, margin alerts) | unit reproduces the spec table ($6.47 / $4.82 / $6.16; 1,497 subscribers) |
| Product/business analytics | P0 | allow-listed events with a sanitizing trigger; `admin_product_metrics` with explicit numerators and denominators | SQL §8 |
| Backup & restore | P0 | `backup.service.ts` (separate S3 copy, checksums, purge on deletion, restore drill), `scripts/restore-drill.ts` | SQL §7 tombstones |
| Annual summary (v2 §32) | later | `get_annual_summary` + `/me/annual-summary`; counts and user-reported refunds only | SQL §12 |
| Outcome ledger | P0 | `outcomes` (one per case, evidence level, "helped?"); summary never counts purchase value | — |
| Share-to-app capture | P1 | `capture_drafts` + `/capture-drafts` | — |
| Email forwarding | P1 | migration 0012; `capture.service.ts` (rotatable address, basic-auth webhook, DKIM/SPF verdict, screening, daily quota, Message-ID and checksum dedupe, atomic storage quota) | unit sender verdict |
| Household vault | P1 | migration 0008 (roles, invitations, revocation, owner-plan entitlement, read-only sharing) | SQL §9 |
| Business/property portfolio pilot | P1 | `business_pilot` plan, locations, assignment history, service records, workspace export | SQL §9 |
| Maintenance & service records | P1 | `maintenance_tasks` (`requirement_basis` avoids implying legal duty), completion → service record + next due date, reminders | — |
| Partner distribution | P2 | partners, referral codes, versioned revocable consents, consented-only admin share | — |
| Credit-card benefits database | P2 | `card_benefits` with country/product/effective dates, exclusions, review workflow; `suggest_coverage` | — |

## Cross-cutting rules (§3–§9)

- **Money:** `numeric(12,2)` domain, never negative, USD/CAD/GBP only; allocations done in integer cents.
- **Ownership:** composite FKs `(parent_id, user_id)` on every child; same-item FKs `(warranty_id, item_id, user_id)` on reminders; a trigger enforces same-item consistency on claims.
- **RLS:** operation-specific policies; explicit grants; column-level grants for server-only columns; reference tables are SELECT-only (published rows only). `db:check` fails if any public table lacks RLS.
- **Untrusted receipt content:** no tools offered to the model; document text is wrapped and escaped; strict output schema; evidence is required for every value; ambiguous dates become null.
- **Logs and analytics:** pino redaction plus `redactDeep`; signed URLs, tokens, serial numbers and receipt text are never logged; OCR text and email attachments are wiped from job payloads once a job finishes.
- **Upload limits:** 10 MB per file; JPEG/PNG/HEIC/PDF; at most 10 stored PDF pages; 2 AI pages per action (PDF trimmed before sending); HEIC is not sent to AI (use on-device OCR); HTML/JS/embedded files are quarantined.

## Release-blocking tests (§11) → where covered

1. **Cross-account isolation** — SQL §1 (read, write and link attempts, privileged RPCs, storage policy) and §11 (column-level writes).
2. **Concurrent quota / retries** — SQL §2. The per-user advisory lock serializes checks; PGlite is single-connection, so true parallelism must be re-tested on real Postgres.
3. **Shared receipt and partial return** — SQL §3.
4. **Unknown dates, labelled inferred terms, totals not repeated** — SQL §3–4 and unit tests.
5. **Reminder versions, simultaneous alerts, acceptance ≠ delivery** — SQL §5.
6. **Cancellation, refunds, replay, sandbox** — SQL §6 and unit reconcile tests.
7. **Export after cancellation, deletion survives failures, restore respects deletions** — SQL §7 (tombstones). Export and deletion workers still need live-stack tests.
8. **No leaks** — unit redaction/scrub tests; keys live only in server environment variables.

## Post-build audit fixes (migration 0019)

- Coverage time status and item lists use the user's IANA-timezone date rather than server UTC.
- Uploads where the client never called `/complete` are verified by the worker; abandoned objects are removed from Storage.
- Workspace sharing follows the owner's current plan. Existing shares survive a downgrade; new shares pause.
- Registration suggestions from curated brand data. Partner referral codes are attributed to the first paid cohort.
- Churn (numerator/denominator) in the profitability snapshot. Product-label scans get the same evidence-or-null validation as receipts.
- The Home empty state ("Protect your first purchase").

## Second audit (migrations 0020–0021)

- **Price experiment (§8/§10):** sticky per-user variant assignment (`GET /v1/me/offer`), draft-only edits, per-variant conversion, revenue and refunds (`/v1/admin/price-experiments`). Seeded as a draft: $169.99 vs $199.99.
- **Launch gates (§10–§11):** `/v1/admin/launch-gates` checks after-tax target, cost inputs, first-year cohort forecast, refund rate, acquisition spend cap, restore drill freshness, reminder hand-off and critical alerts. `/v1/admin/profitability/forecast` projects each cohort's first year from observed retention.
- **Acquisition spending cap:** `acquisition_monthly_cap_usd` with a critical alert.
- **Correction rate (§5):** measured by the server by comparing the saved purchase with the AI draft (the client value is ignored).
- **Backup retention (§6):** backup copies of deleted documents are purged after the published period, counted from deletion.
- **Travel/timezone (§7):** `GET /v1/me` returns a `timezone_hint` when the device zone differs from the profile.
- **Product recognition (v2 §14):** label scans suggest a category and, from reviewed reference data, the standard manufacturer warranty ("…appears to be 24 months. Confirm?").
- **Claim contact (v2 §20.2):** prefilled from brand support data when the user gives none.
- **AI image path:** images are EXIF-rotated, transparency is flattened onto white, they are capped at 2048 px and sent as JPEG (originals unchanged). A transparent PNG previously produced an empty draft.

## AI abuse controls

| Abuse | Control |
|---|---|
| Free-account farming | Verified email required; daily cap on total free-tier AI spend (`ai_free_tier_daily_budget_usd`) |
| Using scans as a chatbot / sending non-receipts | Model must classify the document; non-receipts are rejected with nothing extracted, still count (the cost was real) and are an abuse signal |
| Using claim drafts as a chatbot | Free moderation check first; 2,000-character AI input cap; prompt returns `OFF_TOPIC`; output must look like a claim letter (no code or arbitrary content) or it is rejected |
| Re-scanning the same file/text | Identical input reuses the earlier result: no AI call, no charge |
| Repeated abuse | Automatic AI suspension after N signals in 24h (`ai_abuse_signal_threshold_24h`, `ai_suspension_days`); audited; admin can review and lift. Manual entry is never blocked |
| Volume / cost | Plan quotas, hourly rate limit (counts released attempts too), per-account and global monthly spend caps, kill switch, page/character/output-token limits |
| Prompt injection | No tools; untrusted-data instructions; strict schema; evidence required for every value; verified live |

## What is not yet verified (be explicit)

- **Partly live.** Supabase (migrations, Auth, PostgREST/RLS, Storage), OpenAI, the worker (scans, billing events, export, deletion) and the RevenueCat webhook path (with simulated events) are verified live — 120 live checks. Not yet: RevenueCat's REST reconciliation (needs the secret key), FCM/APNs push, Postmark inbound, Resend email, S3 backups and the restore drill, and the Docker image build/CI run (no Docker on this machine; no git remote). The database tests use PGlite plus a shim of `auth`/`storage`. Run `supabase db reset` and repeat the SQL suite on the real stack.
- **Identity-merge trigger.** `guard_identity_linking` sits on `auth.identities`. Supabase manages that schema, so confirm on your project that the trigger is permitted and that Auth surfaces the error as expected.
- **True concurrency.** The advisory-lock quota checks were exercised sequentially; parallel uploads and scans need a real multi-connection test.
- **AI provider and cost.** The default is OpenAI `gpt-5.4-mini` (`AI_PROVIDER=openai`, `store: false`); Anthropic remains selectable. A live test measured about $0.003 per receipt action (two receipts, PDF and OCR text), well under the spec's $0.02 assumption, and the model ignored an injected instruction. The image (JPEG/PNG) path and accuracy on real-world receipts are not yet measured; no accuracy claim is made.
- **Monthly price and fee mix.** These are unvalidated; profitability output is only as good as the costs entered.
- **Rate limits.** `express-rate-limit` uses in-memory storage; use a shared store for multiple API instances.
- **Legal/privacy review, store disclosures, real-device notification tests and a security review** are still required (§12).
