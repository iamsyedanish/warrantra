/**
 * Server-authoritative billing with Google Play directly (no third party):
 *   app purchase -> POST /me/purchases/google-play {purchase_token} -> read the
 *   subscription from the Android Publisher API -> upsert entitlement ->
 *   acknowledge. Renewals, cancellations and refunds arrive as Real-time
 *   developer notifications (Pub/Sub push) -> durably recorded (unique message
 *   id; replay = no-op) -> queued -> state re-read from Google.
 * Test (licence-tester) purchases are stored as SANDBOX and never grant
 * production access unless `billing_environment` says otherwise.
 */
import { JWT, OAuth2Client } from 'google-auth-library';
import { env } from '../../config/env.js';
import { AppError, check, unauthorized } from '../../lib/errors.js';
import { safeEqual } from '../../lib/crypto.js';
import { logger } from '../../lib/logger.js';
import { serviceClient } from '../../lib/supabase.js';
import { audit, enqueueJob, track } from '../ops.service.js';
import {
  PLAY_NOTIFICATION, deriveFromPlay, mainLineItem, orderKind, usdPrice,
  type DerivedEntitlement, type PlaySubscription,
} from './reconcile.js';

type Row = Record<string, unknown>;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const API = 'https://androidpublisher.googleapis.com/androidpublisher/v3/applications';

// ---- Google Play Developer API ----

let jwt: JWT | null = null;
function playAuth(): JWT {
  if (jwt) return jwt;
  const raw = env().GOOGLE_PLAY_SERVICE_ACCOUNT_JSON ?? env().FCM_SERVICE_ACCOUNT_JSON;
  if (!raw) throw new AppError(503, 'billing_not_configured', 'Google Play billing is not configured on the server');
  const sa = JSON.parse(raw) as { client_email: string; private_key: string };
  jwt = new JWT({ email: sa.client_email, key: sa.private_key, scopes: ['https://www.googleapis.com/auth/androidpublisher'] });
  return jwt;
}

async function play(path: string, init: { method?: string; body?: unknown } = {}): Promise<Response> {
  const { token } = await playAuth().getAccessToken();
  return fetch(`${API}/${encodeURIComponent(env().GOOGLE_PLAY_PACKAGE_NAME)}${path}`, {
    method: init.method ?? 'GET',
    headers: { Authorization: `Bearer ${token}`, Accept: 'application/json', ...(init.body ? { 'Content-Type': 'application/json' } : {}) },
    body: init.body ? JSON.stringify(init.body) : undefined,
    signal: AbortSignal.timeout(10_000),
  });
}

/** Authoritative subscription state; null when Google doesn't know the token. */
export async function fetchPlaySubscription(purchaseToken: string): Promise<PlaySubscription | null> {
  const res = await play(`/purchases/subscriptionsv2/tokens/${encodeURIComponent(purchaseToken)}`);
  if (res.status === 404 || res.status === 410) return null;
  if (res.status === 400) throw new AppError(400, 'invalid_purchase_token', 'Google Play did not recognise this purchase');
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    logger.warn({ status: res.status, body: body.slice(0, 300) }, 'Google Play API error');
    throw new AppError(502, 'play_unavailable', `Google Play API ${res.status}`);
  }
  return (await res.json()) as PlaySubscription;
}

/** Google refunds purchases not acknowledged within 3 days. Already-acknowledged is fine. */
async function acknowledge(productId: string, purchaseToken: string) {
  const res = await play(`/purchases/subscriptions/${encodeURIComponent(productId)}/tokens/${encodeURIComponent(purchaseToken)}:acknowledge`, { method: 'POST', body: {} });
  if (!res.ok && res.status !== 400) logger.warn({ status: res.status }, 'Play acknowledge failed; the app also acknowledges');
}

// ---- entitlement sync ----

async function applyEntitlement(userId: string, d: DerivedEntitlement, source: 'provider_api' | 'event', eventId: string | null) {
  const svc = serviceClient();
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
    last_event_at: new Date().toISOString(),
    last_reconciled_at: new Date().toISOString(),
    reconciliation_source: source,
  };
  return check(await svc.from('entitlements').upsert(row, { onConflict: 'user_id,entitlement_key,environment' }).select('*').single()) as Row;
}

