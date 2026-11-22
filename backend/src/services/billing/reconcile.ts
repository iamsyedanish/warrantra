/**
 * Pure entitlement derivation from Google Play's authoritative subscription
 * state (Android Publisher API `purchases.subscriptionsv2.get`). Real-time
 * developer notifications only tell us *which* purchase changed; the state
 * itself is always re-read from Google, so delayed or out-of-order
 * notifications cannot regress an entitlement.
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

export interface PlayMoney { currencyCode?: string; units?: string; nanos?: number }

export interface PlayLineItem {
  productId: string;
  expiryTime?: string;
  latestSuccessfulOrderId?: string;
  autoRenewingPlan?: { autoRenewEnabled?: boolean; recurringPrice?: PlayMoney };
  prepaidPlan?: Record<string, unknown>;
  offerDetails?: { basePlanId?: string; offerId?: string; offerTags?: string[] };
}

/** Subset of SubscriptionPurchaseV2 that we use. */
export interface PlaySubscription {
  subscriptionState: string;
  startTime?: string;
  latestOrderId?: string;
  linkedPurchaseToken?: string;
  acknowledgementState?: string;
  testPurchase?: Record<string, unknown>;
  externalAccountIdentifiers?: { obfuscatedExternalAccountId?: string; obfuscatedExternalProfileId?: string };
  lineItems?: PlayLineItem[];
}

/** RTDN subscriptionNotification.notificationType values. */
export const PLAY_NOTIFICATION: Record<number, string> = {
  1: 'SUBSCRIPTION_RECOVERED', 2: 'SUBSCRIPTION_RENEWED', 3: 'SUBSCRIPTION_CANCELED', 4: 'SUBSCRIPTION_PURCHASED',
  5: 'SUBSCRIPTION_ON_HOLD', 6: 'SUBSCRIPTION_IN_GRACE_PERIOD', 7: 'SUBSCRIPTION_RESTARTED', 8: 'SUBSCRIPTION_PRICE_CHANGE_CONFIRMED',
  9: 'SUBSCRIPTION_DEFERRED', 10: 'SUBSCRIPTION_PAUSED', 11: 'SUBSCRIPTION_PAUSE_SCHEDULE_CHANGED', 12: 'SUBSCRIPTION_REVOKED',
  13: 'SUBSCRIPTION_EXPIRED', 17: 'SUBSCRIPTION_ITEMS_CHANGED', 18: 'SUBSCRIPTION_CANCELLATION_SCHEDULED',
  19: 'SUBSCRIPTION_PRICE_CHANGE_UPDATED', 20: 'SUBSCRIPTION_PENDING_PURCHASE_CANCELED', 22: 'SUBSCRIPTION_PRICE_STEP_UP_CONSENT_UPDATED',
};

export function billingPeriodOf(id: string | null | undefined): 'monthly' | 'annual' | 'other' {
  const p = (id ?? '').toLowerCase();
  if (/(annual|yearly|year|1y|12m|p1y)/.test(p)) return 'annual';
  if (/(monthly|month|1m|p1m)/.test(p)) return 'monthly';
  return 'other';
}

/** Latest-expiring line item (a subscription normally has exactly one). */
export function mainLineItem(sub: PlaySubscription): PlayLineItem | null {
  const items = sub.lineItems ?? [];
  if (items.length === 0) return null;
  return [...items].sort((a, b) => Date.parse(b.expiryTime ?? '0') - Date.parse(a.expiryTime ?? '0'))[0]!;
}

const after = (iso: string | null | undefined, now: Date) => Boolean(iso && new Date(iso).getTime() > now.getTime());

/**
 * Map Google's subscription state to an entitlement. `revoked` comes from the
 * SUBSCRIPTION_REVOKED notification: Google refunded and removed access, which
 * the v2 resource reports only as EXPIRED.
 */
export function deriveFromPlay(sub: PlaySubscription, purchaseToken: string, opts: { revoked?: boolean; entitlementKey?: string; now?: Date } = {}): DerivedEntitlement | null {
  const now = opts.now ?? new Date();
  const li = mainLineItem(sub);
  if (!li) return null;
  if (sub.subscriptionState === 'SUBSCRIPTION_STATE_PENDING' || sub.subscriptionState === 'SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED') return null;
  const expiry = li.expiryTime ?? null;
  let state: EntitlementState;
  switch (sub.subscriptionState) {
    case 'SUBSCRIPTION_STATE_ACTIVE':
      state = 'active';
      break;
    case 'SUBSCRIPTION_STATE_CANCELED':
      // Cancelled = will not renew; access continues until the paid period ends.
      state = after(expiry, now) ? 'active' : 'expired';
      break;
    case 'SUBSCRIPTION_STATE_IN_GRACE_PERIOD':
      state = 'grace_period';
      break;
    case 'SUBSCRIPTION_STATE_ON_HOLD':
      state = 'billing_retry';
      break;
    case 'SUBSCRIPTION_STATE_PAUSED':
      state = 'paused';
      break;
    default:
      state = 'expired';
  }
  if (opts.revoked) state = 'refunded';

  const renews = li.autoRenewingPlan?.autoRenewEnabled;
  const renewal: DerivedEntitlement['renewal_intent'] =
    state === 'refunded' || state === 'expired' || li.prepaidPlan ? 'will_not_renew' : renews === true ? 'will_renew' : renews === false ? 'will_not_renew' : 'unknown';

  return {
    entitlement_key: opts.entitlementKey ?? 'pro',
    environment: sub.testPurchase ? 'SANDBOX' : 'PRODUCTION',
    state,
    renewal_intent: renewal,
    valid_from: sub.startTime ?? null,
    valid_until: state === 'refunded' ? now.toISOString() : expiry,
    grace_until: state === 'grace_period' ? expiry : null,
    product_id: li.offerDetails?.basePlanId ? `${li.productId}:${li.offerDetails.basePlanId}` : li.productId,
    store: 'play_store',
    period_type: li.offerDetails?.offerId ? 'intro' : li.prepaidPlan ? 'prepaid' : 'normal',
    billing_period: billingPeriodOf(li.offerDetails?.basePlanId ?? li.productId),
    original_transaction_id: purchaseToken,
  };
}

/** Recurring price in USD, or null when Google reports another currency (gross is tracked in USD only). */
export function usdPrice(li: PlayLineItem | null): number | null {
  const m = li?.autoRenewingPlan?.recurringPrice;
  if (!m || m.currencyCode !== 'USD') return null;
  return Math.round((Number(m.units ?? 0) + (m.nanos ?? 0) / 1e9) * 100) / 100;
}

/** Google order ids look like GPA.1234-5678-9012-34567 with `..N` appended per renewal. */
export function orderKind(orderId: string): 'purchase' | 'renewal' {
  return /\.\.\d+$/.test(orderId) ? 'renewal' : 'purchase';
}
