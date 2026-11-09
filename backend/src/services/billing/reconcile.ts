/**
 * Pure entitlement derivation. Reconciles AUTHORITATIVE subscriber state from
 * RevenueCat's REST API rather than applying webhook events in arrival order.
 * An event-based fallback exists for when the API is unavailable; it ignores
 * events older than the last applied one.
 */

export type EntitlementState = 'active' | 'grace_period' | 'billing_retry' | 'expired' | 'refunded' | 'revoked' | 'paused' | 'transferred';
export type Environment = 'PRODUCTION' | 'SANDBOX';

export interface DerivedEntitlement {
  entitlement_key: string;
  environment: Environment;
  state: EntitlementState;
  renewal_intent: 'will_renew' | 'will_not_renew' | 'unknown';
  valid_from: string | null;
  valid_until: string | null;
  grace_until: string | null;
  product_id: string | null;
  store: string;
  period_type: string | null;
  billing_period: 'monthly' | 'annual' | 'other';
  original_transaction_id: string | null;
}

export interface RcSubscriberEntitlement {
  expires_date: string | null;
  grace_period_expires_date?: string | null;
  product_identifier: string;
  purchase_date: string | null;
}

export interface RcSubscription {
  expires_date: string | null;
  purchase_date?: string | null;
  original_purchase_date?: string | null;
  period_type?: string | null;
  store?: string | null;
  is_sandbox?: boolean;
  unsubscribe_detected_at?: string | null;
  billing_issues_detected_at?: string | null;
  grace_period_expires_date?: string | null;
  refunded_at?: string | null;
  store_transaction_id?: string | null;
}

export interface RcSubscriber {
  entitlements: Record<string, RcSubscriberEntitlement>;
  subscriptions: Record<string, RcSubscription>;
}

export const mapStore = (s: string | null | undefined): string =>
  ({ APP_STORE: 'app_store', app_store: 'app_store', PLAY_STORE: 'play_store', play_store: 'play_store', STRIPE: 'stripe', stripe: 'stripe',
     PROMOTIONAL: 'promotional', promotional: 'promotional', AMAZON: 'amazon', amazon: 'amazon', MAC_APP_STORE: 'mac_app_store',
     mac_app_store: 'mac_app_store' } as Record<string, string>)[s ?? ''] ?? 'unknown';

export const mapPeriodType = (p: string | null | undefined): string | null =>
  p ? ({ NORMAL: 'normal', normal: 'normal', TRIAL: 'trial', trial: 'trial', INTRO: 'intro', intro: 'intro', PROMOTIONAL: 'promotional',
         promotional: 'promotional', PREPAID: 'prepaid', prepaid: 'prepaid' } as Record<string, string>)[p] ?? null : null;

export function billingPeriodOf(productId: string | null | undefined): 'monthly' | 'annual' | 'other' {
  const p = (productId ?? '').toLowerCase();
  if (/(annual|yearly|year|1y|12m|p1y)/.test(p)) return 'annual';
  if (/(monthly|month|1m|p1m)/.test(p)) return 'monthly';
  return 'other';
}

const after = (iso: string | null | undefined, now: Date) => Boolean(iso && new Date(iso).getTime() > now.getTime());

export function deriveFromSubscriber(sub: RcSubscriber, entitlementKey: string, now = new Date()): DerivedEntitlement | null {
  const ent = sub.entitlements?.[entitlementKey];
  if (!ent) return null;
  const s = sub.subscriptions?.[ent.product_identifier] ?? ({} as RcSubscription);
  const environment: Environment = s.is_sandbox ? 'SANDBOX' : 'PRODUCTION';
  const store = mapStore(s.store);
  const grace = ent.grace_period_expires_date ?? s.grace_period_expires_date ?? null;

  let state: EntitlementState;
  let validUntil = ent.expires_date;
  if (s.refunded_at) {
    state = 'refunded';
    validUntil = s.refunded_at;
  } else if (ent.expires_date === null) {
    state = 'active'; // lifetime / non-expiring promotional grant
  } else if (after(ent.expires_date, now)) {
    state = 'active';
  } else if (s.billing_issues_detected_at && after(grace, now)) {
    state = 'grace_period';
  } else if (s.billing_issues_detected_at && !s.unsubscribe_detected_at) {
    state = 'billing_retry'; // store still retrying; no paid access past valid_until
  } else {
    state = 'expired';
  }

  const renewal: DerivedEntitlement['renewal_intent'] =
    state === 'refunded' || state === 'expired' ? 'will_not_renew' : s.unsubscribe_detected_at ? 'will_not_renew' : ent.expires_date ? 'will_renew' : 'unknown';

  return {
    entitlement_key: entitlementKey,
    environment,
    state,
    renewal_intent: renewal,
    valid_from: ent.purchase_date ?? s.purchase_date ?? null,
    valid_until: validUntil,
    grace_until: grace,
    product_id: ent.product_identifier,
    store,
    period_type: mapPeriodType(s.period_type),
    billing_period: billingPeriodOf(ent.product_identifier),
    original_transaction_id: s.store_transaction_id ?? null,
  };
}

