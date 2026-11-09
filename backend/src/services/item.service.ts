/**
 * Items (owned products), the Action Center and the item timeline.
 */
import type { z } from 'zod';
import { check } from '../lib/errors.js';
import type { Db } from '../lib/supabase.js';
import { Items } from '../models/index.js';
import type { ItemListQuery, ItemPatch } from '../validators/index.js';
import { coverage } from './coverage.service.js';

type Row = Record<string, unknown>;

export async function listItems(db: Db, q: z.infer<typeof ItemListQuery>) {
  let query = db.from('items_overview').select('*', { count: 'exact' });
  if (q.lifecycle !== 'any') query = query.eq('lifecycle_state', q.lifecycle);
  if (q.archived !== 'any') query = query.eq('archived', q.archived === 'true');
  if (q.category_id) query = query.eq('category_id', q.category_id);
  if (q.q) {
    const term = q.q.toLowerCase().replace(/[%_,()]/g, ' ').trim();
    if (term) query = query.ilike('search_text', `%${term}%`);
  }
  const today = new Date().toISOString().slice(0, 10);
  switch (q.status) {
    case 'active_coverage':
      query = query.not('nearest_coverage_end', 'is', null);
      break;
    case 'expired_coverage':
      query = query.is('nearest_coverage_end', null).gt('coverage_count', 0);
      break;
    case 'return_soon': {
      const soon = new Date(Date.now() + 7 * 86_400_000).toISOString().slice(0, 10);
      query = query.gte('next_return_deadline', today).lte('next_return_deadline', soon);
      break;
    }
    case 'registration_pending':
      query = query.eq('registration_pending', true);
      break;
    case 'unconfirmed':
      query = query.eq('has_unconfirmed_coverage', true);
      break;
  }
  switch (q.sort) {
    case 'purchase_date':
      query = query.order('purchase_date', { ascending: false, nullsFirst: false });
      break;
    case 'coverage_urgency':
      query = query.order('next_return_deadline', { ascending: true, nullsFirst: false })
        .order('nearest_coverage_end', { ascending: true, nullsFirst: false });
      break;
    case 'value':
      query = query.order('purchase_price', { ascending: false, nullsFirst: false });
      break;
    case 'name':
      query = query.order('name', { ascending: true });
      break;
    default:
      query = query.order('created_at', { ascending: false });
  }
  const res = await query.range(q.offset, q.offset + q.limit - 1);
  return { rows: check(res) as Row[], total: res.count ?? null };
}

export async function getItemDetail(db: Db, id: string) {
  const item = await Items(db).get(id, 'item_not_found');
  const [cov, documents, claims, timeline, receiptLine] = await Promise.all([
    coverage.listForItem(db, id),
    db.from('item_attachments')
      .select('role, created_at, attachments(id, file_type, original_filename, verified_mime_type, page_count, processing_state, created_at)')
      .eq('item_id', id),
    db.from('claims').select('id, status, claim_kind, provider_name, created_at').eq('item_id', id).order('created_at', { ascending: false }),
    db.rpc('get_item_timeline', { p_item_id: id }),
    db.from('receipt_lines').select('id, purchase_group_id, line_index, original_description, quantity, line_amount, allocation_is_estimated').eq('item_id', id).maybeSingle(),
  ]);
  return {
    ...item,
    coverage: cov,
    documents: check(documents),
    claims: check(claims),
    timeline: check(timeline),
    receipt_line: check(receiptLine),
  };
}

export const updateItem = (db: Db, id: string, patch: z.infer<typeof ItemPatch>, version?: number) =>
  Items(db).update(id, patch, version, 'item_not_found');

/**
 * Deleting an item removes its links (and its own coverage/reminders) but never
 * a receipt that another item, purchase or claim still uses. Claims keep their
 * snapshot as history.
 */
export const deleteItem = (db: Db, id: string) => Items(db).remove(id, 'item_not_found');

export async function actionCenter(db: Db, horizonDays: number) {
  const rows = check(await db.rpc('get_action_center', { p_horizon_days: horizonDays })) as Row[];
  const urgent = rows.filter((r) => !String(r.kind).startsWith('missing_'));
  return {
    summary: urgent.length === 0
      ? { title: "You're all caught up", message: 'No returns, registrations, or warranties need attention right now.' }
      : { title: `${urgent.length} ${urgent.length === 1 ? 'thing needs' : 'things need'} your attention` },
    actions: urgent,
    missing_information: rows.filter((r) => String(r.kind).startsWith('missing_')),
  };
}

export async function timeline(db: Db, id: string) {
  return check(await db.rpc('get_item_timeline', { p_item_id: id }));
}
