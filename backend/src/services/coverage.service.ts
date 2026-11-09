/**
 * Coverage evidence: warranties, return windows, registrations.
 * Translates API intent (confirm / accept_estimate) into explicit, auditable
 * certainty fields. Unknown stays unknown; nothing is invented.
 */
import type { z } from 'zod';
import { check, notFound, unprocessable } from '../lib/errors.js';
import type { Db } from '../lib/supabase.js';
import { Items, Registrations, ReturnWindows, Warranties } from '../models/index.js';
import type { RegistrationInput, ReturnWindowInput, WarrantyInput } from '../validators/index.js';
import { track } from './ops.service.js';

type Row = Record<string, unknown>;
const nowIso = () => new Date().toISOString();

export function normalizeWarranty(input: Partial<z.infer<typeof WarrantyInput>>, isUpdate = false): Row {
  const { confirm, accept_estimate, ...rest } = input;
  const out: Row = { ...rest };
  if (!isUpdate && rest.start_date && !rest.start_anchor) out.start_anchor = 'custom';
  if (rest.term_kind === 'fixed_date' && rest.end_date && !rest.date_certainty && !confirm) {
    // A user-entered fixed date without confirmation is treated as an estimate.
    out.date_certainty = 'estimated';
  }
  if (confirm) {
    out.confirmed_at = nowIso();
    out.date_certainty = rest.date_certainty && rest.date_certainty !== 'unknown' && rest.date_certainty !== 'estimated'
      ? rest.date_certainty : 'user_confirmed';
  } else if (rest.date_certainty === 'document_verified' || rest.date_certainty === 'user_confirmed') {
    out.confirmed_at = nowIso();
  }
  if (accept_estimate === true) out.estimate_accepted_at = nowIso();
  if (accept_estimate === false) out.estimate_accepted_at = null;
  if (rest.term_kind === 'lifetime' || rest.term_kind === 'unknown') {
    out.end_date = null;
  }
  return out;
}

export function normalizeReturnWindow(input: Partial<z.infer<typeof ReturnWindowInput>>): Row {
  const { confirm, accept_estimate, ...rest } = input;
  const out: Row = { ...rest };
  if (rest.return_deadline && !rest.policy_anchor && rest.window_days == null) {
    out.policy_anchor = rest.anchor_date ? 'custom' : 'unknown';
  }
  if (rest.return_deadline && !rest.date_certainty && !confirm) out.date_certainty = 'estimated';
  if (rest.window_days != null && !rest.terms_state) out.terms_state = 'known';
  if (confirm) {
    out.confirmed_at = nowIso();
    if (!rest.date_certainty || rest.date_certainty === 'estimated' || rest.date_certainty === 'unknown') out.date_certainty = 'user_confirmed';
  } else if (rest.date_certainty === 'document_verified' || rest.date_certainty === 'user_confirmed') {
    out.confirmed_at = nowIso();
  }
  if (accept_estimate === true) out.estimate_accepted_at = nowIso();
  if (accept_estimate === false) out.estimate_accepted_at = null;
  if (rest.refund_amount && !rest.refund_currency) {
    throw unprocessable('refund_currency_required');
  }
  return out;
}

export function normalizeRegistration(input: Partial<z.infer<typeof RegistrationInput>>): Row {
  const out: Row = { ...input };
  if (input.deadline && !input.deadline_certainty) out.deadline_certainty = 'user_confirmed';
  return out;
}

async function assertItemOwned(db: Db, itemId: string): Promise<Row> {
  const item = check(await db.from('items').select('id, user_id').eq('id', itemId).maybeSingle());
  if (!item) throw notFound('item_not_found');
  return item as Row;
}

export const coverage = {
  async listForItem(db: Db, itemId: string) {
    const [warranties, returns, registrations, status] = await Promise.all([
      Warranties(db).list({ eq: { item_id: itemId }, orderBy: 'created_at', ascending: true, limit: 100 }),
      ReturnWindows(db).list({ eq: { item_id: itemId }, orderBy: 'created_at', ascending: true, limit: 100 }),
      Registrations(db).list({ eq: { item_id: itemId }, orderBy: 'created_at', ascending: true, limit: 100 }),
      db.from('coverage_status').select('warranty_id, time_status, days_remaining, disclosure').eq('item_id', itemId),
    ]);
    const byId = new Map(((status.data ?? []) as Row[]).map((s) => [s.warranty_id, s]));
    return {
      warranties: warranties.map((w) => ({ ...w, status: byId.get(w.id) ?? null })),
      return_windows: returns,
      registrations,
    };
  },

  async addWarranty(db: Db, userId: string, itemId: string, input: z.infer<typeof WarrantyInput>) {
    await assertItemOwned(db, itemId);
    const row = await Warranties(db).insert({ ...normalizeWarranty(input), user_id: userId, item_id: itemId });
    await track(userId, 'warranty_added', { coverage_type: String(row.coverage_type), term_kind: String(row.term_kind), date_certainty: String(row.date_certainty) });
    return row;
  },
  updateWarranty: (db: Db, id: string, patch: Partial<z.infer<typeof WarrantyInput>>, version?: number) =>
    Warranties(db).update(id, normalizeWarranty(patch, true), version, 'warranty_not_found'),
  removeWarranty: (db: Db, id: string) => Warranties(db).remove(id, 'warranty_not_found'),

  async addReturnWindow(db: Db, userId: string, itemId: string, input: z.infer<typeof ReturnWindowInput>) {
    await assertItemOwned(db, itemId);
    const row = await ReturnWindows(db).insert({ ...normalizeReturnWindow(input), user_id: userId, item_id: itemId });
    await track(userId, 'return_deadline_added', { policy_anchor: String(row.policy_anchor), terms_state: String(row.terms_state) });
    return row;
  },
  updateReturnWindow: (db: Db, id: string, patch: Partial<z.infer<typeof ReturnWindowInput>>, version?: number) =>
    ReturnWindows(db).update(id, normalizeReturnWindow(patch), version, 'return_window_not_found'),
  removeReturnWindow: (db: Db, id: string) => ReturnWindows(db).remove(id, 'return_window_not_found'),

  async addRegistration(db: Db, userId: string, itemId: string, input: z.infer<typeof RegistrationInput>) {
    await assertItemOwned(db, itemId);
    const row = await Registrations(db).insert({ ...normalizeRegistration(input), user_id: userId, item_id: itemId });
    await track(userId, 'registration_added', { requirement_state: String(row.requirement_state) });
    return row;
  },
  updateRegistration: (db: Db, id: string, patch: Partial<z.infer<typeof RegistrationInput>>, version?: number) =>
    Registrations(db).update(id, normalizeRegistration(patch), version, 'registration_not_found'),
  removeRegistration: (db: Db, id: string) => Registrations(db).remove(id, 'registration_not_found'),

  /** Labelled suggestions from curated reference data; never auto-applied. */
  suggestions: async (db: Db, itemId: string) => {
    await Items(db).get(itemId, 'item_not_found');
    const [cov, reg] = await Promise.all([
      db.rpc('suggest_coverage', { p_item_id: itemId }),
      db.rpc('suggest_registration', { p_item_id: itemId }),
    ]);
    return { ...(check(cov) as Record<string, unknown>), registrations: check(reg) };
  },
};
