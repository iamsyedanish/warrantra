/**
 * Field validation of an extraction candidate. Produces a review draft for the
 * user — never a saved record. Anything without evidence, malformed, or
 * implausible is nulled with a warning rather than "fixed" by guessing.
 */
import { addDays, isValidIsoDate, parseCandidateDate } from '../../lib/dates.js';
import type { ProductLabelExtraction, ReceiptExtraction } from './schema.js';

export interface ReviewField<T> {
  value: T | null;
  evidence: string | null;
  status: 'extracted' | 'missing' | 'rejected';
}

export interface ReviewDraft {
  merchant: ReviewField<string>;
  purchase_date: ReviewField<string>;
  delivery_date: ReviewField<string>;
  order_number: ReviewField<string>;
  currency: ReviewField<'USD' | 'CAD' | 'GBP'>;
  subtotal: ReviewField<string>;
  tax: ReviewField<string>;
  shipping: ReviewField<string>;
  discount: ReviewField<string>;
  total_paid: ReviewField<string>;
  lines: Array<{
    line_index: number;
    description: string | null;
    quantity: number | null;
    unit_amount: string | null;
    line_amount: string | null;
    sku: string | null;
    evidence: string | null;
  }>;
  suggestions: {
    return_policy: Array<{ text: string; evidence: string; label: string }>;
    warranty: Array<{ text: string; evidence: string; label: string }>;
  };
  warnings: string[];
}

const MONEY = /^\d{1,10}(\.\d{1,2})?$/;
const clip = (s: string | null | undefined, n: number) => (s == null ? null : s.trim().slice(0, n) || null);

function textField(f: { value: string | null; evidence: string | null }, max: number, warnings: string[], name: string): ReviewField<string> {
  const value = clip(f.value, max);
  if (!value) return { value: null, evidence: null, status: 'missing' };
  if (!f.evidence) {
    warnings.push(`${name}: no supporting text found, left blank`);
    return { value: null, evidence: null, status: 'rejected' };
  }
  return { value, evidence: clip(f.evidence, 120), status: 'extracted' };
}

function moneyField(f: { value: string | null; evidence: string | null }, warnings: string[], name: string): ReviewField<string> {
  const raw = f.value?.replace(/[,\s$£]/g, '').replace(/^(USD|CAD|GBP)/i, '') ?? null;
  if (!raw) return { value: null, evidence: null, status: 'missing' };
  if (!MONEY.test(raw) || !f.evidence) {
    warnings.push(`${name}: amount could not be verified, left blank`);
    return { value: null, evidence: clip(f.evidence, 120), status: 'rejected' };
  }
  return { value: Number(raw).toFixed(2), evidence: clip(f.evidence, 120), status: 'extracted' };
}

function dateField(f: { value: string | null; evidence: string | null }, locale: 'US' | 'CA' | 'GB', today: string,
                   warnings: string[], name: string): ReviewField<string> {
  if (!f.value) {
    if (f.evidence) warnings.push(`${name}: date format is ambiguous ("${clip(f.evidence, 40)}"), please confirm`);
    return { value: null, evidence: clip(f.evidence, 120), status: 'missing' };
  }
  const parsed = isValidIsoDate(f.value) ? { value: f.value, ambiguous: false } : parseCandidateDate(f.value, locale);
  if (!parsed.value || !f.evidence) {
    warnings.push(`${name}: date could not be verified, left blank`);
    return { value: null, evidence: clip(f.evidence, 120), status: 'rejected' };
  }
  if (parsed.ambiguous) warnings.push(`${name}: date read as ${parsed.value} — please confirm the day/month order`);
  if (parsed.value > addDays(today, 1) || parsed.value < '1990-01-01') {
    warnings.push(`${name}: implausible date ${parsed.value}, left blank`);
    return { value: null, evidence: clip(f.evidence, 120), status: 'rejected' };
  }
  return { value: parsed.value, evidence: clip(f.evidence, 120), status: 'extracted' };
}