async function productionEnvironment(): Promise<string> {
  const r = await serviceClient().from('system_settings').select('value').eq('key', 'billing_environment').maybeSingle();
  return (r.data?.value as string | undefined) ?? 'PRODUCTION';
}

/** Revenue facts + first-paid cohort row, once per Google order id. */
async function recordRevenue(userId: string, sub: PlaySubscription, d: DerivedEntitlement, billingEventId: string | null, revoked: boolean) {
  const li = mainLineItem(sub);
  const orderId = li?.latestSuccessfulOrderId ?? sub.latestOrderId;
  const price = usdPrice(li);
  if (!orderId || price === null) return;
  const svc = serviceClient();
  const kind = revoked ? 'refund' : orderKind(orderId);
  const occurred = new Date().toISOString();
  const { error } = await svc.from('revenue_transactions').insert({
    transaction_id: orderId, kind, gross_usd: kind === 'refund' ? -price : price, platform_fee_rate: null, tax_rate: null,
    occurred_at: occurred, billing_period: d.billing_period, store: 'play_store', product_id: d.product_id, country_code: null,
    user_id: userId, billing_event_id: billingEventId, environment: d.environment,
  });
  if (error) return; // already recorded (unique transaction_id, kind)
  if (kind !== 'purchase' || d.environment !== (await productionEnvironment())) return;
  const profile = await svc.from('profiles').select('acquisition_channel, referral_code').eq('id', userId).maybeSingle();
  const code = (profile.data?.referral_code as string | null)?.trim().toUpperCase();
  const referral = code ? (await svc.from('partner_referral_codes').select('partner_id').eq('code', code).eq('active', true).maybeSingle()).data : null;
  const first = new Date(occurred);
  const ins = await svc.from('customer_acquisitions').insert({
    user_id: userId,
    first_paid_at: occurred,
    cohort_month: `${first.getUTCFullYear()}-${String(first.getUTCMonth() + 1).padStart(2, '0')}-01`,
    channel: referral ? 'partner' : (profile.data?.acquisition_channel as string | null) ?? 'organic',
    partner_id: (referral?.partner_id as string | undefined) ?? null,
    first_product: d.product_id,
    billing_period: d.billing_period,
  });
  if (!ins.error) await track(userId, 'subscription_started', { billing_period: d.billing_period });
}

async function syncToken(userId: string, purchaseToken: string, sub: PlaySubscription, opts: { source: 'provider_api' | 'event'; eventId?: string | null; revoked?: boolean }) {
  const d = deriveFromPlay(sub, purchaseToken, { revoked: opts.revoked });
  if (!d) return null;
  const row = await applyEntitlement(userId, d, opts.source, opts.eventId ?? null);
  const li = mainLineItem(sub);
  if (li && sub.acknowledgementState === 'ACKNOWLEDGEMENT_STATE_PENDING' && d.state === 'active') await acknowledge(li.productId, purchaseToken);
  await recordRevenue(userId, sub, d, opts.eventId ?? null, Boolean(opts.revoked));
  return row;
}

/** Owner of a token: the account id the app attached at purchase, else whoever already holds it. */
async function ownerOf(purchaseToken: string, sub: PlaySubscription): Promise<string | null> {
  const attached = sub.externalAccountIdentifiers?.obfuscatedExternalAccountId;
  if (attached && UUID_RE.test(attached)) return attached;
  const tokens = [purchaseToken, sub.linkedPurchaseToken].filter((t): t is string => Boolean(t));
  const { data } = await serviceClient().from('entitlements').select('user_id').in('original_transaction_id', tokens).limit(1);
  return (data?.[0]?.user_id as string | undefined) ?? null;
}

