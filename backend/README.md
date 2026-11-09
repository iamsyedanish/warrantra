# Warrantra Backend (v4 profit-first spec)

A standalone REST API for the Warrantra purchase-protection assistant. It is
built on Supabase (Postgres, Auth, Storage) with Node.js + TypeScript +
Express, in an MVC layout. The Flutter app talks only to this API and
to Supabase Auth. It never holds the service-role key, AI keys or billing secrets.

> Status: implemented and tested locally against embedded Postgres (PGlite with a
> Supabase shim) plus unit/HTTP tests. It has **not** yet been run against a live
> Supabase project, RevenueCat, FCM, Postmark or an S3 bucket. See
> [docs/SPEC_COVERAGE.md](docs/SPEC_COVERAGE.md) → "What is not yet verified".

## Architecture

```
Flutter app ──HTTPS──► Express API (/v1) ──► Supabase Postgres (RLS + RPCs)
                          │                 ├► Supabase Storage (private buckets, signed URLs)
                          │                 └► Supabase Auth (JWT verification)
                          ├► Anthropic (receipt extraction / claim drafts, server-side only)
RevenueCat ──webhook────► │
Postmark   ──webhook────► │
                     Worker process ──► jobs queue (FOR UPDATE SKIP LOCKED)
                          ├► FCM HTTP v1 (push; APNs via FCM)
                          └► S3-compatible bucket (separate backup of original files)
```

**Defense in depth.** User requests use a Supabase client bound to the caller's
JWT, so every query also runs under row-level security. The service-role client
is used only by webhooks, workers and admin routes, and those paths do their own
authorization checks. Identity always comes from the verified token, never from
a request body.

### MVC layout

| Layer | Path | Responsibility |
|---|---|---|
| Routes | `src/routes/index.ts` | URL → middleware → controller |
| Controllers | `src/controllers/*` | HTTP adapters: validate input (zod), call services, render views |
| Services | `src/services/*` | Business logic (purchases, coverage, vault, AI, reminders, billing, claims, export, deletion, workspaces, profitability, backups) |
| Models | `src/models/*` | Table repositories (RLS-scoped or service-scoped clients) |
| Views | `src/views/index.ts` | Response shaping, internal-field removal, certainty/disclaimer labels |
| Validators | `src/validators/index.ts` | Strict request schemas (unknown keys, including `user_id`, are rejected) |
| Database | `supabase/migrations/*.sql` | Schema, composite-FK ownership, RLS, triggers, atomic RPCs |
| Workers | `src/workers/*` | Job queue runner + periodic tasks |

## Getting started

```bash
cd backend
npm install
cp .env.example .env    # fill in Supabase keys, HASH_PEPPER, webhook secrets
```

### Database migrations

Set `DATABASE_URL` in `.env` (Supabase Dashboard → **Connect** → Direct connection or
Session pooler, port 5432), then:

```bash
npm run db:migrate            # apply every pending file in supabase/migrations, in order
npm run db:migrate -- --seed  # ...and load supabase/seed.sql (categories, brands)
npm run db:status             # applied / pending / edited files
npm run db:seed               # seed only
npm run db:migrate -- --dry-run
```

How it works:
- Files run in name order. Each one runs in its own transaction, so a failing file rolls back completely and stops the run.
- Applied versions go in `supabase_migrations.schema_migrations`, the same table the Supabase CLI uses, so `supabase db push` stays compatible.
- SHA-256 checksums are recorded, and editing an already-applied file is refused. Add a new file instead.
- An advisory lock stops two runs from overlapping.
- It refuses the transaction pooler (port 6543) and databases without Supabase's `auth`/`storage` schemas.
- After migrating, it checks that every public table has row-level security.

To add a change, create `supabase/migrations/<timestamp>_<name>.sql` and run `npm run db:migrate`.

Run the API and the worker as separate processes:

```bash
npm run dev       # API on :8080
npm run worker    # job queue + reminders + periodic tasks
```

Production: `npm run build && npm start` and `npm run worker:prod`.

## Tests

```bash
npm test               # all suites
npm run test:sql       # release-blocking DB tests on embedded Postgres
npm run db:check       # apply every migration and assert RLS is enabled everywhere
npm run typecheck
```

`tests/sql/release-blocking.test.ts` covers the spec's §11 release-blocking tests
at the database level, using two (or more) authenticated users: cross-account
isolation, quotas and idempotency, shared receipts and partial returns, unknown
dates, reminder versioning, entitlements, tombstone replay, privacy guards,
workspace authorization and column-level write restrictions. Before release,
run the same scenarios against a real `supabase db reset` stack as well.

## Required platform configuration

- **Supabase Auth:** enable Email, Google and Apple, and keep *manual* identity
  linking. The `guard_identity_linking` trigger blocks email-only account merging.
  Enable TOTP MFA for admins.
- **Storage:** private buckets `warranty-files`, `exports` and `claim-packs` are
  created by migration 0016.
- **RevenueCat:** set the app user ID to the Supabase user ID. The webhook goes to
  `POST /v1/webhooks/revenuecat` with the Authorization value from
  `REVENUECAT_WEBHOOK_AUTH`. Set `REVENUECAT_SECRET_API_KEY` so reconciliation
  reads the authoritative subscriber state.
- **Postmark inbound:** webhook `POST /v1/webhooks/inbound-email` with basic auth
  `INBOUND_WEBHOOK_USER:INBOUND_WEBHOOK_PASSWORD`, plus an MX record for
  `INBOUND_DOMAIN`.
- **FCM:** set `PUSH_PROVIDER=fcm`, a service account with
  `firebase.messaging`, and the APNs key uploaded to Firebase.
- **Backups:** set the S3-compatible bucket env vars. Supabase database backups
  do **not** include Storage objects.
- **Admins:** insert rows into `admin_users` with the service role. The first
  superadmin must be added manually.

## Documents

- [docs/API.md](docs/API.md) — endpoint reference
- [docs/SPEC_COVERAGE.md](docs/SPEC_COVERAGE.md) — every spec module mapped to code and tests, plus open items
- [docs/RUNBOOK.md](docs/RUNBOOK.md) — incident runbook, kill switches, restore drill, deletion recovery
