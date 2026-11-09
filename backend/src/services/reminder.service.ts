/**
 * Reminder dispatch. The schedule is maintained by database triggers; this
 * worker hands due reminders to the push provider, records each attempt, and
 * retries with backoff. The in-app Action Center works regardless of push.
 */
import type { z } from 'zod';
import { check } from '../lib/errors.js';
import { logger } from '../lib/logger.js';
import { serviceClient, type Db } from '../lib/supabase.js';
import type { CustomReminderBody } from '../validators/index.js';
import { pushProvider } from './push/provider.js';

type Row = Record<string, unknown>;
const MAX_ATTEMPTS = 5;

export async function dispatchDueReminders(batch = 100): Promise<{ claimed: number; dispatched: number; retried: number; failed: number }> {
  const svc = serviceClient();
  const due = check(await svc.rpc('worker_claim_due_reminders', { p_batch: batch })) as Row[];
  const stats = { claimed: due.length, dispatched: 0, retried: 0, failed: 0 };
  const provider = pushProvider();

  for (const r of due) {
    try {
      const devices = check(await svc.from('devices').select('id, push_token, permission_state')
        .eq('user_id', r.user_id as string).eq('token_state', 'active')) as Row[];
      const reachable = devices.filter((d) => d.push_token && (d.permission_state === 'granted' || d.permission_state === 'provisional'));

      // Always record the in-app (Action Center) channel.
      await svc.from('notification_deliveries').upsert({
        user_id: r.user_id, reminder_id: r.id, schedule_version: r.schedule_version, channel: 'in_app',
        destination: 'in_app', state: 'provider_accepted', provider: 'in_app', accepted_at: new Date().toISOString(), attempt_count: 1,
      }, { onConflict: 'reminder_id,schedule_version,channel,destination', ignoreDuplicates: true });

      let anyRetryable = false;
      for (const d of reachable) {
        const key = { reminder_id: r.id, schedule_version: r.schedule_version, channel: 'push', destination: d.id };
        const existing = check(await svc.from('notification_deliveries').select('id, state, attempt_count').match(key).maybeSingle()) as Row | null;
        if (existing && (existing.state === 'provider_accepted' || existing.state === 'opened')) continue; // no duplicate sends

        const result = await provider.send({
          token: String(d.push_token),
          title: String(r.title),
          body: String(r.body),
          data: { reminder_id: String(r.id), reminder_type: String(r.reminder_type), item_id: r.item_id ? String(r.item_id) : '' },
        });
        const base = { ...key, user_id: r.user_id, device_id: d.id, provider: provider.name,
                       attempt_count: Number(existing?.attempt_count ?? 0) + 1 };
        if (result.status === 'accepted') {
          await svc.from('notification_deliveries').upsert({ ...base, state: 'provider_accepted', accepted_at: new Date().toISOString(),
            provider_message_id: result.providerMessageId, provider_response: { status: 'accepted' }, error_code: null },
            { onConflict: 'reminder_id,schedule_version,channel,destination' });
        } else {
          await svc.from('notification_deliveries').upsert({ ...base, state: 'failed', failed_at: new Date().toISOString(),
            provider_response: { status: result.status }, error_code: result.errorCode },
            { onConflict: 'reminder_id,schedule_version,channel,destination' });
          if (result.status === 'invalid_token') {
            await svc.from('devices').update({ token_state: 'stale' }).eq('id', d.id as string);
          } else if (result.status === 'retryable_error') {
            anyRetryable = true;
          }
        }
      }

      if (reachable.length === 0) {
        await svc.from('notification_deliveries').upsert({
          user_id: r.user_id, reminder_id: r.id, schedule_version: r.schedule_version, channel: 'push', destination: 'none',
          state: 'suppressed', error_code: 'no_reachable_device', attempt_count: 1,
        }, { onConflict: 'reminder_id,schedule_version,channel,destination', ignoreDuplicates: true });
      }

      if (anyRetryable) {
        await svc.rpc('worker_finish_reminder', { p_reminder_id: r.id, p_schedule_version: r.schedule_version, p_outcome: 'retry',
          p_error: 'push_retryable_error', p_max_attempts: MAX_ATTEMPTS });
        stats.retried++;
      } else {
        await svc.rpc('worker_finish_reminder', { p_reminder_id: r.id, p_schedule_version: r.schedule_version, p_outcome: 'dispatched' });
        stats.dispatched++;
      }
    } catch (err) {
      logger.error({ err, reminderId: r.id }, 'reminder dispatch failed');
      await svc.rpc('worker_finish_reminder', { p_reminder_id: r.id, p_schedule_version: r.schedule_version, p_outcome: 'retry',
        p_error: 'dispatch_exception', p_max_attempts: MAX_ATTEMPTS });
      stats.failed++;
    }
  }
  return stats;
}