/** The app hands us a purchase right after Google Play completes it (and on restore). */
export async function verifyPlayPurchase(userId: string, purchaseToken: string) {
  const sub = await fetchPlaySubscription(purchaseToken);
  if (!sub) throw new AppError(404, 'purchase_not_found', 'Google Play has no record of this purchase');
  const owner = await ownerOf(purchaseToken, sub);
  if (owner && owner !== userId) {
    throw new AppError(409, 'purchase_owned_by_other_account', 'This subscription belongs to a different Warrantra account. Sign in with that account to use it.');
  }
  const row = await syncToken(userId, purchaseToken, sub, { source: 'provider_api' });
  await audit({ actorType: 'user', actorId: userId, action: 'billing.play_purchase_verified', metadata: { state: row?.state ?? 'none' } });
  return row;
}

// ---- Real-time developer notifications (Pub/Sub push) ----

const oidc = new OAuth2Client();
export const RTDN_PATH = '/v1/webhooks/google-play';

/**
 * Pub/Sub push authenticates with a Google-signed OIDC token for our service
 * account (audience = the endpoint URL). A `?token=` shared secret is accepted
 * as an alternative when GOOGLE_PLAY_RTDN_TOKEN is set.
 */
export async function verifyRtdn(authorization: string | undefined, queryToken: unknown): Promise<void> {
  const e = env();
  if (e.GOOGLE_PLAY_RTDN_TOKEN && typeof queryToken === 'string' && safeEqual(queryToken, e.GOOGLE_PLAY_RTDN_TOKEN)) return;
  const bearer = (authorization ?? '').replace(/^Bearer\s+/i, '');
  const raw = e.GOOGLE_PLAY_SERVICE_ACCOUNT_JSON ?? e.FCM_SERVICE_ACCOUNT_JSON;
  if (!bearer || !raw) throw unauthorized('invalid_webhook_auth');
  const email = (JSON.parse(raw) as { client_email: string }).client_email;
  const audience = e.GOOGLE_PLAY_RTDN_AUDIENCE ?? `${e.PUBLIC_BASE_URL.replace(/\/$/, '')}${RTDN_PATH}`;
  try {
    const ticket = await oidc.verifyIdToken({ idToken: bearer, audience });
    const p = ticket.getPayload();
    if (!p || p.email !== email || !p.email_verified) throw new Error('wrong signer');
  } catch {
    throw unauthorized('invalid_webhook_auth');
  }
}

interface RtdnPayload {
  packageName?: string;
  eventTimeMillis?: string;
  subscriptionNotification?: { notificationType: number; purchaseToken: string; subscriptionId?: string };
  testNotification?: { version: string };
}

export async function receiveRtdn(body: unknown): Promise<{ recorded: boolean; duplicate: boolean; event_id?: string }> {
  const msg = (body as { message?: { data?: string; messageId?: string; message_id?: string } })?.message;
  const messageId = msg?.messageId ?? msg?.message_id;
  if (!msg?.data || !messageId) throw new AppError(400, 'invalid_event', 'Missing Pub/Sub message');
  let n: RtdnPayload;
  try {
    n = JSON.parse(Buffer.from(msg.data, 'base64').toString('utf8')) as RtdnPayload;
  } catch {
    throw new AppError(400, 'invalid_event', 'Unreadable notification');
  }
  const sn = n.subscriptionNotification;
  const type = n.testNotification ? 'TEST' : sn ? (PLAY_NOTIFICATION[sn.notificationType] ?? `TYPE_${sn.notificationType}`) : 'OTHER';
  const svc = serviceClient();
  const { data, error } = await svc.from('billing_events').insert({
    provider: 'google_play',
    provider_event_id: messageId,
    event_type: type,
    environment: 'PRODUCTION', // the real environment comes from Google when processed
    product_id: sn?.subscriptionId ?? null,
    store: 'play_store',
    event_timestamp: n.eventTimeMillis ? new Date(Number(n.eventTimeMillis)).toISOString() : new Date().toISOString(),
    payload: n as Record<string, unknown>,
  }).select('id').single();
  if (error) {
    if (error.code === '23505') return { recorded: false, duplicate: true };
    throw new AppError(500, 'billing_record_failed', 'Could not record event');
  }
  await enqueueJob('billing_process', { billing_event_id: data.id }, { dedupeKey: `bill:${data.id}`, priority: 5 });
  return { recorded: true, duplicate: false, event_id: data.id as string };
}

