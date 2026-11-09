/**
 * Server-authoritative billing:
 *   webhook (authenticated) -> durably record immutable event (unique id; replay
 *   = no-op) -> queue processing -> reconcile authoritative subscriber state ->
 *   upsert entitlements per environment -> revenue facts + cohort membership.
 * Sandbox events are stored but never grant production access.
 */
import { env } from '../../config/env.js';
import { AppError, check, unauthorized } from '../../lib/errors.js';
import { safeEqual } from '../../lib/crypto.js';
import { logger } from '../../lib/logger.js';
import { serviceClient } from '../../lib/supabase.js';
import { audit, enqueueJob, track } from '../ops.service.js';
import {
  deriveFromEvent, deriveFromSubscriber, revenueFromEvent,
  type DerivedEntitlement, type RcEvent, type RcSubscriber,
} from './reconcile.js';

type Row = Record<string, unknown>;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function verifyWebhookAuth(header: string | undefined): void {
  const expected = env().REVENUECAT_WEBHOOK_AUTH;
  const got = (header ?? '').replace(/^Bearer\s+/i, '');
  if (!got || !safeEqual(got, expected)) throw unauthorized('invalid_webhook_auth');
}

/** Durably record, then process asynchronously. Duplicate deliveries are acknowledged without effect. */
export async function receiveWebhook(body: unknown): Promise<{ recorded: boolean; duplicate: boolean; event_id?: string }> {
  const ev = (body as { event?: RcEvent })?.event;
  if (!ev?.id || !ev.type || !ev.environment) throw new AppError(400, 'invalid_event', 'Missing event fields');
  const svc = serviceClient();
  const userId = await resolveUserId(ev);
  const { data, error } = await svc
    .from('billing_events')
    .insert({
      provider: 'revenuecat',
      provider_event_id: ev.id,
      event_type: ev.type,
      environment: ev.environment,
      app_user_id: ev.app_user_id ?? null,
      original_app_user_id: ev.original_app_user_id ?? null,
      user_id: userId,
      product_id: ev.product_id ?? null,
      store: ev.store ?? null,
      entitlement_ids: ev.entitlement_ids ?? [],
      event_timestamp: ev.event_timestamp_ms ? new Date(ev.event_timestamp_ms).toISOString() : null,
      payload: body as Record<string, unknown>,
    })
    .select('id')
    .single();
  if (error) {
    if (error.code === '23505') return { recorded: false, duplicate: true };
    throw new AppError(500, 'billing_record_failed', 'Could not record event');
  }
  await enqueueJob('billing_process', { billing_event_id: data.id }, { userId: userId ?? undefined, dedupeKey: `bill:${data.id}`, priority: 5 });
  return { recorded: true, duplicate: false, event_id: data.id as string };
}

async function resolveUserId(ev: RcEvent): Promise<string | null> {
  const candidates = [ev.app_user_id, ev.original_app_user_id, ...(ev.aliases ?? [])].filter((x): x is string => Boolean(x && UUID_RE.test(x)));
  if (candidates.length === 0) return null;
  const { data } = await serviceClient().from('profiles').select('id').in('id', candidates).limit(1);
  return (data?.[0]?.id as string | undefined) ?? null;
}

async function fetchSubscriber(appUserId: string): Promise<RcSubscriber | null> {
  const key = env().REVENUECAT_SECRET_API_KEY;
  if (!key) return null;
  const res = await fetch(`https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(appUserId)}`, {
    headers: { Authorization: `Bearer ${key}`, Accept: 'application/json' },
    signal: AbortSignal.timeout(10_000),
  });
  if (res.status === 404) return { entitlements: {}, subscriptions: {} };
  if (!res.ok) throw new AppError(502, 'revenuecat_unavailable', `RevenueCat API ${res.status}`);
  const body = (await res.json()) as { subscriber: RcSubscriber };
  return body.subscriber;
}

