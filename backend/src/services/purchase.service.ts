/**
 * Purchase capture: one receipt (purchase group) -> receipt lines -> the items
 * the user selected to track. Allocation happens here in integer cents; the
 * database RPC saves everything in one transaction and re-validates totals.
 */
import type { z } from 'zod';
import { check, unprocessable } from '../lib/errors.js';
import { allocateGroup, checkGroupConsistency, fromCents, toCents } from '../lib/money.js';
import type { Db } from '../lib/supabase.js';
import { Items, PurchaseGroups } from '../models/index.js';
import type { PurchaseInput, QuickAddItemInput, TrackLineBody } from '../validators/index.js';
import { normalizeRegistration, normalizeReturnWindow, normalizeWarranty } from './coverage.service.js';
import { track } from './ops.service.js';

type PurchaseBody = z.infer<typeof PurchaseInput>;

export interface CreatePurchaseResult {
  purchase_group_id: string;
  created: boolean;
  item_ids: string[];
  line_ids: string[];
  warnings: { code: string; message: string }[];
}

export function buildPurchasePayload(idempotencyKey: string, body: PurchaseBody) {
  const lines = body.lines;
  const group = {
    subtotalCents: toCents(body.subtotal ?? null),
    taxCents: toCents(body.tax ?? null),
    shippingCents: toCents(body.shipping ?? null),
    discountCents: toCents(body.discount ?? null),
    totalCents: toCents(body.total_paid ?? null),
  };
  const forAlloc = lines.map((l) => ({ lineCents: toCents(l.line_amount ?? null) }));
  const allocations = allocateGroup(forAlloc, group);
  const warnings = checkGroupConsistency(forAlloc, group);

  if (lines.length > 1 && lines.some((l) => l.track) && forAlloc.every((l) => l.lineCents === null) && group.totalCents !== null) {
    warnings.push({
      code: 'item_values_unknown',
      message: 'Line amounts are missing, so item values are left blank instead of repeating the receipt total.',
    });
  }

  const payloadLines = lines.map((l, index) => {
    const a = allocations[index]!;
    const t = l.track;
    return {
      line_index: index,
      original_description: l.original_description ?? null,
      confirmed_name: l.confirmed_name ?? t?.name ?? null,
      sku: l.sku ?? null,
      quantity: l.quantity ?? 1,
      unit_amount: l.unit_amount ?? null,
      line_amount: l.line_amount ?? null,
      allocated_tax: fromCents(a.taxCents),
      allocated_shipping: fromCents(a.shippingCents),
      allocated_discount: fromCents(a.discountCents),
      allocation_is_estimated: a.estimated,
      confirmation_state: l.confirmation_state ?? 'user_confirmed',
      item: t
        ? {
            name: t.name ?? l.confirmed_name ?? l.original_description ?? null,
            brand: t.brand ?? null,
            brand_id: t.brand_id ?? null,
            model_number: t.model_number ?? null,
            serial_number: t.serial_number ?? null,
            sku: t.sku ?? l.sku ?? null,
            category_id: t.category_id ?? null,
            condition_at_purchase: t.condition_at_purchase ?? 'unknown',
            quantity: t.quantity ?? 1,
            notes: t.notes ?? null,
            // Item value = its own line (+ allocated tax/shipping - discount); never the receipt total.
            purchase_price: fromCents(a.itemValueCents),
            price_is_estimated: a.estimated,
            attachment_ids: t.attachment_ids ?? [],
            warranties: (t.warranties ?? []).map((w) => normalizeWarranty(w)),
            return_window: t.return_window ? normalizeReturnWindow(t.return_window) : null,
            registration: t.registration ? normalizeRegistration(t.registration) : null,
          }
        : null,
    };
  });

  if (!payloadLines.some((l) => l.item)) {
    throw unprocessable('no_items_selected', 'Select at least one line to track as an item');
  }
  for (const l of payloadLines) {
    if (l.item && !l.item.name) throw unprocessable('item_name_required', `Line ${l.line_index + 1} needs a product name`);
  }

  return {
    payload: {
      idempotency_key: idempotencyKey,
      retailer: body.retailer ?? null,
      order_number: body.order_number ?? null,
      purchase_date: body.purchase_date ?? null,
      delivery_date: body.delivery_date ?? null,
      currency: body.currency ?? 'USD',
      subtotal: body.subtotal ?? null,
      tax: body.tax ?? null,
      shipping: body.shipping ?? null,
      discount: body.discount ?? null,
      total_paid: body.total_paid ?? null,
      source: body.source ?? 'manual',
      payment_card_id: body.payment_card_id ?? null,
      scan_job_id: body.scan_job_id ?? null,
      capture_draft_id: body.capture_draft_id ?? null,
      correction_count: body.correction_count ?? null,
      notes: body.notes ?? null,
      attachment_ids: body.attachment_ids ?? [],
      lines: payloadLines,
    },
    warnings,
  };
}

type DraftField = { value: string | number | null } | undefined;

