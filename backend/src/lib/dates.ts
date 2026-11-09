/**
 * Calendar-date helpers operating on ISO `YYYY-MM-DD` strings (no time component,
 * no implicit timezone). Deadlines are dates, not legal midnight cutoffs.
 */
const ISO_DATE = /^(\d{4})-(\d{2})-(\d{2})$/;

export function isValidIsoDate(s: string): boolean {
  const m = ISO_DATE.exec(s);
  if (!m) return false;
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const dt = new Date(Date.UTC(y, mo - 1, d));
  return dt.getUTCFullYear() === y && dt.getUTCMonth() === mo - 1 && dt.getUTCDate() === d;
}

const parse = (s: string): Date => {
  if (!isValidIsoDate(s)) throw new Error(`invalid_date:${s}`);
  const [y, m, d] = s.split('-').map(Number) as [number, number, number];
  return new Date(Date.UTC(y, m - 1, d));
};
const fmt = (d: Date): string => d.toISOString().slice(0, 10);

export function addDays(date: string, days: number): string {
  const d = parse(date);
  d.setUTCDate(d.getUTCDate() + days);
  return fmt(d);
}

/** Add calendar months with month-end clamping (Jan 31 + 1 month = Feb 28/29), matching PostgreSQL. */
export function addMonths(date: string, months: number): string {
  const d = parse(date);
  const targetMonth = d.getUTCMonth() + months;
  const y = d.getUTCFullYear() + Math.floor(targetMonth / 12);
  const m = ((targetMonth % 12) + 12) % 12;
  const lastDay = new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
  return fmt(new Date(Date.UTC(y, m, Math.min(d.getUTCDate(), lastDay))));
}

export function daysBetween(from: string, to: string): number {
  return Math.round((parse(to).getTime() - parse(from).getTime()) / 86_400_000);
}

/** End of a duration-based coverage: the day before the anniversary (same as the DB trigger). */
export function durationEndDate(start: string, months: number): string {
  return addDays(addMonths(start, months), -1);
}

/** Today's calendar date in an IANA timezone. */
export function todayIn(timeZone: string, now = new Date()): string {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(now);
  const get = (t: string) => parts.find((p) => p.type === t)!.value;
  return `${get('year')}-${get('month')}-${get('day')}`;
}

export function isValidTimeZone(tz: string): boolean {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

/**
 * Parse an extracted date candidate. Accepts ISO only; ambiguous locale formats
 * (e.g. 03/04/2026) are returned as null with `ambiguous: true` rather than guessed.
 */
export function parseCandidateDate(raw: string | null | undefined, locale: 'US' | 'CA' | 'GB'): { value: string | null; ambiguous: boolean } {
  if (!raw) return { value: null, ambiguous: false };
  const s = raw.trim();
  if (isValidIsoDate(s)) return { value: s, ambiguous: false };
  const m = /^(\d{1,2})[/.-](\d{1,2})[/.-](\d{2,4})$/.exec(s);
  if (!m) return { value: null, ambiguous: false };
  const a = Number(m[1]);
  const b = Number(m[2]);
  let y = Number(m[3]);
  if (y < 100) y += 2000;
  const build = (mo: number, d: number) => {
    const iso = `${y}-${String(mo).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
    return isValidIsoDate(iso) ? iso : null;
  };
  const us = build(a, b);
  const intl = build(b, a);
  if (us && intl && us !== intl) {
    // Both readings valid: use locale convention only for US; CA uses mixed conventions.
    if (locale === 'US') return { value: us, ambiguous: true };
    if (locale === 'GB') return { value: intl, ambiguous: true };
    return { value: null, ambiguous: true };
  }
  return { value: us ?? intl, ambiguous: false };
}
