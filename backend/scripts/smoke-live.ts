/**
 * Live smoke test against the Supabase project in .env (use a dev/staging project).
 *   npm run smoke:live
 * Creates two temporary confirmed users, exercises the main API flows through the
 * real Supabase stack (Auth JWTs, PostgREST + RLS, RPCs, Storage), checks that
 * user B cannot reach user A's data, then deletes both users and their files.
 */
import 'dotenv/config';
import { randomBytes } from 'node:crypto';
import request from 'supertest';
import { createClient } from '@supabase/supabase-js';
import { createApp } from '../src/app.js';

const url = process.env.SUPABASE_URL!;
const svc = createClient(url, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false } });
const app = createApp();
const results: Array<[boolean, string, string?]> = [];
const check = (ok: boolean, name: string, detail?: string) => {
  results.push([ok, name, detail]);
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail && !ok ? `  — ${detail}` : ''}`);
};
const PNG = Buffer.from('89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d4944415478da63f8ffff3f0005fe02fea7d6a7e90000000049454e44ae426082', 'hex');

async function makeUser(tag: string) {
  const email = `smoke-${tag}-${randomBytes(4).toString('hex')}@example.com`;
  const password = `Sm0ke-${randomBytes(12).toString('hex')}`;
  const { data, error } = await svc.auth.admin.createUser({ email, password, email_confirm: true });
  if (error) throw new Error(`createUser: ${error.message}`);
  const signIn = await request(app).post('/v1/auth/sign-in').send({ email, password });
  if (signIn.status !== 200) throw new Error(`sign-in ${signIn.status}: ${JSON.stringify(signIn.body)}`);
  return { id: data.user!.id, token: signIn.body.data.session.access_token as string };
}

const users: string[] = [];
try {
  const a = await makeUser('a');
  users.push(a.id);
  const b = await makeUser('b');
  users.push(b.id);
  check(true, 'two users created; profile trigger + identity guard allowed sign-up');
  const A = (r: request.Test) => r.set('Authorization', `Bearer ${a.token}`);
  const B = (r: request.Test) => r.set('Authorization', `Bearer ${b.token}`);

  const me = await A(request(app).get('/v1/me'));
  check(me.status === 200 && me.body.data.entitlement.plan_code === 'free', 'GET /me → free plan from server', JSON.stringify(me.body).slice(0, 200));

  const empty = await A(request(app).get('/v1/action-center'));
  check(empty.status === 200 && empty.body.data.empty === true, 'Action Center empty state for a new user');

  const end = new Date(Date.now() + 20 * 86_400_000).toISOString().slice(0, 10);
  const quick = await A(request(app).post('/v1/items').set('Idempotency-Key', `smoke-${randomBytes(6).toString('hex')}`).send({
    name: 'Smoke Test Kettle', brand: 'Breville', purchase_date: new Date().toISOString().slice(0, 10), purchase_price: '89.99',
    warranties: [{ coverage_type: 'manufacturer', term_kind: 'fixed_date', end_date: end, confirm: true }],
    return_window: { terms_state: 'known', policy_anchor: 'purchase_date', window_days: 15, deadline_basis: 'request_by', confirm: true },
  }));
  check(quick.status === 201 && quick.body.data.item_ids.length === 1, 'POST /items quick add (transactional RPC)', JSON.stringify(quick.body).slice(0, 300));
  const itemId = quick.body.data.item_ids?.[0] as string;

  const replayKey = `smoke-${randomBytes(6).toString('hex')}`;
  const body = { retailer: 'Home Depot', currency: 'USD', subtotal: '300.00', tax: '24.00', total_paid: '324.00',
    lines: [{ original_description: 'Drill', line_amount: '200.00', track: { name: 'Smoke Drill' } }, { original_description: 'Bits', line_amount: '100.00' }] };
  const p1 = await A(request(app).post('/v1/purchases').set('Idempotency-Key', replayKey).send(body));
  const p2 = await A(request(app).post('/v1/purchases').set('Idempotency-Key', replayKey).send(body));
  check(p1.status === 201 && p2.status === 200 && p1.body.data.purchase_group_id === p2.body.data.purchase_group_id,
    'POST /purchases multi-line receipt; replay with same key is a no-op');

  const detail = await A(request(app).get(`/v1/items/${itemId}`));
  check(detail.status === 200 && detail.body.data.coverage.warranties[0]?.labels?.alerts_enabled === true, 'item detail with labelled coverage');

  const rem = await A(request(app).get('/v1/reminders'));
  check(rem.status === 200 && rem.body.data.length >= 3, 'reminders scheduled server-side by triggers', `count=${rem.body.data?.length}`);

  const ac = await A(request(app).get('/v1/action-center'));
  check(ac.status === 200 && ac.body.data.actions.some((x: { kind: string }) => x.kind === 'return_deadline'), 'Action Center lists the return deadline');

  // Vault: reserve -> signed upload -> server verification -> signed download.
  const begin = await A(request(app).post('/v1/attachments').set('Idempotency-Key', `smoke-${randomBytes(6).toString('hex')}`)
    .send({ file_type: 'receipt', filename: 'receipt.png', mime_type: 'image/png', byte_size: PNG.length }));
  check(begin.status === 201 && Boolean(begin.body.data.upload?.token), 'POST /attachments reserves bytes + signed upload URL', JSON.stringify(begin.body).slice(0, 200));
  const attId = begin.body.data.attachment?.id as string;
  const up = await createClient(url, process.env.SUPABASE_ANON_KEY!, { auth: { persistSession: false } })
    .storage.from('warranty-files').uploadToSignedUrl(begin.body.data.upload.path, begin.body.data.upload.token, PNG, { contentType: 'image/png' });
  check(!up.error, 'client upload with signed token', up.error?.message);
  const done = await A(request(app).post(`/v1/attachments/${attId}/complete`));
  check(done.status === 200 && done.body.data.attachment.processing_state === 'ready', 'server verifies object → ready', JSON.stringify(done.body).slice(0, 200));
  const link = await A(request(app).post(`/v1/attachments/${attId}/links`).send({ target: 'item', target_id: itemId, role: 'receipt' }));
  check(link.status === 201, 'link document to item');
  const dl = await A(request(app).get(`/v1/attachments/${attId}/url`));
  check(dl.status === 200 && typeof dl.body.data.url === 'string', 'short-lived signed download URL');

  // Cross-account isolation through the real stack.
  const bItem = await B(request(app).get(`/v1/items/${itemId}`));
  check(bItem.status === 404, 'B cannot read A item');
  const bList = await B(request(app).get('/v1/items'));
  check(bList.status === 200 && bList.body.data.length === 0, 'B item list is empty');
  const bPatch = await B(request(app).patch(`/v1/items/${itemId}`).send({ name: 'pwned' }));
  check(bPatch.status === 404, 'B cannot update A item');
  const bUrl = await B(request(app).get(`/v1/attachments/${attId}/url`));
  check(bUrl.status === 404, 'B cannot get a download link for A document');
  const bComplete = await B(request(app).post(`/v1/attachments/${attId}/complete`));
  check(bComplete.status === 404, 'B cannot drive A upload via privileged endpoint');
  const bDirect = await createClient(url, process.env.SUPABASE_ANON_KEY!, { auth: { persistSession: false }, global: { headers: { Authorization: `Bearer ${b.token}` } } })
    .from('entitlements').insert({ user_id: b.id, entitlement_key: 'pro', environment: 'PRODUCTION', state: 'active' });
  check(Boolean(bDirect.error), 'B cannot self-grant Pro via direct PostgREST', bDirect.error?.message);

  // Claims.
  const claim = await A(request(app).post('/v1/claims').send({ item_id: itemId, claim_kind: 'warranty_repair', issue_description: 'Does not heat' }));
  check(claim.status === 201, 'create claim draft');
  const claimId = claim.body.data?.id as string;
  const facts = await A(request(app).get(`/v1/claims/${claimId}/facts`));
  await A(request(app).put(`/v1/claims/${claimId}/snapshot`).send({ facts: facts.body.data.proposed }));
  const pack = await A(request(app).post(`/v1/claims/${claimId}/packs`).send({ format: 'text' }));
  check(pack.status === 201 && /Smoke Test Kettle/.test(pack.body.data.text), 'claim pack from reviewed facts', JSON.stringify(pack.body).slice(0, 200));

  const exp = await A(request(app).post('/v1/me/exports').send({}));
  check(exp.status === 202, 'export request queued (needs the worker to build)');
} catch (err) {
  check(false, 'smoke run aborted', (err as Error).message);
} finally {
  for (const id of users) {
    for (const bucket of ['warranty-files', 'claim-packs', 'exports']) {
      const { data: top } = await svc.storage.from(bucket).list(id, { limit: 1000 });
      for (const folder of top ?? []) {
        const { data: inner } = await svc.storage.from(bucket).list(`${id}/${folder.name}`, { limit: 1000 });
        const paths = (inner ?? []).map((f) => `${id}/${folder.name}/${f.name}`);
        if (paths.length) await svc.storage.from(bucket).remove(paths);
      }
    }
    await svc.from('jobs').delete().eq('user_id', id);
    const { error } = await svc.auth.admin.deleteUser(id);
    if (error) console.log(`cleanup: could not delete test user ${id}: ${error.message}`);
  }
  console.log(`\ncleaned up ${users.length} test user(s).`);
  const failed = results.filter((r) => !r[0]).length;
  console.log(failed ? `${failed} check(s) FAILED` : `All ${results.length} checks passed.`);
  process.exit(failed ? 1 : 0);
}
