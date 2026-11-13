/**
 * Live end-to-end test from several perspectives against the configured Supabase
 * project. Needs a RUNNING WORKER (npm run worker). Use a dev/staging project.
 *   npm run e2e:live
 * Perspectives: public visitor, billing webhooks, paying user, household member,
 * attacker, admin (with and without MFA), worker jobs (export, deletion).
 * Everything it creates is removed at the end.
 */
import 'dotenv/config';
import { randomBytes } from 'node:crypto';
import request from 'supertest';
import { createClient } from '@supabase/supabase-js';
import { createApp } from '../src/app.js';
import { env, setEnvForTests } from '../src/config/env.js';
import { normalizeEmail, pepperedHash } from '../src/lib/crypto.js';

const svc = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false } });
const anon = createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_ANON_KEY!, { auth: { persistSession: false } });
const app = createApp();
const results: boolean[] = [];
let section = '';
const check = (ok: boolean, name: string, detail?: unknown) => {
  results.push(ok);
  console.log(`${ok ? 'PASS' : 'FAIL'}  [${section}] ${name}${!ok && detail !== undefined ? `  — ${JSON.stringify(detail).slice(0, 400)}` : ''}`);
};
const key = () => `e2e-${randomBytes(8).toString('hex')}`;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function until<T>(fn: () => Promise<T>, ok: (v: T) => boolean, tries = 40, ms = 2000): Promise<T> {
  let v = await fn();
  for (let i = 0; i < tries && !ok(v); i++) { await sleep(ms); v = await fn(); }
  return v;
}
const PNG = Buffer.from('89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d4944415478da63f8ffff3f0005fe02fea7d6a7e90000000049454e44ae426082', 'hex');

const created = { users: [] as string[], emails: [] as string[], experimentIds: [] as string[] };
async function makeUser(tag: string) {
  const email = `e2e-${tag}-${randomBytes(4).toString('hex')}@example.com`;
  const password = `E2e-${randomBytes(12).toString('hex')}`;
  const u = await svc.auth.admin.createUser({ email, password, email_confirm: true });
  if (u.error) throw new Error(u.error.message);
  created.users.push(u.data.user!.id);
  created.emails.push(email);
  const s = await request(app).post('/v1/auth/sign-in').send({ email, password });
  return { id: u.data.user!.id, email, token: s.body.data.session.access_token as string };
}
const as = (token: string) => ({
  get: (p: string) => request(app).get(p).set('Authorization', `Bearer ${token}`),
  post: (p: string, body?: object, idem = false) => {
    const r = request(app).post(p).set('Authorization', `Bearer ${token}`);
    return (idem ? r.set('Idempotency-Key', key()) : r).send(body ?? {});
  },
  patch: (p: string, body: object) => request(app).patch(p).set('Authorization', `Bearer ${token}`).send(body),
  put: (p: string, body: object) => request(app).put(p).set('Authorization', `Bearer ${token}`).send(body),
  del: (p: string) => request(app).delete(p).set('Authorization', `Bearer ${token}`),
});
const rcEvent = (userId: string, type: string, extra: Record<string, unknown> = {}) => ({
  api_version: '1.0',
  event: {
    id: `evt_${randomBytes(8).toString('hex')}`, type, app_user_id: userId, original_app_user_id: userId, aliases: [userId],
    environment: 'PRODUCTION', product_id: 'pro_annual', entitlement_ids: ['pro'], period_type: 'NORMAL', store: 'APP_STORE',
    purchased_at_ms: Date.now() - 1000, expiration_at_ms: Date.now() + 365 * 86_400_000, event_timestamp_ms: Date.now(),
    price: 169.99, takehome_percentage: 0.85, commission_percentage: 0.15, transaction_id: `txn_${randomBytes(6).toString('hex')}`,
    country_code: 'US', ...extra,
  },
});
const webhook = (body: object, auth = env().REVENUECAT_WEBHOOK_AUTH) =>
  request(app).post('/v1/webhooks/revenuecat').set('Authorization', `Bearer ${auth}`).send(body);
const planOf = async (token: string) => (await as(token).get('/v1/me/entitlement')).body.data?.plan_code as string;