async function applyEntitlement(userId: string, d: DerivedEntitlement, source: 'provider_api' | 'event', eventId: string | null, eventAt: string | null) {
  const svc = serviceClient();
  const existing = check(await svc.from('entitlements').select('id, last_event_at, state')
    .eq('user_id', userId).eq('entitlement_key', d.entitlement_key).eq('environment', d.environment).maybeSingle()) as Row | null;
  // Event fallback must not regress state with an older, delayed event.
  if (source === 'event' && existing?.last_event_at && eventAt && new Date(eventAt) < new Date(String(existing.last_event_at))) {
    logger.info({ userId, eventId }, 'stale billing event ignored');
    return existing;
  }
  const row = {
    user_id: userId,
    entitlement_key: d.entitlement_key,
    environment: d.environment,
    state: d.state,
    renewal_intent: d.renewal_intent,
    valid_from: d.valid_from,
    valid_until: d.valid_until,
    grace_until: d.grace_until,
    product_id: d.product_id,
    store: d.store,
    period_type: d.period_type,
    billing_period: d.billing_period,
    original_transaction_id: d.original_transaction_id,
    last_event_id: eventId,
    last_event_at: eventAt ?? (existing?.last_event_at as string | null) ?? null,
    last_reconciled_at: new Date().toISOString(),
    reconciliation_source: source,
  };
  return check(await svc.from('entitlements').upsert(row, { onConflict: 'user_id,entitlement_key,environment' }).select('*').single()) as Row;
}

/** Reconcile one user's entitlements from the authoritative source. */
export async function reconcileUser(userId: string, opts: { event?: RcEvent; eventRowId?: string } = {}) {
  const keys = [env().REVENUECAT_PRO_ENTITLEMENT, env().REVENUECAT_BUSINESS_ENTITLEMENT];
  const keyMap: Record<string, 'pro' | 'business_pilot'> = {
    [env().REVENUECAT_PRO_ENTITLEMENT]: 'pro',
    [env().REVENUECAT_BUSINESS_ENTITLEMENT]: 'business_pilot',
  };
  const eventAt = opts.event?.event_timestamp_ms ? new Date(opts.event.event_timestamp_ms).toISOString() : null;
  const results: Row[] = [];
  let subscriber: RcSubscriber | null = null;
  try {
    subscriber = await fetchSubscriber(userId);
  } catch (err) {
    logger.warn({ err }, 'RevenueCat API unavailable; using event fallback');
  }

  for (const rcKey of keys) {
    const derived = subscriber ? deriveFromSubscriber(subscriber, rcKey) : opts.event ? deriveFromEvent(opts.event, rcKey) : null;
    if (!derived) {
      if (subscriber) {
        // Authoritative API says no entitlement: expire any active production row.
        const svc = serviceClient();
        await svc.from('entitlements').update({ state: 'expired', renewal_intent: 'will_not_renew', last_reconciled_at: new Date().toISOString(), reconciliation_source: 'provider_api' })
          .eq('user_id', userId).eq('entitlement_key', keyMap[rcKey]!).in('state', ['active', 'grace_period', 'billing_retry', 'paused']);
      }
      continue;
    }
    derived.entitlement_key = keyMap[rcKey]!;
    results.push(await applyEntitlement(userId, derived, subscriber ? 'provider_api' : 'event', opts.eventRowId ?? null, eventAt));
  }
  return results;
}

