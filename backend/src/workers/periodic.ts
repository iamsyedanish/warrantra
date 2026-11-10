/**
 * Periodic tasks. Run by the worker loop on a cadence, or triggered over HTTP
 * (POST /v1/internal/cron/:task with X-Cron-Secret) by an external scheduler.
 */
import { env } from '../config/env.js';
import { check } from '../lib/errors.js';
import { BUCKETS, serviceClient } from '../lib/supabase.js';
import { reconcileExpiring } from '../services/billing/billing.service.js';
import { purgeExpiredExports } from '../services/export.service.js';
import { enqueueJob } from '../services/ops.service.js';
import { dispatchDueReminders, queueMonthlyDigests } from '../services/reminder.service.js';

export async function retentionPurge() {
  const svc = serviceClient();
  const now = Date.now();
  const days = (n: number) => new Date(now - n * 86_400_000).toISOString();
  const policies = check(await svc.from('retention_policies').select('data_class, retention_days')) as Array<{ data_class: string; retention_days: number }>;
  const p = Object.fromEntries(policies.map((x) => [x.data_class, x.retention_days]));
  const results: Record<string, number | null> = {};
  const del = async (name: string, q: PromiseLike<{ count: number | null }>) => {
    results[name] = (await q).count;
  };
  await del('notification_deliveries', svc.from('notification_deliveries').delete({ count: 'exact' }).lt('created_at', days(p.notification_deliveries ?? 180)));
  await del('analytics_events', svc.from('analytics_events').delete({ count: 'exact' }).lt('received_at', days(p.analytics_events ?? 395)));
  await del('inbound_emails', svc.from('inbound_emails').delete({ count: 'exact' }).lt('received_at', days(p.inbound_email_records ?? 90)));
  await del('jobs', svc.from('jobs').delete({ count: 'exact' }).in('state', ['succeeded', 'cancelled']).lt('updated_at', days(30)));
  await del('web_deletion_requests', svc.from('web_deletion_requests').delete({ count: 'exact' }).lt('created_at', days(30)));
  await del('identity_link_intents', svc.from('identity_link_intents').delete({ count: 'exact' }).lt('expires_at', days(1)));
  await del('closed_support_tickets', svc.from('support_tickets').delete({ count: 'exact' }).in('status', ['closed', 'resolved'])
    .lt('retention_until', new Date().toISOString().slice(0, 10)));
  results.expired_exports = await purgeExpiredExports();
  results.reservations = null;
  const cleanup = check(await svc.rpc('worker_cleanup_reservations')) as Record<string, number>;
  return { ...results, ...cleanup };
}

/**
 * Upload recovery: verify uploads whose client never called /complete, and remove
 * the stored bytes of uploads that were abandoned (so no orphaned objects remain).
 */
export async function recoverUploads() {
  const svc = serviceClient();
  const pending = check(await svc.rpc('worker_pending_uploads', { p_older_than: '10 minutes', p_limit: 200 })) as Array<{ id: string }>;
  for (const p of pending) {
    await enqueueJob('upload_verify', { attachment_id: p.id }, { dedupeKey: `verify:${p.id}`, maxAttempts: 3 });
  }
  const abandoned = check(await svc.rpc('worker_abandoned_uploads', { p_limit: 200 })) as Array<{ id: string; storage_path: string }>;
  let removed = 0;
  for (let i = 0; i < abandoned.length; i += 100) {
    const chunk = abandoned.slice(i, i + 100);
    const rm = await svc.storage.from(BUCKETS.files).remove(chunk.map((a) => a.storage_path));
    if (rm.error) continue;
    check(await svc.from('attachments').delete().in('id', chunk.map((a) => a.id)));
    removed += chunk.length;
  }
  return { verify_queued: pending.length, abandoned_removed: removed };
}

const TASKS: Record<string, () => Promise<unknown>> = {
  uploads: () => recoverUploads(),
  reminders: () => dispatchDueReminders(200),
  cleanup: async () => check(await serviceClient().rpc('worker_cleanup_reservations')),
  billing_reconcile: () => reconcileExpiring(),
  storage_backup: async () => {
    // Skip quietly until a backup target is configured (avoids retry noise in failed-job views).
    if (!env().BACKUP_S3_BUCKET || !env().BACKUP_S3_ACCESS_KEY_ID) return { skipped: 'backup_not_configured' };
    return { job_id: await enqueueJob('storage_backup', { mode: 'incremental' }, { dedupeKey: 'storage-backup' }) };
  },
  profitability: async () => ({ job_id: await enqueueJob('profitability_snapshot', {}, { dedupeKey: `profit:${new Date().toISOString().slice(0, 10)}` }) }),
  monthly_digest: () => queueMonthlyDigests(),
  retention: () => retentionPurge(),
};

export async function runPeriodicTask(name: string): Promise<unknown> {
  const fn = TASKS[name];
  if (!fn) throw new Error(`unknown_task:${name}`);
  return { task: name, result: await fn() };
}

/** Cadence for the in-process scheduler (milliseconds). */
export const SCHEDULE: Array<{ task: string; everyMs: number }> = [
  { task: 'reminders', everyMs: 30_000 },
  { task: 'cleanup', everyMs: 10 * 60_000 },
  { task: 'uploads', everyMs: 5 * 60_000 },
  { task: 'billing_reconcile', everyMs: 60 * 60_000 },
  { task: 'storage_backup', everyMs: 24 * 60 * 60_000 },
  { task: 'profitability', everyMs: 24 * 60 * 60_000 },
  { task: 'retention', everyMs: 24 * 60 * 60_000 },
];