try {
  const U = await makeUser('owner');   // will become Pro via webhook, admin later
  const V = await makeUser('member');  // free user, household member, then deleted
  const UA = as(U.token);
  const VA = as(V.token);

  // ------------------------------------------------------------------ public
  section = 'public';
  check((await request(app).get('/v1/public/plans')).status === 200, 'plan limits are public');
  check((await request(app).get('/v1/public/retention-schedule')).body.data?.length >= 10, 'retention schedule is published');
  const spec = await request(app).get('/v1/openapi.json');
  check(spec.status === 200 && Object.keys(spec.body.paths ?? {}).length > 100, 'OpenAPI spec is served');
  const webDel = await request(app).post('/v1/public/account-deletion').send({ email: `nobody-${randomBytes(3).toString('hex')}@example.com` });
  check(webDel.status === 202 && /If an account exists/.test(webDel.body.data.message), 'web deletion route answers the same whether or not the account exists');
  const pub = await request(app).post('/v1/public/support').send({ contact_email: U.email, subject: 'e2e test', category: 'general', message: 'hello' });
  check(pub.status === 201, 'public support form opens a ticket');

  // ------------------------------------------------------------------ billing webhooks
  section = 'billing';
  check((await webhook(rcEvent(U.id, 'INITIAL_PURCHASE'), 'wrong-secret')).status === 401, 'webhook with wrong secret is rejected');
  const purchase = rcEvent(U.id, 'INITIAL_PURCHASE');
  const w1 = await webhook(purchase);
  const w2 = await webhook(purchase);
  check(w1.status === 200 && w1.body.recorded && w2.body.duplicate, 'event is recorded once; replay is a no-op');
  check(await until(() => planOf(U.token), (p) => p === 'pro') === 'pro', 'worker grants Pro from the purchase event');
  await webhook(rcEvent(V.id, 'INITIAL_PURCHASE', { environment: 'SANDBOX' }));
  await sleep(6000);
  check(await planOf(V.token) === 'free', 'a SANDBOX purchase never grants production access');
  await webhook(rcEvent(U.id, 'CANCELLATION', { cancel_reason: 'UNSUBSCRIBE', event_timestamp_ms: Date.now() + 1000 }));
  const ent = await until(() => UA.get('/v1/me/entitlement'), (r) => r.body.data?.entitlement?.renewal_intent === 'will_not_renew');
  check(ent.body.data.plan_code === 'pro' && ent.body.data.entitlement.renewal_intent === 'will_not_renew',
    'cancellation stops renewal but keeps paid access until expiry', ent.body.data);
  const acq = await svc.from('customer_acquisitions').select('cohort_month, channel').eq('user_id', U.id).maybeSingle();
  const rev = await svc.from('revenue_transactions').select('kind, gross_usd').eq('user_id', U.id);
  check(Boolean(acq.data) && (rev.data ?? []).some((r) => r.kind === 'purchase'), 'revenue and cohort membership recorded for profitability');

  // ------------------------------------------------------------------ paying user
  section = 'user';
  const item = await UA.post('/v1/items', { name: 'E2E Washer', brand: 'Bosch', purchase_date: new Date().toISOString().slice(0, 10),
    purchase_price: '899.00', warranties: [{ coverage_type: 'manufacturer', term_kind: 'duration', duration_months: 24, accept_estimate: true }] }, true);
  const itemId = item.body.data.item_ids[0] as string;
  check(item.status === 201, 'Pro user adds an item with an accepted estimated warranty');
  const begin = await UA.post('/v1/attachments', { file_type: 'claim_evidence', filename: 'photo.png', mime_type: 'image/png', byte_size: PNG.length }, true);
  await anon.storage.from('warranty-files').uploadToSignedUrl(begin.body.data.upload.path, begin.body.data.upload.token, PNG, { contentType: 'image/png' });
  const attId = begin.body.data.attachment.id as string;
  await UA.post(`/v1/attachments/${attId}/complete`);
  const claim = await UA.post('/v1/claims', { item_id: itemId, claim_kind: 'warranty_repair', issue_description: 'Drum does not spin', attachment_ids: [attId] });
  const facts = await UA.get(`/v1/claims/${claim.body.data.id}/facts`);
  await UA.put(`/v1/claims/${claim.body.data.id}/snapshot`, { facts: facts.body.data.proposed });
  const pack = await UA.post(`/v1/claims/${claim.body.data.id}/packs`, { format: 'pdf' });
  const pdf = pack.body.data?.url ? Buffer.from(await (await fetch(pack.body.data.url)).arrayBuffer()) : Buffer.alloc(0);
  check(pack.status === 201 && pack.body.data.pack_level === 'assembled' && pdf.subarray(0, 4).toString() === '%PDF',
    'Pro claim pack is an assembled PDF with the evidence', { status: pack.status, level: pack.body.data?.pack_level });
  const outcome = await UA.post('/v1/outcomes', { claim_id: claim.body.data.id, outcome_type: 'refund_received', amount: '120.00', currency: 'USD' });
  const summary = await UA.get('/v1/outcomes/summary');
  check(outcome.status === 201 && summary.body.data.refunds_reported.USD === 120, 'outcome recorded; summary reports refunds, not "money saved"');
  const dupOutcome = await UA.post('/v1/outcomes', { claim_id: claim.body.data.id, outcome_type: 'repair_completed' });
  check(dupOutcome.status === 409, 'the same case cannot be counted twice');
  const tomorrow = new Date(Date.now() + 2 * 86_400_000).toISOString().slice(0, 10);
  const rem = await UA.post('/v1/reminders', { title: 'Clean lint filter', date: tomorrow, item_id: itemId });
  const remList = await UA.get('/v1/reminders');
  check(rem.status === 201 && remList.body.data.some((r: { id: string }) => r.id === rem.body.data.id), 'custom reminder scheduled');
  check((await UA.post(`/v1/reminders/${rem.body.data.id}/cancel`)).status === 200, 'custom reminder cancelled');
  const offer = await UA.get('/v1/me/offer');
  check(offer.status === 200, 'paywall offer endpoint responds');

  // ------------------------------------------------------------------ household
  section = 'household';
  const vWs = await VA.post('/v1/workspaces', { kind: 'household', name: 'Not allowed' });
  check(vWs.status === 402, 'free users cannot create a household (plan required)', vWs.body);
  const ws = await UA.post('/v1/workspaces', { kind: 'household', name: 'E2E Home' });
  const wsId = ws.body.data.id as string;
  await svc.from('workspace_members').insert({ workspace_id: wsId, user_id: V.id, role: 'viewer', invited_by: U.id });
  await UA.post(`/v1/workspaces/${wsId}/items`, { item_id: itemId });
  check((await VA.get(`/v1/items/${itemId}`)).status === 200, 'member can read a shared item');
  check((await VA.patch(`/v1/items/${itemId}`, { name: 'changed' })).status === 404, 'member cannot edit the owner\'s item');
  const docUrl = await VA.get(`/v1/attachments/${attId}/url`);
  check(docUrl.status === 404, 'member cannot download documents that were not linked to the shared item');
  await UA.patch(`/v1/workspaces/${wsId}/members/${V.id}`, { state: 'revoked' });
  check((await VA.get(`/v1/items/${itemId}`)).status === 404, 'revoked member loses access immediately');

  // ------------------------------------------------------------------ attacker
  section = 'attacker';
  check((await request(app).get('/v1/me').set('Authorization', `Bearer ${U.token.slice(0, -2)}xx`)).status === 401, 'tampered token is rejected');
  check((await VA.get('/v1/admin/health')).status === 403, 'non-admin cannot reach admin routes');
  check((await VA.post('/v1/workspaces/invitations/accept', { token: 'x'.repeat(40) })).status === 404, 'bogus invitation token is refused');
  check((await VA.get(`/v1/claims/${claim.body.data.id}`)).status === 404, 'another user\'s claim is invisible');
  check((await VA.post(`/v1/attachments/${attId}/links`, { target: 'item', target_id: itemId })).status === 404, 'cannot link another user\'s document');
  const inbound = await request(app).post('/v1/webhooks/inbound-email').send({ MessageID: 'x' });
  check(inbound.status === 401, 'inbound email webhook requires its secret');
  const selfPro = await createClient(process.env.SUPABASE_URL!, process.env.SUPABASE_ANON_KEY!, { auth: { persistSession: false }, global: { headers: { Authorization: `Bearer ${V.token}` } } })
    .rpc('worker_settle_usage', { p_reservation_id: '00000000-0000-0000-0000-000000000000' });
  check(Boolean(selfPro.error), 'clients cannot call worker-only database functions');

  // ------------------------------------------------------------------ admin
  section = 'admin';
  await svc.from('admin_users').insert({ user_id: U.id, role: 'superadmin', mfa_required: true });
  const noMfa = await UA.get('/v1/admin/health');
  check(noMfa.status === 403 && noMfa.body.error.code === 'admin_mfa_required', 'admins must complete MFA', noMfa.body);
  setEnvForTests({ ADMIN_REQUIRE_MFA: false }); // simulate an MFA (aal2) session for the rest of this section
  check((await UA.get('/v1/admin/health')).status === 200, 'admin health dashboard');
  const gates = await UA.get('/v1/admin/launch-gates');
  check(gates.status === 200 && Array.isArray(gates.body.data.gates), 'launch gates report', gates.body);
  check((await UA.get('/v1/admin/profitability/forecast')).status === 200, 'first-year cohort forecast');
  check((await UA.get(`/v1/admin/users/${V.id}`)).status === 200, 'user lookup (metadata only)');
  const exp = await UA.post('/v1/admin/price-experiments', { key: `e2e-${randomBytes(3).toString('hex')}`, variants: [
    { code: 'A', label: 'A', annual_price_usd: 169.99, monthly_price_usd: 19.99, revenuecat_offering: 'a', weight: 1 },
    { code: 'B', label: 'B', annual_price_usd: 199.99, monthly_price_usd: 19.99, revenuecat_offering: 'b', weight: 1 }] });
  created.experimentIds.push(exp.body.data?.id);
  const prevRunning = (await svc.from('price_experiments').select('id').eq('status', 'running')).data ?? [];
  for (const r of prevRunning) await svc.from('price_experiments').update({ status: 'stopped' }).eq('id', r.id);
  const start = await UA.post(`/v1/admin/price-experiments/${exp.body.data.id}/status`, { status: 'running' });
  const vOffer1 = await VA.get('/v1/me/offer');
  const vOffer2 = await VA.get('/v1/me/offer');
  check(start.status === 200 && ['A', 'B'].includes(vOffer1.body.data.variant?.code) && vOffer1.body.data.variant.code === vOffer2.body.data.variant.code,
    'running price experiment assigns a sticky variant', vOffer1.body);
  const edit = await UA.post('/v1/admin/price-experiments', { id: exp.body.data.id, key: exp.body.data.key, variants: [
    { code: 'A', label: 'A', annual_price_usd: 9.99, monthly_price_usd: 1.99, revenuecat_offering: 'a', weight: 1 }] });
  check(edit.status === 403, 'a running experiment cannot be edited (keeps the comparison honest)');
  const report = await UA.get(`/v1/admin/price-experiments/${exp.body.data.id}/report`);
  check(report.status === 200 && report.body.data.by_variant.length >= 1, 'per-variant experiment report');
  await UA.post(`/v1/admin/price-experiments/${exp.body.data.id}/status`, { status: 'stopped' });
  for (const r of prevRunning) await svc.from('price_experiments').update({ status: 'running' }).eq('id', r.id);
  const susp = await UA.post(`/v1/admin/users/${V.id}/ai-suspension`, { action: 'suspend', days: 1, reason: 'e2e test' });
  const lift = await UA.post(`/v1/admin/users/${V.id}/ai-suspension`, { action: 'lift', reason: 'e2e test' });
  check(susp.status === 200 && lift.status === 200 && lift.body.data.ai_suspended_until === null, 'admin can suspend and lift AI access');
  const auditRows = await svc.from('audit_events').select('action').eq('actor_id', U.id).like('action', 'admin.%');
  check((auditRows.data ?? []).length >= 5, 'every admin action is audited', auditRows.data?.length);
  setEnvForTests({ ADMIN_REQUIRE_MFA: true });

  // ------------------------------------------------------------------ worker jobs: export
  section = 'export';
  const exportReq = await UA.post('/v1/me/exports', {});
  const ready = await until(() => UA.get(`/v1/me/exports/${exportReq.body.data.id}`), (r) => r.body.data?.state === 'ready', 45);
  const data = ready.body.data?.data_url ? await (await fetch(ready.body.data.data_url)).json() as { data: { items: Array<{ name: string }> } } : null;
  check(ready.body.data?.state === 'ready' && Boolean(data?.data.items.some((i) => i.name === 'E2E Washer')), 'worker builds the export; it contains the user\'s items', ready.body.data);
  const manifest = ready.body.data?.files_manifest_url ? await (await fetch(ready.body.data.files_manifest_url)).json() as { files: Array<{ url: string }> } : null;
  check(Boolean(manifest?.files.length && manifest.files[0]!.url), 'export manifest has expiring links to original files');
  check((await VA.get(`/v1/me/exports/${exportReq.body.data.id}`)).status === 404, 'another user cannot read this export');

  // ------------------------------------------------------------------ worker jobs: account deletion
  section = 'deletion';
  const del = await VA.post('/v1/me/deletion', {});
  check(del.status === 202 && /does not cancel/.test(del.body.data.store_notice), 'deletion request explains store subscriptions are separate');
  check((await VA.post('/v1/items', { name: 'blocked' }, true)).status === 403, 'new data is blocked while deletion is pending');
  check((await VA.post('/v1/me/deletion/confirm', { confirm: 'nope' })).status === 400, 'confirmation phrase is required');
  await VA.post('/v1/me/deletion/confirm', { confirm: 'DELETE MY ACCOUNT' });
  const done = await until(async () => (await svc.from('deletion_requests').select('state, last_error').eq('user_id', V.id)
    .order('created_at', { ascending: false }).limit(1).single()).data, (r) => r?.state === 'completed', 45);
  const authUser = (await svc.auth.admin.getUserById(V.id)).data?.user ?? null;
  const tomb = await svc.from('deletion_tombstones').select('user_id').eq('user_id', V.id).maybeSingle();
  const profile = await svc.from('profiles').select('id').eq('id', V.id).maybeSingle();
  check(done?.state === 'completed' && !authUser && !profile.data && Boolean(tomb.data),
    'worker deletes login + personal data and records a tombstone for restores', done);
  if (done?.state === 'completed') created.users = created.users.filter((x) => x !== V.id);
  const after = await VA.get('/v1/me');
  check(after.status === 401 || after.status === 404, 'the deleted user\'s session no longer works', after.status);
} catch (err) {
  check(false, 'run aborted', (err as Error).stack?.split('\n').slice(0, 3).join(' | '));
} finally {
  setEnvForTests({ ADMIN_REQUIRE_MFA: true });
  for (const id of created.experimentIds.filter(Boolean)) await svc.from('price_experiments').delete().eq('id', id);
  for (const id of created.users) {
    await svc.from('admin_users').delete().eq('user_id', id);
    for (const bucket of ['warranty-files', 'claim-packs', 'exports']) {
      const { data: top } = await svc.storage.from(bucket).list(id, { limit: 1000 });
      for (const folder of top ?? []) {
        const { data: inner } = await svc.storage.from(bucket).list(`${id}/${folder.name}`, { limit: 1000 });
        const paths = (inner ?? []).map((f) => `${id}/${folder.name}/${f.name}`);
        if (paths.length) await svc.storage.from(bucket).remove(paths);
      }
    }
    await svc.from('jobs').delete().eq('user_id', id);
    await svc.from('customer_acquisitions').delete().eq('user_id', id);
    await svc.from('revenue_transactions').delete().eq('user_id', id);
    await svc.auth.admin.deleteUser(id);
  }
  for (const email of created.emails) {
    await svc.from('support_tickets').delete().eq('contact_email', email);
    await svc.from('web_deletion_requests').delete().eq('email_hash', pepperedHash(normalizeEmail(email)));
  }
  console.log(`\ncleaned up ${created.users.length} remaining test user(s).`);
  const failed = results.filter((r) => !r).length;
  console.log(failed ? `${failed} check(s) FAILED` : `All ${results.length} checks passed.`);
  process.exit(failed ? 1 : 0);
}