/** Worker handler for `billing_process` jobs. */
export async function processBillingEvent(billingEventId: string) {
  const svc = serviceClient();
  const row = check(await svc.from('billing_events').select('*').eq('id', billingEventId).maybeSingle()) as Row | null;
  if (!row || row.processing_state === 'processed' || row.processing_state === 'ignored') return { skipped: true };
  if (row.provider !== 'google_play') return finish(billingEventId, 'ignored', 'legacy_provider');
  await svc.from('billing_events').update({ processing_state: 'processing', attempts: Number(row.attempts) + 1 }).eq('id', billingEventId);
  const n = row.payload as RtdnPayload;
  try {
    if (n.testNotification) return finish(billingEventId, 'ignored', 'test_event');
    const sn = n.subscriptionNotification;
    if (!sn?.purchaseToken) return finish(billingEventId, 'ignored', 'not_a_subscription');
    if (n.packageName && n.packageName !== env().GOOGLE_PLAY_PACKAGE_NAME) return finish(billingEventId, 'ignored', 'other_package');
    const sub = await fetchPlaySubscription(sn.purchaseToken);
    if (!sub) return finish(billingEventId, 'ignored', 'unknown_token');
    const userId = await ownerOf(sn.purchaseToken, sub);
    if (!userId) return finish(billingEventId, 'ignored', 'unknown_app_user');
    const exists = await svc.from('profiles').select('id').eq('id', userId).maybeSingle();
    if (!exists.data) return finish(billingEventId, 'ignored', 'account_deleted');
    await svc.from('billing_events').update({ user_id: userId }).eq('id', billingEventId);
    await syncToken(userId, sn.purchaseToken, sub, { source: 'event', eventId: billingEventId, revoked: sn.notificationType === 12 });
    await audit({ actorType: 'webhook', action: `billing.${String(row.event_type).toLowerCase()}`, targetType: 'user', targetId: userId });
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

// ---- reconcile ----

/** Re-read every Play purchase this user holds from Google. */
export async function reconcileUser(userId: string) {
  const rows = check(await serviceClient().from('entitlements').select('original_transaction_id')
    .eq('user_id', userId).eq('store', 'play_store').not('original_transaction_id', 'is', null)) as Row[];
  const results: Row[] = [];
  for (const r of rows) {
    const token = String(r.original_transaction_id);
    const sub = await fetchPlaySubscription(token);
    if (!sub) continue;
    const row = await syncToken(userId, token, sub, { source: 'provider_api' });
    if (row) results.push(row);
  }
  return results;
}

/** "Restore purchases": the app re-sends tokens from the store; this re-checks what we already hold. */
export async function restore(userId: string) {
  const results = await reconcileUser(userId);
  await track(userId, 'subscription_restored', {});
  await audit({ actorType: 'user', actorId: userId, action: 'billing.restore_requested' });
  return results;
}

/** Periodic sweep: re-check entitlements near or past expiry so missed notifications are corrected. */
export async function reconcileExpiring(limit = 200) {
  const svc = serviceClient();
  const soon = new Date(Date.now() + 2 * 86_400_000).toISOString();
  const rows = check(await svc.from('entitlements').select('user_id').eq('store', 'play_store').in('state', ['active', 'grace_period', 'billing_retry'])
    .lte('valid_until', soon).limit(limit)) as Row[];
  let n = 0;
  for (const userId of new Set(rows.map((r) => String(r.user_id)))) {
    try {
      await reconcileUser(userId);
      n++;
    } catch (err) {
      logger.warn({ err }, 'reconcile failed');
    }
  }
  const failed = check(await svc.from('billing_events').select('id').eq('provider', 'google_play').in('processing_state', ['failed', 'received'])
    .lt('received_at', new Date(Date.now() - 10 * 60_000).toISOString()).limit(100)) as Row[];
  for (const f of failed) await enqueueJob('billing_process', { billing_event_id: f.id }, { dedupeKey: `bill:${f.id}` });
  return { reconciled: n, requeued: failed.length };
}