/** Worker handler for `billing_process` jobs. */
export async function processBillingEvent(billingEventId: string) {
  const svc = serviceClient();
  const row = check(await svc.from('billing_events').select('*').eq('id', billingEventId).maybeSingle()) as Row | null;
  if (!row || row.processing_state === 'processed' || row.processing_state === 'ignored') return { skipped: true };
  await svc.from('billing_events').update({ processing_state: 'processing', attempts: Number(row.attempts) + 1 }).eq('id', billingEventId);
  const ev = (row.payload as { event: RcEvent }).event;

  try {
    if (ev.type === 'TEST') return finish(billingEventId, 'ignored', 'test_event');
    const configuredEnv = await svc.from('system_settings').select('value').eq('key', 'billing_environment').maybeSingle();
    const productionEnv = (configuredEnv.data?.value as string | undefined) ?? 'PRODUCTION';

    const users = new Set<string>();
    const primary = (row.user_id as string | null) ?? null;
    if (primary) users.add(primary);
    if (ev.type === 'TRANSFER') {
      for (const id of [...(ev.transferred_from ?? []), ...(ev.transferred_to ?? [])]) if (UUID_RE.test(id)) users.add(id);
    }
    if (users.size === 0) return finish(billingEventId, 'ignored', 'unknown_app_user');

    for (const userId of users) {
      const exists = await svc.from('profiles').select('id').eq('id', userId).maybeSingle();
      if (!exists.data) continue; // deleted account: keep event, nothing to grant
      await reconcileUser(userId, { event: ev.type === 'TRANSFER' ? undefined : ev, eventRowId: billingEventId });
    }

    // Revenue facts (both environments recorded; reports filter to production).
    const rev = revenueFromEvent(ev);
    if (rev && primary) {
      await svc.from('revenue_transactions').upsert({ ...rev, user_id: primary, billing_event_id: billingEventId, environment: ev.environment },
        { onConflict: 'transaction_id,kind', ignoreDuplicates: true });
      if (rev.kind === 'purchase' && ev.environment === productionEnv) {
        const profile = await svc.from('profiles').select('acquisition_channel, referral_code').eq('id', primary).maybeSingle();
        const first = new Date(rev.occurred_at);
        const code = (profile.data?.referral_code as string | null)?.trim().toUpperCase();
        const referral = code
          ? (await svc.from('partner_referral_codes').select('partner_id').eq('code', code).eq('active', true).maybeSingle()).data
          : null;
        const { error } = await svc.from('customer_acquisitions').insert({
          user_id: primary,
          first_paid_at: rev.occurred_at,
          cohort_month: `${first.getUTCFullYear()}-${String(first.getUTCMonth() + 1).padStart(2, '0')}-01`,
          channel: referral ? 'partner' : (profile.data?.acquisition_channel as string | null) ?? 'organic',
          partner_id: (referral?.partner_id as string | undefined) ?? null,
          first_product: rev.product_id,
          billing_period: rev.billing_period,
        });
        if (!error) await track(primary, 'subscription_started', { billing_period: rev.billing_period });
      }
    }
    await audit({ actorType: 'webhook', action: `billing.${ev.type.toLowerCase()}`, targetType: 'user', targetId: primary ?? undefined,
                  metadata: { environment: ev.environment, product_id: ev.product_id } });
    return finish(billingEventId, 'processed', null);
  } catch (err) {
    await svc.from('billing_events').update({ processing_state: 'failed', processing_note: (err as Error).message.slice(0, 300) }).eq('id', billingEventId);
    throw err;
  }
}

async function finish(id: string, state: 'processed' | 'ignored', note: string | null) {
  await serviceClient().from('billing_events').update({ processing_state: state, processing_note: note, processed_at: new Date().toISOString() }).eq('id', id);
  return { state, note };
}

/** Client "restore purchases": the app restores with RevenueCat, then asks us to reconcile. */
export async function restore(userId: string) {
  const results = await reconcileUser(userId);
  await track(userId, 'subscription_restored', {});
  await audit({ actorType: 'user', actorId: userId, action: 'billing.restore_requested' });
  return results;
}

/** Periodic sweep: re-check entitlements near or past expiry so missed events are corrected. */
export async function reconcileExpiring(limit = 200) {
  const svc = serviceClient();
  const soon = new Date(Date.now() + 2 * 86_400_000).toISOString();
  const rows = check(await svc.from('entitlements').select('user_id').in('state', ['active', 'grace_period', 'billing_retry'])
    .lte('valid_until', soon).limit(limit)) as Row[];
  let n = 0;
  for (const r of rows) {
    try {
      await reconcileUser(String(r.user_id));
      n++;
    } catch (err) {
      logger.warn({ err }, 'reconcile failed');
    }
  }
  // Retry events that failed processing.
  const failed = check(await svc.from('billing_events').select('id').in('processing_state', ['failed', 'received'])
    .lt('received_at', new Date(Date.now() - 10 * 60_000).toISOString()).limit(100)) as Row[];
  for (const f of failed) await enqueueJob('billing_process', { billing_event_id: f.id }, { dedupeKey: `bill:${f.id}` });
  return { reconciled: n, requeued: failed.length };
}
