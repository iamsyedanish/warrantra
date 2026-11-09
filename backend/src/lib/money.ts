/**
 * Money helpers. All arithmetic is done in integer minor units (cents) — never in
 * floating point. Initial scope (USD/CAD/GBP) has two minor units.
 */
export const toCents = (amount: number | string | null | undefined): number | null => {
  if (amount === null || amount === undefined || amount === '') return null;
  const s = typeof amount === 'number' ? amount.toFixed(2) : String(amount).trim();
  if (!/^-?\d+(\.\d{1,2})?$/.test(s)) throw new Error(`invalid_money:${s}`);
  const [whole, frac = ''] = s.replace('-', '').split('.');
  const cents = Number(whole) * 100 + Number(frac.padEnd(2, '0'));
  return s.startsWith('-') ? -cents : cents;
};

export const fromCents = (cents: number | null): string | null =>
  cents === null ? null : `${cents < 0 ? '-' : ''}${Math.floor(Math.abs(cents) / 100)}.${String(Math.abs(cents) % 100).padStart(2, '0')}`;

/**
 * Split `totalCents` across `weights` proportionally using the largest-remainder
 * method, so the parts always sum exactly to the total.
 */
export function allocateProportionally(totalCents: number, weights: number[]): number[] {
  const n = weights.length;
  if (n === 0) return [];
  const sumW = weights.reduce((a, b) => a + Math.max(0, b), 0);
  if (sumW === 0) {
    // Equal split when no weights are known.
    const base = Math.floor(totalCents / n);
    const rem = totalCents - base * n;
    return weights.map((_, i) => base + (i < rem ? 1 : 0));
  }
  const exact = weights.map((w) => (Math.max(0, w) * totalCents) / sumW);
  const floors = exact.map(Math.floor);
  let remainder = totalCents - floors.reduce((a, b) => a + b, 0);
  const order = exact
    .map((v, i) => ({ i, frac: v - Math.floor(v) }))
    .sort((a, b) => b.frac - a.frac || a.i - b.i);
  for (const { i } of order) {
    if (remainder <= 0) break;
    floors[i]! += 1;
    remainder -= 1;
  }
  return floors;
}

export interface LineForAllocation {
  lineCents: number | null;
}

export interface GroupAmounts {
  subtotalCents: number | null;
  taxCents: number | null;
  shippingCents: number | null;
  discountCents: number | null;
  totalCents: number | null;
}

export interface AllocatedLine {
  taxCents: number | null;
  shippingCents: number | null;
  discountCents: number | null;
  itemValueCents: number | null;
  estimated: boolean;
}

/**
 * Allocate group-level tax/shipping/discount across ALL receipt lines (including
 * lines the user does not track) in proportion to line amounts. Allocations are
 * always labelled estimated. An item's value is its own line value — the receipt
 * total is never repeated across items.
 */
export function allocateGroup(lines: LineForAllocation[], group: GroupAmounts): AllocatedLine[] {
  const weights = lines.map((l) => l.lineCents ?? 0);
  const anyKnown = weights.some((w) => w > 0);
  const split = (total: number | null) => (total && anyKnown ? allocateProportionally(total, weights) : null);
  const tax = split(group.taxCents);
  const ship = split(group.shippingCents);
  const disc = split(group.discountCents);
  return lines.map((l, i) => {
    const t = tax ? tax[i]! : null;
    const s = ship ? ship[i]! : null;
    const d = disc ? disc[i]! : null;
    const value = l.lineCents === null ? null : l.lineCents + (t ?? 0) + (s ?? 0) - (d ?? 0);
    return {
      taxCents: t,
      shippingCents: s,
      discountCents: d,
      itemValueCents: value === null ? null : Math.max(0, value),
      estimated: Boolean(tax || ship || disc),
    };
  });
}

export interface ConsistencyWarning {
  code: string;
  message: string;
}

/** Non-blocking arithmetic checks shown to the user during review. */
export function checkGroupConsistency(lines: LineForAllocation[], group: GroupAmounts): ConsistencyWarning[] {
  const warnings: ConsistencyWarning[] = [];
  const linesSum = lines.reduce((a, l) => a + (l.lineCents ?? 0), 0);
  if (group.subtotalCents !== null && lines.every((l) => l.lineCents !== null) && linesSum !== group.subtotalCents) {
    warnings.push({ code: 'lines_do_not_match_subtotal', message: 'Line amounts do not add up to the subtotal.' });
  }
  if (group.totalCents !== null && group.subtotalCents !== null) {
    const expected = group.subtotalCents + (group.taxCents ?? 0) + (group.shippingCents ?? 0) - (group.discountCents ?? 0);
    if (Math.abs(expected - group.totalCents) > 1) {
      warnings.push({ code: 'total_mismatch', message: 'Subtotal, tax, shipping and discount do not add up to the total paid.' });
    }
  }
  return warnings;
}