/**
 * Corrections = fields where what the user saved differs from what extraction
 * proposed (spec §5: record correction rates). Measured by the server, never
 * trusted from the client.
 */
export function countCorrections(draft: Record<string, unknown> | null | undefined, body: PurchaseBody): number {
  if (!draft) return 0;
  const norm = (v: unknown) => (v === null || v === undefined || v === '' ? null : String(v).trim().toLowerCase());
  const money = (v: unknown) => (v === null || v === undefined || v === '' ? null : Number(v).toFixed(2));
  const field = (k: string) => (draft[k] as DraftField)?.value ?? null;
  let n = 0;
  if (norm(field('merchant')) !== norm(body.retailer)) n++;
  if (norm(field('purchase_date')) !== norm(body.purchase_date)) n++;
  if (norm(field('delivery_date')) !== norm(body.delivery_date)) n++;
  if (norm(field('order_number')) !== norm(body.order_number)) n++;
  if (field('currency') !== null && norm(field('currency')) !== norm(body.currency ?? 'USD')) n++;
  for (const k of ['subtotal', 'tax', 'shipping', 'discount', 'total_paid'] as const) {
    if (money(field(k)) !== money(body[k])) n++;
  }
  const lines = (draft.lines as Array<{ description: string | null; line_amount: string | null }> | undefined) ?? [];
  n += Math.abs(lines.length - body.lines.length);
  body.lines.forEach((l, i) => {
    const d = lines[i];
    if (!d) return;
    if (money(d.line_amount) !== money(l.line_amount)) n++;
    if (norm(d.description) !== norm(l.original_description ?? l.confirmed_name)) n++;
  });
  return n;
}

export async function createPurchase(db: Db, userId: string, idempotencyKey: string, body: PurchaseBody): Promise<CreatePurchaseResult> {
  if (body.scan_job_id) {
    const job = check(await db.from('scan_jobs').select('candidate').eq('id', body.scan_job_id).maybeSingle()) as
      { candidate: { review_draft?: Record<string, unknown> } | null } | null;
    body = { ...body, correction_count: countCorrections(job?.candidate?.review_draft, body) };
  } else {
    body = { ...body, correction_count: undefined };
  }
  if (body.purchase_date && body.delivery_date && body.delivery_date < body.purchase_date) {
    throw unprocessable('delivery_before_purchase', 'Delivery date cannot be before the purchase date');
  }
  const { payload, warnings } = buildPurchasePayload(idempotencyKey, body);
  const result = check(await db.rpc('create_purchase', { p: payload })) as Omit<CreatePurchaseResult, 'warnings'>;
  if (result.created) {
    const src = payload.source;
    await track(userId, 'item_created', { source: src });
    await track(userId, src === 'receipt_scan' ? 'item_created_receipt_scan' : 'item_created_manual',
      src === 'receipt_scan' ? { line_count: payload.lines.length } : {});
  }
  return { ...result, warnings };
}

/** Manual quick add: a single item is a purchase group with one line. */
export async function quickAddItem(db: Db, userId: string, idempotencyKey: string, body: z.infer<typeof QuickAddItemInput>) {
  const { retailer_name, order_number, purchase_date, delivery_date, purchase_price, currency, payment_card_id, attachment_ids,
          warranties, return_window, registration, ...item } = body;
  return createPurchase(db, userId, idempotencyKey, {
    retailer: retailer_name ?? null,
    order_number: order_number ?? null,
    purchase_date: purchase_date ?? null,
    delivery_date: delivery_date ?? null,
    currency,
    subtotal: purchase_price ?? null,
    total_paid: purchase_price ?? null,
    source: 'manual',
    payment_card_id: payment_card_id ?? null,
    attachment_ids: attachment_ids ?? [],
    lines: [
      {
        original_description: item.name,
        confirmed_name: item.name,
        line_amount: purchase_price ?? null,
        quantity: item.quantity ?? 1,
        confirmation_state: 'user_confirmed',
        track: { ...item, warranties, return_window, registration },
      },
    ],
  });
}

export async function getPurchase(db: Db, id: string) {
  const group = await PurchaseGroups(db).get(id, 'purchase_not_found');
  const [lines, items, attachments] = await Promise.all([
    db.from('receipt_lines').select('*').eq('purchase_group_id', id).order('line_index'),
    db.from('items').select('id, name, purchase_price, price_is_estimated, lifecycle_state').eq('purchase_group_id', id),
    db.from('purchase_attachments').select('attachment_id, attachments(id, file_type, original_filename, processing_state, page_count)').eq('purchase_group_id', id),
  ]);
  return { ...group, lines: check(lines), items: check(items), attachments: check(attachments) };
}

export async function trackLine(db: Db, lineId: string, body: z.infer<typeof TrackLineBody>) {
  const itemId = check(await db.rpc('track_receipt_line', { p_line_id: lineId, p_item: body })) as string;
  return Items(db).get(itemId);
}
