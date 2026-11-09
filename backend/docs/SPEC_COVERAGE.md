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

## What is not yet verified (be explicit)

- **No live services yet.** Nothing has run against a live Supabase project, RevenueCat, FCM/APNs, Postmark, Resend, Anthropic or S3. The database tests use PGlite plus a shim of `auth`/`storage`. Run `supabase db reset` and repeat the SQL suite on the real stack.
- **Identity-merge trigger.** `guard_identity_linking` sits on `auth.identities`. Supabase manages that schema, so confirm on your project that the trigger is permitted and that Auth surfaces the error as expected.
- **True concurrency.** The advisory-lock quota checks were exercised sequentially; parallel uploads and scans need a real multi-connection test.
- **AI cost.** The default model is `claude-opus-5-5` with `effort: low`. That may exceed the spec's $0.02/action assumption. Measure it, and choose a cheaper model through `AI_MODEL` plus the price env vars if needed (your decision). No accuracy claim is made.
- **Monthly price and fee mix.** These are unvalidated; profitability output is only as good as the costs entered.
- **Rate limits.** `express-rate-limit` uses in-memory storage; use a shared store for multiple API instances.
- **Legal/privacy review, store disclosures, real-device notification tests and a security review** are still required (§12).
