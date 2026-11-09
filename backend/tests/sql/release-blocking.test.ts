/**
 * Release-blocking database tests (spec §11) run against embedded Postgres with
 * the Supabase shim. Each test uses two different authenticated users.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { PGlite } from '@electric-sql/pglite';
import { createDatabase, createUser, asUser, asService, expectError } from './harness.js';

let db: PGlite;
let userA: string;
let userB: string;

const purchase = (key: string, extra: Record<string, unknown> = {}) => ({
  idempotency_key: key,
  retailer: 'Best Buy',
  purchase_date: '2026-10-01',
  currency: 'USD',
  subtotal: 300,
  tax: 24,
  total_paid: 324,
  source: 'manual',
  lines: [
    { line_index: 0, original_description: 'TV', line_amount: 200, allocated_tax: 16, allocation_is_estimated: true,
      item: { name: 'Samsung TV', purchase_price: 216, price_is_estimated: true,
              warranties: [{ coverage_type: 'manufacturer', term_kind: 'unknown' }] } },
    { line_index: 1, original_description: 'Soundbar', line_amount: 100, allocated_tax: 8, allocation_is_estimated: true,
      item: { name: 'Soundbar', purchase_price: 108, price_is_estimated: true } },
  ],
  ...extra,
});

async function createAttachment(userId: string, key: string) {
  return asUser(db, userId, async (tx) => {
    const r = await tx.query<{ id: string }>(
      `select (public.begin_attachment_upload($1, 'receipt', 'receipt.pdf', 'application/pdf', 1000)).id as id`, [key]);
    return r.rows[0]!.id;
  });
}

async function completeAttachment(id: string, size = 1000) {
  await asService(db, (tx) =>
    tx.query(`select public.worker_complete_attachment_upload($1, 'application/pdf', $2, 1, $3, 'ready')`,
      [id, size, 'a'.repeat(64)]));
}

beforeAll(async () => {
  db = await createDatabase();
  userA = await createUser(db, 'a@example.com');
  userB = await createUser(db, 'b@example.com');
  // Consent to AI for both users (server-side column).
  await db.query(`update public.profiles set ai_processing_consent_at = now(), timezone = 'America/Chicago'`);
});

afterAll(async () => {
  await db?.close();
});

describe('1. cross-account isolation', () => {
  let itemA: string;
  let warrantyA: string;
  let attA: string;

  beforeAll(async () => {
    attA = await createAttachment(userA, 'att-a-0001');
    await completeAttachment(attA);
    const res = await asUser(db, userA, (tx) =>
      tx.query<{ r: any }>(`select public.create_purchase($1::jsonb) as r`, [JSON.stringify(purchase('iso-a-0001', { attachment_ids: [attA] }))]));
    itemA = res.rows[0]!.r.item_ids[0];
    const w = await asUser(db, userA, (tx) => tx.query<{ id: string }>(`select id from public.warranties where item_id = $1`, [itemA]));
    warrantyA = w.rows[0]!.id;
  });

  it('user B cannot read A items, warranties, attachments, claims or reminders', async () => {
    await asUser(db, userB, async (tx) => {
      for (const table of ['items', 'warranties', 'attachments', 'purchase_groups', 'receipt_lines', 'item_attachments',
                           'claims', 'reminders', 'usage_ledger', 'entitlements']) {
        const r = await tx.query<{ n: number }>(`select count(*)::int as n from public.${table}`);
        expect(r.rows[0]!.n, table).toBe(0);
      }
    });
  });

  it('user B cannot update or delete A rows', async () => {
    await asUser(db, userB, async (tx) => {
      const upd = await tx.query(`update public.items set name = 'pwned' where id = $1`, [itemA]);
      expect(upd.affectedRows).toBe(0);
      const del = await tx.query(`delete from public.warranties where id = $1`, [warrantyA]);
      expect(del.affectedRows).toBe(0);
    });
  });

  it('user B cannot insert child rows pointing at A parents (composite FK + RLS)', async () => {
    await asUser(db, userB, async (tx) => {
      await expectError(tx.query(`insert into public.warranties (user_id, item_id, coverage_type) values ($1, $2, 'manufacturer')`,
        [userB, itemA]), /foreign key|violates/);
      await expectError(tx.query(`insert into public.warranties (user_id, item_id, coverage_type) values ($1, $2, 'manufacturer')`,
        [userA, itemA]), /row-level security/);
    });
  });

  it('user B cannot link A attachment to own item', async () => {
    const r = await asUser(db, userB, (tx) =>
      tx.query<{ r: any }>(`select public.create_purchase($1::jsonb) as r`, [JSON.stringify(purchase('iso-b-0001'))]));
    const itemB = r.rows[0]!.r.item_ids[0];
    await asUser(db, userB, async (tx) => {
      await expectError(tx.query(`insert into public.item_attachments (item_id, attachment_id, user_id) values ($1, $2, $3)`,
        [itemB, attA, userB]), /foreign key/);
      await expectError(tx.query(`select public.create_purchase($1::jsonb)`,
        [JSON.stringify(purchase('iso-b-0002', { attachment_ids: [attA] }))]), /foreign key/);
    });
  });

  it('user B cannot attach a reminder/claim to A warranty, nor A warranty to B item', async () => {
    const itemB = (await asUser(db, userB, (tx) => tx.query<{ id: string }>(`select id from public.items limit 1`))).rows[0]!.id;
    await asUser(db, userB, async (tx) => {
      await expectError(tx.query(`insert into public.claims (user_id, item_id, warranty_id, item_label, issue_description)
                                  values ($1, $2, $3, 'x', 'broken')`, [userB, itemB, warrantyA]), /foreign key|warranty_not_on_claim_item/);
    });
    // Same-owner but different item: A's warranty must not attach to A's other item.
    const otherItemA = (await asUser(db, userA, (tx) => tx.query<{ id: string }>(
      `select id from public.items where id <> $1 limit 1`, [itemA]))).rows[0]!.id;
    await asUser(db, userA, async (tx) => {
      await expectError(tx.query(`insert into public.claims (user_id, item_id, warranty_id, item_label, issue_description)
                                  values ($1, $2, $3, 'x', 'broken')`, [userA, otherItemA, warrantyA]), /warranty_not_on_claim_item/);
    });
  });

  it('clients cannot write entitlements, billing events or plan limits (no self-granted premium)', async () => {
    await asUser(db, userB, async (tx) => {
      await expectError(tx.query(`insert into public.entitlements (user_id, entitlement_key, environment, state, valid_until)
                                  values ($1, 'pro', 'PRODUCTION', 'active', now() + interval '1 year')`, [userB]), /permission denied|row-level/);
      await expectError(tx.query(`update public.plan_limits set max_items = 100000`), /permission denied/);
      await expectError(tx.query(`insert into public.billing_events (provider_event_id, event_type, environment, payload)
                                  values ('x', 'INITIAL_PURCHASE', 'PRODUCTION', '{}')`), /permission denied/);
      await expectError(tx.query(`update public.profiles set account_state = 'active', ai_processing_consent_at = now()`), /permission denied/);
      await expectError(tx.query(`select public.worker_claim_due_reminders(10)`), /permission denied/);
      await expectError(tx.query(`select public.worker_complete_attachment_upload($1, 'application/pdf', 1, 1, null, 'ready')`, [attA]), /permission denied/);
    });
  });

  it('reference tables are read-only for clients', async () => {
    await asUser(db, userA, async (tx) => {
      const r = await tx.query<{ n: number }>(`select count(*)::int as n from public.categories`);
      expect(r.rows[0]!.n).toBeGreaterThan(10);
      await expectError(tx.query(`insert into public.categories (slug, name) values ('x', 'x')`), /permission denied/);
      await expectError(tx.query(`update public.brands set name = 'x'`), /permission denied/);
    });
  });

  it('storage policy only exposes ready originals owned by the caller', async () => {
    const path = (await db.query<{ storage_path: string }>(`select storage_path from public.attachments where id = $1`, [attA])).rows[0]!.storage_path;
    await db.query(`insert into storage.objects (bucket_id, name) values ('warranty-files', $1)`, [path]);
    // A forged object inside B's folder prefix but with no attachments row is invisible.
    await db.query(`insert into storage.objects (bucket_id, name) values ('warranty-files', $1)`, [`${userB}/forged/file.pdf`]);
    const a = await asUser(db, userA, (tx) => tx.query<{ n: number }>(`select count(*)::int n from storage.objects`));
    const b = await asUser(db, userB, (tx) => tx.query<{ n: number }>(`select count(*)::int n from storage.objects`));
    expect(a.rows[0]!.n).toBe(1);
    expect(b.rows[0]!.n).toBe(0);
  });
});

describe('2. quotas, retries and idempotency', () => {
  it('replaying create_purchase with the same key creates nothing new', async () => {
    const u = await createUser(db, 'idem@example.com');
    const run = () => asUser(db, u, (tx) =>
      tx.query<{ r: any }>(`select public.create_purchase($1::jsonb) as r`, [JSON.stringify(purchase('idem-0001'))]));
    const first = (await run()).rows[0]!.r;
    const second = (await run()).rows[0]!.r;
    expect(first.created).toBe(true);
    expect(second.created).toBe(false);
    expect(second.purchase_group_id).toBe(first.purchase_group_id);
    const n = await asUser(db, u, (tx) => tx.query<{ n: number }>(`select count(*)::int n from public.items`));
    expect(n.rows[0]!.n).toBe(2);
  });

  it('free plan item quota (10, archived count) blocks additions without deleting', async () => {
    const u = await createUser(db, 'quota@example.com');
    await asUser(db, u, async (tx) => {
      for (let i = 0; i < 10; i++) {
        await tx.query(`insert into public.items (user_id, name, archived) values ($1, $2, $3)`, [u, `Item ${i}`, i % 2 === 0]);
      }
      await expectError(tx.query(`insert into public.items (user_id, name) values ($1, 'eleventh')`, [u]), /quota_exceeded:items:10/);
      const usage = await tx.query<{ r: any }>(`select public.get_my_usage() as r`);
      expect(usage.rows[0]!.r.additions_paused).toBe(true);
    });
  });

  it('AI retries with the same key never double charge; failures release allowance', async () => {
    const u = await createUser(db, 'ai@example.com');
    await db.query(`update public.profiles set ai_processing_consent_at = now() where id = $1`, [u]);
    const reserve = (key: string) => asUser(db, u, (tx) =>
      tx.query<{ id: string; state: string }>(`select id, state from public.reserve_ai_action($1, 'scan_job', null)`, [key]));
    const r1 = (await reserve('scan-key-0001')).rows[0]!;
    const r1again = (await reserve('scan-key-0001')).rows[0]!;
    expect(r1again.id).toBe(r1.id);
    // Release (failed) then retry with the same key: re-reserved in place, still one row.
    await asService(db, (tx) => tx.query(`select public.worker_release_usage($1, 'provider_error')`, [r1.id]));
    const r1retry = (await reserve('scan-key-0001')).rows[0]!;
    expect(r1retry.id).toBe(r1.id);
    expect(r1retry.state).toBe('reserved');
    await reserve('scan-key-0002');
    await reserve('scan-key-0003');
    // Free trial = 3 lifetime actions.
    await expectError(reserve('scan-key-0004'), /quota_exceeded:ai_actions:3/);
    // A failure releases allowance so another action becomes possible.
    await asService(db, (tx) => tx.query(`select public.worker_release_usage($1, 'provider_error')`, [r1.id]));
    await reserve('scan-key-0004');
  });

  it('AI requires consent and honours the kill switch', async () => {
    const u = await createUser(db, 'noconsent@example.com');
    await expectError(asUser(db, u, (tx) => tx.query(`select public.reserve_ai_action('k-000001', 'scan_job', null)`)), /ai_consent_required/);
    await db.query(`update public.profiles set ai_processing_consent_at = now() where id = $1`, [u]);
    await db.query(`update public.system_settings set value = 'true' where key = 'ai_kill_switch'`);
    await expectError(asUser(db, u, (tx) => tx.query(`select public.reserve_ai_action('k-000001', 'scan_job', null)`)), /ai_disabled/);
    await db.query(`update public.system_settings set value = 'false' where key = 'ai_kill_switch'`);
  });

  it('storage reservations count against quota; retries reuse the pending upload', async () => {
    const u = await createUser(db, 'storage@example.com');
    const begin = (key: string, size: number) => asUser(db, u, (tx) =>
      tx.query<{ id: string }>(`select (public.begin_attachment_upload($1, 'receipt', 'r.jpg', 'image/jpeg', $2)).id as id`, [key, size]));
    const a = (await begin('up-key-0001', 9_000_000)).rows[0]!.id;
    expect((await begin('up-key-0001', 9_000_000)).rows[0]!.id).toBe(a);
    await expectError(begin('up-key-big1', 11 * 1024 * 1024), /file_too_large/);
    for (let i = 2; i <= 11; i++) await begin(`up-key-${String(i).padStart(4, '0')}`, 9_000_000);
    await expectError(begin('up-key-0012', 9_000_000), /quota_exceeded:storage_bytes/);
  });
});

describe('3. shared receipts and partial returns', () => {
  it('removing one item keeps the shared receipt for the other', async () => {
    const u = await createUser(db, 'shared@example.com');
    const att = await createAttachment(u, 'shared-att-1');
    await completeAttachment(att);
    const r = (await asUser(db, u, (tx) => tx.query<{ r: any }>(`select public.create_purchase($1::jsonb) as r`,
      [JSON.stringify(purchase('shared-0001', { attachment_ids: [att] }))]))).rows[0]!.r;
    const [tv, bar] = r.item_ids as string[];
    await asUser(db, u, async (tx) => {
      await tx.query(`delete from public.items where id = $1`, [tv]);
      const links = await tx.query<{ n: number }>(`select count(*)::int n from public.item_attachments where attachment_id = $1`, [att]);
      expect(links.rows[0]!.n).toBe(1);
      const still = await tx.query<{ n: number }>(`select count(*)::int n from public.attachments where id = $1`, [att]);
      expect(still.rows[0]!.n).toBe(1);
      const pg = await tx.query<{ n: number }>(`select count(*)::int n from public.purchase_attachments where attachment_id = $1`, [att]);
      expect(pg.rows[0]!.n).toBe(1);
      const line = await tx.query<{ item_id: string | null }>(`select item_id from public.receipt_lines where line_index = 0 and purchase_group_id = $1`, [r.purchase_group_id]);
      expect(line.rows[0]!.item_id).toBeNull();
      const impact = await tx.query<{ r: any }>(`select public.get_attachment_impact($1) as r`, [att]);
      expect(impact.rows[0]!.r.items).toHaveLength(1);
      expect(impact.rows[0]!.r.items[0].item_id).toBe(bar);
    });
  });

  it('a refunded partial return affects only its own item', async () => {
    const u = await createUser(db, 'partial@example.com');
    const r = (await asUser(db, u, (tx) => tx.query<{ r: any }>(`select public.create_purchase($1::jsonb) as r`,
      [JSON.stringify(purchase('partial-0001'))]))).rows[0]!.r;
    const [tv, bar] = r.item_ids as string[];
    await asUser(db, u, async (tx) => {
      const rw = await tx.query<{ id: string }>(
        `insert into public.return_windows (user_id, item_id, terms_state, policy_anchor, window_days, deadline_basis, date_certainty, confirmed_at)
         values ($1, $2, 'known', 'purchase_date', 15, 'request_by', 'user_confirmed', now()) returning id`, [u, tv]);
      await tx.query(`update public.return_windows set return_state = 'refunded' where id = $1`, [rw.rows[0]!.id]);
      const states = await tx.query<{ id: string; lifecycle_state: string }>(`select id, lifecycle_state from public.items`);
      const byId = Object.fromEntries(states.rows.map((x) => [x.id, x.lifecycle_state]));
      expect(byId[tv]).toBe('returned');
      expect(byId[bar]).toBe('owned');
    });
  });

  it('receipt totals are never repeated as item values', async () => {
    const u = await createUser(db, 'totals@example.com');
    await asUser(db, u, async (tx) => {
      await tx.query(`select public.create_purchase($1::jsonb)`, [JSON.stringify(purchase('totals-0001'))]);
      const sum = await tx.query<{ s: string }>(`select sum(purchase_price)::text s from public.items`);
      expect(Number(sum.rows[0]!.s)).toBe(324);
      await expectError(tx.query(`select public.create_purchase($1::jsonb)`, [JSON.stringify(purchase('totals-0002', { tax: 10 }))]),
        /allocations_exceed_group_amounts/);
    });
  });
});

describe('4. coverage correctness', () => {
  let u: string;
  let item: string;
  beforeAll(async () => {
    u = await createUser(db, 'coverage@example.com');
    item = (await asUser(db, u, (tx) => tx.query<{ id: string }>(
      `insert into public.items (user_id, name, purchase_date, delivery_date) values ($1, 'Fridge', '2024-01-31', '2024-02-05') returning id`, [u])))
      .rows[0]!.id;
  });

  it('unknown warranty dates stay unknown and create no reminders', async () => {
    await asUser(db, u, async (tx) => {
      const w = await tx.query<{ end_date: string | null; date_certainty: string }>(
        `insert into public.warranties (user_id, item_id, coverage_type, term_kind) values ($1, $2, 'manufacturer', 'unknown')
         returning end_date, date_certainty`, [u, item]);
      expect(w.rows[0]!.end_date).toBeNull();
      expect(w.rows[0]!.date_certainty).toBe('unknown');
      await expectError(tx.query(`insert into public.warranties (user_id, item_id, coverage_type, term_kind, end_date, date_certainty)
                                  values ($1, $2, 'manufacturer', 'lifetime', '2099-01-01', 'estimated')`, [u, item]), /check constraint/);
      const rem = await tx.query<{ n: number }>(`select count(*)::int n from public.reminders where item_id = $1`, [item]);
      expect(rem.rows[0]!.n).toBe(0);
    });
  });

  it('duration terms derive an estimated end date with month-end/leap-year clamping', async () => {
    await asUser(db, u, async (tx) => {
      const w = await tx.query<{ end_date: string; date_certainty: string }>(
        `insert into public.warranties (user_id, item_id, coverage_type, term_kind, duration_months)
         values ($1, $2, 'manufacturer', 'duration', 1) returning end_date::text, date_certainty`, [u, item]);
      // 2024-01-31 + 1 month = 2024-02-29 (leap year), coverage through the prior day.
      expect(w.rows[0]!.end_date).toBe('2024-02-28');
      expect(w.rows[0]!.date_certainty).toBe('estimated');
    });
  });

  it('delivery-anchored return deadlines follow delivery date changes', async () => {
    await asUser(db, u, async (tx) => {
      const r = await tx.query<{ id: string; return_deadline: string }>(
        `insert into public.return_windows (user_id, item_id, terms_state, policy_anchor, window_days, deadline_basis)
         values ($1, $2, 'known', 'delivery_date', 30, 'merchant_receipt_by') returning id, return_deadline::text`, [u, item]);
      expect(r.rows[0]!.return_deadline).toBe('2024-03-06');
      await tx.query(`update public.items set delivery_date = '2024-02-10' where id = $1`, [item]);
      const after = await tx.query<{ return_deadline: string }>(`select return_deadline::text from public.return_windows where id = $1`, [r.rows[0]!.id]);
      expect(after.rows[0]!.return_deadline).toBe('2024-03-11');
      await tx.query(`update public.items set delivery_date = null where id = $1`, [item]);
      const unknown = await tx.query<{ return_deadline: string | null; date_certainty: string }>(
        `select return_deadline, date_certainty from public.return_windows where id = $1`, [r.rows[0]!.id]);
      expect(unknown.rows[0]!.return_deadline).toBeNull();
      expect(unknown.rows[0]!.date_certainty).toBe('unknown');
    });
  });

  it('there is no default return entitlement', async () => {
    await asUser(db, u, async (tx) => {
      const r = await tx.query<{ return_deadline: string | null; window_days: number | null; terms_state: string }>(
        `insert into public.return_windows (user_id, item_id) values ($1, $2) returning return_deadline, window_days, terms_state`, [u, item]);
      expect(r.rows[0]).toEqual({ return_deadline: null, window_days: null, terms_state: 'unknown' });
    });
  });
});

describe('5. reminder versioning', () => {
  let u: string;
  let item: string;
  beforeAll(async () => {
    u = await createUser(db, 'remind@example.com');
    item = (await asUser(db, u, (tx) => tx.query<{ id: string }>(
      `insert into public.items (user_id, name, purchase_date) values ($1, 'Laptop', current_date) returning id`, [u]))).rows[0]!.id;
  });

  it('two coverages on one item can alert at the same instant', async () => {
    await asUser(db, u, async (tx) => {
      for (const t of ['manufacturer', 'protection_plan']) {
        await tx.query(`insert into public.warranties (user_id, item_id, coverage_type, term_kind, end_date, date_certainty, confirmed_at)
                        values ($1, $2, $3, 'fixed_date', current_date + 60, 'user_confirmed', now())`, [u, item, t]);
      }
      const r = await tx.query<{ n: number; distinct_due: number }>(
        `select count(*)::int n, count(distinct due_at)::int distinct_due from public.reminders
          where item_id = $1 and state = 'scheduled'`, [item]);
      expect(r.rows[0]!.n).toBe(6);          // 30/7/1 days for each coverage
      expect(r.rows[0]!.distinct_due).toBe(3); // simultaneous alerts allowed
    });
  });

  it('editing a deadline supersedes the old schedule version; re-saving unchanged is a no-op', async () => {
    await asUser(db, u, async (tx) => {
      const w = (await tx.query<{ id: string }>(`select id from public.warranties where item_id = $1 and coverage_type = 'manufacturer'`, [item])).rows[0]!.id;
      await tx.query(`update public.warranties set notes = 'unchanged dates' where id = $1`, [w]);
      let v = await tx.query<{ max: number }>(`select max(schedule_version)::int max from public.reminders where warranty_id = $1`, [w]);
      expect(v.rows[0]!.max).toBe(1);
      await tx.query(`update public.warranties set end_date = current_date + 90 where id = $1`, [w]);
      const rows = await tx.query<{ schedule_version: number; state: string }>(
        `select schedule_version, state from public.reminders where warranty_id = $1 order by schedule_version`, [w]);
      expect(rows.rows.filter((r) => r.schedule_version === 1).every((r) => r.state === 'superseded')).toBe(true);
      expect(rows.rows.filter((r) => r.schedule_version === 2 && r.state === 'scheduled')).toHaveLength(3);
      v = await tx.query<{ max: number }>(`select max(schedule_version)::int max from public.reminders where warranty_id = $1`, [w]);
      expect(v.rows[0]!.max).toBe(2);
    });
  });

  it('estimated dates only alert after explicit acceptance', async () => {
    await asUser(db, u, async (tx) => {
      const w = await tx.query<{ id: string }>(
        `insert into public.warranties (user_id, item_id, coverage_type, term_kind, duration_months)
         values ($1, $2, 'retailer', 'duration', 12) returning id`, [u, item]);
      const id = w.rows[0]!.id;
      let n = await tx.query<{ n: number }>(`select count(*)::int n from public.reminders where warranty_id = $1`, [id]);
      expect(n.rows[0]!.n).toBe(0);
      await tx.query(`update public.warranties set estimate_accepted_at = now() where id = $1`, [id]);
      n = await tx.query<{ n: number }>(`select count(*)::int n from public.reminders where warranty_id = $1 and state = 'scheduled' and is_estimate`, [id]);
      expect(n.rows[0]!.n).toBe(3);
    });
  });

  it('completing a return / registration cancels its alerts', async () => {
    await asUser(db, u, async (tx) => {
      const r = await tx.query<{ id: string }>(
        `insert into public.return_windows (user_id, item_id, terms_state, policy_anchor, window_days, deadline_basis, date_certainty, confirmed_at)
         values ($1, $2, 'known', 'purchase_date', 30, 'request_by', 'user_confirmed', now()) returning id`, [u, item]);
      const g = await tx.query<{ id: string }>(
        `insert into public.registrations (user_id, item_id, requirement_state, deadline, deadline_certainty)
         values ($1, $2, 'extra_benefit', current_date + 20, 'user_confirmed') returning id`, [u, item]);
      const live = async () => (await tx.query<{ n: number }>(
        `select count(*)::int n from public.reminders where (return_window_id = $1 or registration_id = $2) and state = 'scheduled'`,
        [r.rows[0]!.id, g.rows[0]!.id])).rows[0]!.n;
      expect(await live()).toBe(5);
      await tx.query(`update public.return_windows set return_state = 'initiated' where id = $1`, [r.rows[0]!.id]);
      await tx.query(`update public.registrations set status = 'link_opened' where id = $1`, [g.rows[0]!.id]);
      expect(await live()).toBe(2); // opening the link is not completion
      await tx.query(`update public.registrations set status = 'user_reported_complete' where id = $1`, [g.rows[0]!.id]);
      expect(await live()).toBe(0);
    });
  });

  it('timezone changes reschedule alerts at the local alert hour (DST-aware)', async () => {
    await asUser(db, u, async (tx) => {
      await tx.query(`update public.profiles set timezone = 'Europe/London', alert_local_time = '08:30' where id = $1`, [u]);
      const r = await tx.query<{ ok: boolean }>(
        `select bool_and(to_char(due_at at time zone 'Europe/London', 'HH24:MI') = '08:30') ok
           from public.reminders where user_id = $1 and state = 'scheduled' and reminder_type = 'warranty_expiry'`, [u]);
      expect(r.rows[0]!.ok).toBe(true);
    });
  });

  it('worker claims due reminders; provider acceptance is recorded separately from opening', async () => {
    const custom = await asUser(db, u, (tx) => tx.query<{ id: string }>(
      `select (public.create_custom_reminder('Check filter', 'Replace the water filter', current_date + 1)).id as id`));
    await db.query(`update public.reminders set due_at = now() - interval '1 minute' where id = $1`, [custom.rows[0]!.id]);
    const claimed = await asService(db, (tx) => tx.query<{ id: string; schedule_version: number }>(
      `select id, schedule_version from public.worker_claim_due_reminders(50)`));
    expect(claimed.rows.map((r) => r.id)).toContain(custom.rows[0]!.id);
    const again = await asService(db, (tx) => tx.query(`select id from public.worker_claim_due_reminders(50)`));
    expect(again.rows.map((r: any) => r.id)).not.toContain(custom.rows[0]!.id);
    const d = await asService(db, (tx) => tx.query<{ id: string }>(
      `insert into public.notification_deliveries (user_id, reminder_id, schedule_version, channel, destination, state, accepted_at)
       values ($1, $2, 1, 'push', 'device-1', 'provider_accepted', now()) returning id`, [u, custom.rows[0]!.id]));
    await asService(db, (tx) => tx.query(`select public.worker_finish_reminder($1, 1, 'dispatched')`, [custom.rows[0]!.id]));
    await asUser(db, u, (tx) => tx.query(`select public.mark_notification_opened($1)`, [d.rows[0]!.id]));
    const st = await db.query<{ state: string }>(`select state from public.notification_deliveries where id = $1`, [d.rows[0]!.id]);
    expect(st.rows[0]!.state).toBe('opened');
    await expectError(asService(db, (tx) => tx.query(
      `insert into public.notification_deliveries (user_id, reminder_id, schedule_version, channel, destination)
       values ($1, $2, 1, 'push', 'device-1')`, [u, custom.rows[0]!.id])), /duplicate key/);
  });
});

describe('6. entitlements', () => {
  it('cancellation keeps access until expiry; sandbox never grants production access', async () => {
    const u = await createUser(db, 'billing@example.com');
    await asService(db, (tx) => tx.query(
      `insert into public.entitlements (user_id, entitlement_key, environment, state, renewal_intent, valid_until, store)
       values ($1, 'pro', 'SANDBOX', 'active', 'will_renew', now() + interval '1 month', 'app_store')`, [u]));
    let plan = await asUser(db, u, (tx) => tx.query<{ r: any }>(`select public.get_my_entitlement() as r`));
    expect(plan.rows[0]!.r.plan_code).toBe('free');
    await asService(db, (tx) => tx.query(
      `insert into public.entitlements (user_id, entitlement_key, environment, state, renewal_intent, valid_until, store)
       values ($1, 'pro', 'PRODUCTION', 'active', 'will_not_renew', now() + interval '10 days', 'app_store')`, [u]));
    plan = await asUser(db, u, (tx) => tx.query<{ r: any }>(`select public.get_my_entitlement() as r`));
    expect(plan.rows[0]!.r.plan_code).toBe('pro');
    expect(plan.rows[0]!.r.limits.max_items).toBe(500);
    await asService(db, (tx) => tx.query(`update public.entitlements set valid_until = now() - interval '1 second' where user_id = $1 and environment = 'PRODUCTION'`, [u]));
    plan = await asUser(db, u, (tx) => tx.query<{ r: any }>(`select public.get_my_entitlement() as r`));
    expect(plan.rows[0]!.r.plan_code).toBe('free');
  });

  it('billing events are immutable and unique per provider event id', async () => {
    await asService(db, async (tx) => {
      const r = await tx.query<{ id: string }>(`insert into public.billing_events (provider_event_id, event_type, environment, payload)
                                                values ('evt-1', 'RENEWAL', 'PRODUCTION', '{"a":1}') returning id`);
      await expectError(tx.query(`insert into public.billing_events (provider_event_id, event_type, environment, payload)
                                  values ('evt-1', 'RENEWAL', 'PRODUCTION', '{}')`), /duplicate key/);
      await expectError(tx.query(`update public.billing_events set payload = '{}' where id = $1`, [r.rows[0]!.id]), /immutable/);
      await tx.query(`update public.billing_events set processing_state = 'processed' where id = $1`, [r.rows[0]!.id]);
    });
  });
});

describe('7. deletion & restore', () => {
  it('tombstone replay removes accounts resurrected by a restore', async () => {
    const u = await createUser(db, 'deleted@example.com');
    await asService(db, (tx) => tx.query(`insert into public.deletion_tombstones (user_id) values ($1)`, [u]));
    const r = await asService(db, (tx) => tx.query<{ user_id: string }>(`select user_id from public.replay_deletion_tombstones()`));
    expect(r.rows.map((x) => x.user_id)).toContain(u);
    const left = await db.query<{ n: number }>(`select count(*)::int n from auth.users where id = $1`, [u]);
    expect(left.rows[0]!.n).toBe(0);
  });

  it('a deletion-pending account cannot add items', async () => {
    const u = await createUser(db, 'pending@example.com');
    await db.query(`update public.profiles set account_state = 'deletion_pending' where id = $1`, [u]);
    await expectError(asUser(db, u, (tx) => tx.query(`insert into public.items (user_id, name) values ($1, 'x')`, [u])), /account_not_active/);
  });
});

describe('8. privacy guards', () => {
  it('payment card labels reject card numbers', async () => {
    const u = await createUser(db, 'cards@example.com');
    await asUser(db, u, async (tx) => {
      await tx.query(`insert into public.payment_cards (user_id, nickname) values ($1, 'Amex Gold — Personal')`, [u]);
      await expectError(tx.query(`insert into public.payment_cards (user_id, nickname) values ($1, '4111 1111 1111 1111')`, [u]), /check constraint/);
    });
  });

  it('analytics strips non-allow-listed properties', async () => {
    await asService(db, async (tx) => {
      await tx.query(`insert into public.analytics_events (event_name, properties, occurred_at)
                      values ('item_created', '{"source":"manual","serial_number":"ABC123","receipt_text":"secret"}', now())`);
      const r = await tx.query<{ properties: Record<string, unknown> }>(`select properties from public.analytics_events order by id desc limit 1`);
      expect(r.rows[0]!.properties).toEqual({ source: 'manual' });
    });
  });

  it('a new provider identity cannot silently merge into an existing account', async () => {
    const u = await createUser(db, 'merge@example.com');
    await expectError(db.query(`insert into auth.identities (user_id, provider) values ($1, 'google')`, [u]), /identity_link_requires_explicit_intent/);
    await asUser(db, u, (tx) => tx.query(`select public.request_identity_link('google')`));
    await db.query(`insert into auth.identities (user_id, provider) values ($1, 'google')`, [u]);
  });
});

describe('9. workspaces (household / business pilot)', () => {
  it('free owners cannot create workspaces; pro owners share read-only items and can revoke', async () => {
    const owner = await createUser(db, 'owner@example.com');
    const member = await createUser(db, 'member@example.com');
    await expectError(asUser(db, owner, (tx) => tx.query(`insert into public.workspaces (owner_id, kind, name) values ($1, 'household', 'Home')`, [owner])),
      /plan_feature_unavailable:workspaces/);
    await asService(db, (tx) => tx.query(
      `insert into public.entitlements (user_id, entitlement_key, environment, state, valid_until, store)
       values ($1, 'pro', 'PRODUCTION', 'active', now() + interval '1 year', 'app_store')`, [owner]));
    const ws = await asUser(db, owner, (tx) => tx.query<{ id: string }>(
      `insert into public.workspaces (owner_id, kind, name) values ($1, 'household', 'Home') returning id`, [owner]));
    const wsId = ws.rows[0]!.id;
    const item = await asUser(db, owner, (tx) => tx.query<{ id: string }>(
      `insert into public.items (user_id, name) values ($1, 'Washer') returning id`, [owner]));
    await asUser(db, owner, (tx) => tx.query(
      `insert into public.workspace_items (workspace_id, item_id, user_id, shared_by) values ($1, $2, $3, $3)`, [wsId, item.rows[0]!.id, owner]));
    await asService(db, (tx) => tx.query(
      `insert into public.workspace_members (workspace_id, user_id, role, invited_by) values ($1, $2, 'viewer', $3)`, [wsId, member, owner]));

    const seen = await asUser(db, member, (tx) => tx.query<{ n: number }>(`select count(*)::int n from public.items where id = $1`, [item.rows[0]!.id]));
    expect(seen.rows[0]!.n).toBe(1);
    const upd = await asUser(db, member, (tx) => tx.query(`update public.items set name = 'x' where id = $1`, [item.rows[0]!.id]));
    expect(upd.affectedRows).toBe(0);
    await expectError(asUser(db, member, (tx) => tx.query(
      `insert into public.locations (workspace_id, name) values ($1, 'Kitchen')`, [wsId])), /row-level security/);

    await asUser(db, owner, (tx) => tx.query(`update public.workspace_members set state = 'revoked' where workspace_id = $1 and user_id = $2`, [wsId, member]));
    const after = await asUser(db, member, (tx) => tx.query<{ n: number }>(`select count(*)::int n from public.items where id = $1`, [item.rows[0]!.id]));
    expect(after.rows[0]!.n).toBe(0);
    await expectError(asUser(db, owner, (tx) => tx.query(
      `update public.workspace_members set role = 'viewer' where workspace_id = $1 and user_id = $2`, [wsId, owner])), /workspace_owner_cannot_be_demoted/);
  });
});

describe('10. action center & timeline', () => {
  it('orders overdue first, then return, registration, coverage', async () => {
    const u = await createUser(db, 'action@example.com');
    await asUser(db, u, async (tx) => {
      const item = (await tx.query<{ id: string }>(`insert into public.items (user_id, name, purchase_date) values ($1, 'AirPods', current_date - 29) returning id`, [u])).rows[0]!.id;
      await tx.query(`insert into public.return_windows (user_id, item_id, terms_state, policy_anchor, window_days, deadline_basis, date_certainty, confirmed_at)
                      values ($1, $2, 'known', 'purchase_date', 30, 'request_by', 'user_confirmed', now())`, [u, item]);
      await tx.query(`insert into public.registrations (user_id, item_id, deadline, deadline_certainty) values ($1, $2, current_date + 5, 'user_confirmed')`, [u, item]);
      await tx.query(`insert into public.warranties (user_id, item_id, coverage_type, term_kind, end_date, date_certainty, confirmed_at)
                      values ($1, $2, 'manufacturer', 'fixed_date', current_date + 27, 'document_verified', now())`, [u, item]);
      const ac = await tx.query<{ kind: string; title: string }>(`select kind, title from public.get_action_center(60)`);
      expect(ac.rows.slice(0, 3).map((r) => r.kind)).toEqual(['return_deadline', 'registration_deadline', 'coverage_ending']);
      expect(ac.rows[0]!.title).toBe('Return window ends tomorrow');
      const tl = await tx.query<{ event_kind: string }>(`select event_kind from public.get_item_timeline($1)`, [item]);
      expect(tl.rows.map((r) => r.event_kind)).toContain('purchased');
    });
  });
});

describe('11. column-level write restrictions (direct PostgREST access)', () => {
  it('clients cannot write server-only columns', async () => {
    const u = await createUser(db, 'columns@example.com');
    await asUser(db, u, async (tx) => {
      const item = (await tx.query<{ id: string }>(`insert into public.items (user_id, name) values ($1, 'Kettle') returning id`, [u])).rows[0]!.id;
      await expectError(tx.query(`insert into public.claims (user_id, item_id, item_label, issue_description, ai_draft_text)
                                  values ($1, $2, 'Kettle', 'leaks', 'forged AI draft')`, [u, item]), /permission denied/);
      const c = await tx.query<{ id: string }>(`insert into public.claims (user_id, item_id, item_label, issue_description)
                                                values ($1, $2, 'Kettle', 'leaks') returning id`, [u, item]);
      await expectError(tx.query(`update public.claims set ai_draft_text = 'x' where id = $1`, [c.rows[0]!.id]), /permission denied/);
      await expectError(tx.query(`update public.attachments set processing_state = 'ready'`), /permission denied/);
      await expectError(tx.query(`insert into public.attachments (user_id, storage_path, declared_byte_size) values ($1, $2, 1)`, [u, `${u}/x`]), /permission denied/);
      await expectError(tx.query(`update public.scan_jobs set state = 'succeeded'`), /permission denied/);
      await expectError(tx.query(`insert into public.reminders (user_id, reminder_type, timezone, due_at, title, body)
                                  values ($1, 'custom', 'UTC', now(), 'x', 'y')`, [u]), /permission denied/);
    });
  });
});
