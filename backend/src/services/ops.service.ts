/**
 * Cross-cutting operational services: durable job queue, audit trail,
 * privacy-conscious analytics, settings.
 */
import { check } from '../lib/errors.js';
import { pepperedHash } from '../lib/crypto.js';
import { logger } from '../lib/logger.js';
import { redactDeep } from '../lib/redact.js';
import { serviceClient } from '../lib/supabase.js';

export type JobKind =
  | 'scan_process' | 'export_build' | 'account_deletion' | 'billing_process' | 'billing_reconcile' | 'email_ingest'
  | 'storage_backup' | 'claim_pack' | 'monthly_digest' | 'profitability_snapshot' | 'retention_purge' | 'upload_verify'
  | 'maintenance';

export async function enqueueJob(
  kind: JobKind,
  payload: Record<string, unknown>,
  opts: { userId?: string; dedupeKey?: string; runAt?: Date; priority?: number; maxAttempts?: number } = {},
): Promise<string> {
  return check(
    await serviceClient().rpc('enqueue_job', {
      p_kind: kind,
      p_payload: payload,
      p_user_id: opts.userId ?? null,
      p_dedupe_key: opts.dedupeKey ?? null,
      p_run_at: (opts.runAt ?? new Date()).toISOString(),
      p_priority: opts.priority ?? 100,
      p_max_attempts: opts.maxAttempts ?? 5,
    }),
  ) as string;
}

export interface AuditInput {
  actorType: 'user' | 'admin' | 'system' | 'worker' | 'webhook';
  actorId?: string | null;
  action: string;
  targetType?: string;
  targetId?: string;
  metadata?: Record<string, unknown>;
  ip?: string;
}

/** Append-only audit trail; metadata is redacted before storage. Never throws. */
export async function audit(input: AuditInput): Promise<void> {
  try {
    const { error } = await serviceClient().from('audit_events').insert({
      actor_type: input.actorType,
      actor_id: input.actorId ?? null,
      action: input.action,
      target_type: input.targetType ?? null,
      target_id: input.targetId ?? null,
      metadata: redactDeep(input.metadata ?? {}),
      ip_hash: input.ip ? pepperedHash(input.ip) : null,
    });
    if (error) logger.warn({ code: error.code, action: input.action }, 'audit insert failed');
  } catch (err) {
    logger.warn({ err, action: input.action }, 'audit insert failed');
  }
}

/** Server-side analytics event (only allow-listed names/properties survive the DB trigger). */
export async function track(
  userId: string | null,
  eventName: string,
  properties: Record<string, string | number | boolean> = {},
  platform: 'ios' | 'android' | 'web' | 'server' = 'server',
): Promise<void> {
  try {
    if (userId) {
      const { data } = await serviceClient().from('profiles').select('analytics_consent').eq('id', userId).maybeSingle();
      if (!data?.analytics_consent) return;
    }
    await serviceClient().from('analytics_events').insert({
      user_id: userId,
      event_name: eventName,
      properties,
      platform,
      occurred_at: new Date().toISOString(),
    });
  } catch (err) {
    logger.debug({ err, eventName }, 'analytics insert skipped');
  }
}

export async function getSetting<T = unknown>(key: string, fallback: T): Promise<T> {
  const { data } = await serviceClient().from('system_settings').select('value').eq('key', key).maybeSingle();
  return (data?.value as T | undefined) ?? fallback;
}

export async function heartbeat(worker: string, info: Record<string, unknown> = {}): Promise<void> {
  await serviceClient().from('worker_heartbeats').upsert({ worker_name: worker, last_beat_at: new Date().toISOString(), info });
}