export async function listReminders(db: Db, opts: { upcoming: boolean; limit: number; offset: number }) {
  let q = db.from('reminders').select('id, reminder_type, item_id, warranty_id, return_window_id, registration_id, claim_id, maintenance_task_id, offset_days, target_date, due_at, state, title, body, is_estimate, schedule_version');
  q = opts.upcoming ? q.in('state', ['scheduled', 'dispatching']).order('due_at', { ascending: true }) : q.order('due_at', { ascending: false });
  return check(await q.range(opts.offset, opts.offset + opts.limit - 1));
}

export async function createCustom(db: Db, body: z.infer<typeof CustomReminderBody>) {
  return check(await db.rpc('create_custom_reminder', {
    p_title: body.title, p_body: body.body ?? '', p_date: body.date, p_item_id: body.item_id ?? null,
    p_local_time: body.local_time ?? null,
  }));
}

export async function cancelCustom(db: Db, id: string) {
  check(await db.rpc('cancel_custom_reminder', { p_reminder_id: id }));
  return { cancelled: true };
}

export async function markOpened(db: Db, deliveryId: string) {
  check(await db.rpc('mark_notification_opened', { p_delivery_id: deliveryId }));
  return { recorded: true };
}

/** Monthly digest: one quiet summary of upcoming actions and missing info, opt-in only. */
export async function queueMonthlyDigests(now = new Date()): Promise<number> {
  const svc = serviceClient();
  const month = now.toISOString().slice(0, 7);
  const users = check(await svc.from('profiles').select('id, timezone, alert_local_time, notification_preferences')
    .eq('account_state', 'active').filter('notification_preferences->monthly_digest->>enabled', 'eq', 'true')) as Row[];
  let queued = 0;
  for (const u of users) {
    const [actions, missing] = await Promise.all([
      svc.from('reminders').select('id', { count: 'exact', head: true }).eq('user_id', u.id as string).eq('state', 'scheduled')
        .lte('due_at', new Date(now.getTime() + 31 * 86_400_000).toISOString()),
      svc.from('warranties').select('id', { count: 'exact', head: true }).eq('user_id', u.id as string).eq('date_certainty', 'unknown'),
    ]);
    const n = actions.count ?? 0;
    const m = missing.count ?? 0;
    if (n === 0 && m === 0) continue;
    const { error } = await svc.from('reminders').insert({
      user_id: u.id, reminder_type: 'monthly_digest', offset_days: 0, target_date: now.toISOString().slice(0, 10),
      local_alert_time: u.alert_local_time, timezone: u.timezone, due_at: now.toISOString(),
      title: 'Your monthly Warrantra summary',
      body: `${n} upcoming ${n === 1 ? 'deadline' : 'deadlines'} this month${m ? `; ${m} ${m === 1 ? 'coverage needs' : 'coverages need'} details` : ''}.`,
      dedupe_key: `digest:${month}`,
    });
    if (!error) queued++;
  }
  return queued;
}