export interface RcEvent {
  id: string;
  type: string;
  app_user_id?: string;
  original_app_user_id?: string;
  aliases?: string[];
  environment: Environment;
  product_id?: string;
  entitlement_ids?: string[] | null;
  period_type?: string;
  purchased_at_ms?: number | null;
  expiration_at_ms?: number | null;
  grace_period_expiration_at_ms?: number | null;
  event_timestamp_ms?: number;
  store?: string;
  price?: number | null;
  takehome_percentage?: number | null;
  commission_percentage?: number | null;
  tax_percentage?: number | null;
  transaction_id?: string | null;
  original_transaction_id?: string | null;
  cancel_reason?: string | null;
  country_code?: string | null;
  transferred_from?: string[];
  transferred_to?: string[];
}

const iso = (ms: number | null | undefined) => (ms ? new Date(ms).toISOString() : null);

/** Fallback derivation from a single event when the authoritative API is unavailable. */
export function deriveFromEvent(ev: RcEvent, entitlementKey: string, now = new Date()): DerivedEntitlement | null {
  if (!(ev.entitlement_ids ?? []).includes(entitlementKey)) return null;
  const validUntil = iso(ev.expiration_at_ms);
  const grace = iso(ev.grace_period_expiration_at_ms);
  let state: EntitlementState;
  let renewal: DerivedEntitlement['renewal_intent'] = 'will_renew';
  switch (ev.type) {
    case 'INITIAL_PURCHASE':
    case 'RENEWAL':
    case 'UNCANCELLATION':
    case 'PRODUCT_CHANGE':
    case 'SUBSCRIPTION_EXTENDED':
    case 'REFUND_REVERSED':
    case 'TEMPORARY_ENTITLEMENT_GRANT':
    case 'NON_RENEWING_PURCHASE':
      state = after(validUntil, now) || validUntil === null ? 'active' : 'expired';
      if (ev.type === 'NON_RENEWING_PURCHASE') renewal = 'will_not_renew';
      break;
    case 'CANCELLATION':
      if (ev.cancel_reason === 'CUSTOMER_SUPPORT') {
        state = 'refunded';
      } else {
        // Cancellation changes renewal intent; access continues until expiry.
        state = after(validUntil, now) ? 'active' : 'expired';
      }
      renewal = 'will_not_renew';
      break;
    case 'BILLING_ISSUE':
      state = after(grace, now) ? 'grace_period' : after(validUntil, now) ? 'active' : 'billing_retry';
      break;
    case 'SUBSCRIPTION_PAUSED':
      state = after(validUntil, now) ? 'active' : 'paused';
      break;
    case 'EXPIRATION':
      state = 'expired';
      renewal = 'will_not_renew';
      break;
    default:
      return null;
  }
  return {
    entitlement_key: entitlementKey,
    environment: ev.environment,
    state,
    renewal_intent: renewal,
    valid_from: iso(ev.purchased_at_ms),
    valid_until: state === 'refunded' ? iso(ev.event_timestamp_ms) : validUntil,
    grace_until: grace,
    product_id: ev.product_id ?? null,
    store: mapStore(ev.store),
    period_type: mapPeriodType(ev.period_type),
    billing_period: billingPeriodOf(ev.product_id),
    original_transaction_id: ev.original_transaction_id ?? null,
  };
}

/** Revenue facts for profitability monitoring (null if the event carries no money movement). */
export function revenueFromEvent(ev: RcEvent): null | {
  transaction_id: string; kind: 'purchase' | 'renewal' | 'refund'; gross_usd: number; platform_fee_rate: number | null;
  tax_rate: number | null; occurred_at: string; billing_period: string; store: string; product_id: string | null; country_code: string | null;
} {
  if (!ev.transaction_id || ev.price === null || ev.price === undefined) return null;
  let kind: 'purchase' | 'renewal' | 'refund';
  if (ev.type === 'INITIAL_PURCHASE' || ev.type === 'NON_RENEWING_PURCHASE') kind = 'purchase';
  else if (ev.type === 'RENEWAL') kind = 'renewal';
  else if (ev.type === 'CANCELLATION' && ev.cancel_reason === 'CUSTOMER_SUPPORT') kind = 'refund';
  else return null;
  const gross = kind === 'refund' ? -Math.abs(ev.price) : ev.price;
  return {
    transaction_id: ev.transaction_id,
    kind,
    gross_usd: Math.round(gross * 100) / 100,
    platform_fee_rate: ev.commission_percentage ?? null,
    tax_rate: ev.tax_percentage ?? null,
    occurred_at: iso(ev.event_timestamp_ms) ?? new Date().toISOString(),
    billing_period: billingPeriodOf(ev.product_id),
    store: mapStore(ev.store),
    product_id: ev.product_id ?? null,
    country_code: ev.country_code ?? null,
  };
}
