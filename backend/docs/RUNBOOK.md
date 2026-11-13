# Operations runbook

## Health signals
- `GET /v1/admin/health` returns: reminder handoff lag (target: 99% of due reminders handed to the provider within 5 minutes; this is an internal target, not an SLA), failed and dead jobs, worker heartbeats, unprocessed billing events, deletions stuck for more than 6 hours, and AI spend this month.
- `worker_heartbeats.last_beat_at` older than 2 minutes means a worker is down. Start another; locks expire, so jobs resume.

## Kill switches (`PUT /v1/admin/settings/:key`, operator role)
| Key | Effect |
|---|---|
| `ai_kill_switch=true` | Refuses new AI reservations and stops queued scans. Manual entry and existing records are unaffected. |
| `ai_global_monthly_budget_usd` / `ai_account_monthly_cost_ceiling_usd` | Spend ceilings |
| `ai_rate_limit_per_hour` | Per-user AI rate limit |
| `uploads_enabled=false` | Pauses new uploads (reading and export still work) |
| `email_ingest_daily_limit` | Forwarded-email quota per address |
| `billing_environment` | Which RevenueCat environment grants access (keep `PRODUCTION`) |

## AI abuse
- Suspended accounts: `GET /v1/admin/ai/suspensions`; a user's signals: `GET /v1/admin/users/:id/ai-abuse-signals`.
- Lift or impose a suspension (audited): `POST /v1/admin/users/:id/ai-suspension` `{action: "lift"|"suspend", days, reason}`.
- Free-tier spend spike: lower `ai_free_tier_daily_budget_usd`; paid users are unaffected.
- Tune sensitivity with `ai_abuse_signal_threshold_24h` and `ai_suspension_days`.

## Incidents
- **Push provider outage:** reminders retry with backoff (up to 5 attempts) and the Action Center still shows due items. Watch `failed_deliveries_24h`. Never report provider acceptance as delivery.
- **Billing webhook backlog or replays:** events are immutable and unique, so replays are harmless. `billing_reconcile` runs hourly and re-queues failed events. For a single user: `POST /v1/admin/users/:id/reconcile-entitlements`.
- **Stuck deletion:** look at `deletion_requests.last_error`. The job retries up to 20 times; storage failures stay in `deletion_manifests`. Retry with `POST /v1/admin/jobs/:id/retry`. Never delete the manifest by hand before completion.
- **Suspicious upload:** quarantined files keep only metadata; the bytes are removed. Check `attachments.quarantine_reason`.
- **AI cost spike:** check `/v1/admin/profitability` alerts (`ai_cost_p95_high`, `ai_budget_near_limit`), then lower the budget or flip the kill switch.

## Restore procedure
1. Restore the database with Supabase PITR or a backup into a **staging** project.
2. Restore Storage originals from the S3 backup (`backup_objects.backup_key` → original `bucket/storage_path`).
3. **Replay tombstones** before opening traffic: `select * from replay_deletion_tombstones();` (service role). Purge the returned users from Storage and the backup.
4. Run `npm run restore:drill` against the restored project. It must pass.
5. Record the result. `restore_drills` is written automatically.

Run the drill on a schedule (at least quarterly) and before launch (Phase D gate).

## Launch gates (spec §11, Phase D)
Real-device notification tests (permission denial, stale tokens, reinstall, long inactivity) · store disclosures (AI sharing, data deletion URL `/v1/public/account-deletion`) · an observed beta · a passing restore drill · this runbook reviewed · acquisition experiment spending capped · profitability snapshot with real costs entered.