export function validateReceiptCandidate(c: ReceiptExtraction, opts: { locale: 'US' | 'CA' | 'GB'; today: string; maxLines?: number }): ReviewDraft {
  const warnings = (c.warnings ?? []).map((w) => w.slice(0, 200)).slice(0, 20);
  const currencyRaw = c.currency.value?.toUpperCase() ?? null;
  const currency: ReviewField<'USD' | 'CAD' | 'GBP'> =
    currencyRaw && ['USD', 'CAD', 'GBP'].includes(currencyRaw) && c.currency.evidence
      ? { value: currencyRaw as 'USD' | 'CAD' | 'GBP', evidence: clip(c.currency.evidence, 60), status: 'extracted' }
      : { value: null, evidence: null, status: currencyRaw ? 'rejected' : 'missing' };
  if (currencyRaw && currency.status === 'rejected') warnings.push(`currency ${currencyRaw} is not supported or not verified`);

  const maxLines = opts.maxLines ?? 50;
  if (c.lines.length > maxLines) warnings.push(`Only the first ${maxLines} lines were kept`);
  const lines = c.lines.slice(0, maxLines).map((l, i) => {
    const qty = l.quantity && /^\d+(\.\d+)?$/.test(l.quantity.trim()) ? Number(l.quantity) : null;
    const unit = l.unit_amount ? moneyField({ value: l.unit_amount, evidence: l.evidence }, warnings, `line ${i + 1} unit price`).value : null;
    const amount = l.line_amount ? moneyField({ value: l.line_amount, evidence: l.evidence }, warnings, `line ${i + 1} amount`).value : null;
    return {
      line_index: i,
      description: clip(l.description, 500),
      quantity: qty && qty > 0 && qty < 100_000 ? qty : null,
      unit_amount: unit,
      line_amount: amount,
      sku: clip(l.sku, 120),
      evidence: clip(l.evidence, 120),
    };
  });

  const label = 'Found on the receipt — not confirmed. Check the retailer or manufacturer terms.';
  return {
    merchant: textField(c.merchant, 200, warnings, 'merchant'),
    purchase_date: dateField(c.purchase_date, opts.locale, opts.today, warnings, 'purchase date'),
    delivery_date: dateField(c.delivery_date, opts.locale, opts.today, warnings, 'delivery date'),
    order_number: textField(c.order_number, 120, warnings, 'order number'),
    currency,
    subtotal: moneyField(c.subtotal, warnings, 'subtotal'),
    tax: moneyField(c.tax, warnings, 'tax'),
    shipping: moneyField(c.shipping, warnings, 'shipping'),
    discount: moneyField(c.discount, warnings, 'discount'),
    total_paid: moneyField(c.total_paid, warnings, 'total'),
    lines,
    suggestions: {
      return_policy: c.return_policy_mentions.slice(0, 5).map((m) => ({ text: m.text.slice(0, 300), evidence: m.evidence.slice(0, 160), label })),
      warranty: c.warranty_mentions.slice(0, 5).map((m) => ({ text: m.text.slice(0, 300), evidence: m.evidence.slice(0, 160), label })),
    },
    warnings,
  };
}

export interface LabelReviewDraft {
  product_name: ReviewField<string>;
  category: { value: string | null; status: 'suggested' | 'missing'; label: string };
  brand: ReviewField<string>;
  model_number: ReviewField<string>;
  serial_number: ReviewField<string>;
  manufacture_date: ReviewField<string>;
  warnings: string[];
}

/** Product/label photo: same rule — no evidence, no value. Serial/model numbers are never "corrected". */
export function validateLabelCandidate(c: ProductLabelExtraction): LabelReviewDraft {
  const warnings = (c.warnings ?? []).map((w) => w.slice(0, 200)).slice(0, 20);
  const code = (f: { value: string | null; evidence: string | null }, name: string): ReviewField<string> => {
    const v = textField(f, 120, warnings, name);
    if (v.value && !/^[A-Za-z0-9][A-Za-z0-9 ./_-]{1,119}$/.test(v.value)) {
      warnings.push(`${name}: unexpected characters, left blank`);
      return { value: null, evidence: v.evidence, status: 'rejected' };
    }
    return v;
  };
  return {
    product_name: textField(c.product_name, 200, warnings, 'product name'),
    category: c.category?.value
      ? { value: c.category.value, status: 'suggested', label: 'Suggested category — change it if it is wrong.' }
      : { value: null, status: 'missing', label: 'Choose a category.' },
    brand: textField(c.brand, 120, warnings, 'brand'),
    model_number: code(c.model_number, 'model number'),
    serial_number: code(c.serial_number, 'serial number'),
    manufacture_date: textField(c.manufacture_date, 40, warnings, 'manufacture date'),
    warnings,
  };
}
