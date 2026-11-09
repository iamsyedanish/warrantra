/**
 * Durable account deletion:
 *   reauthenticate -> stop new jobs (account_state=deletion_pending) -> offer
 *   export & explain store-subscription management -> confirm -> manifest of
 *   storage objects (outside the profile cascade) -> delete objects (retry) ->
 *   delete auth user (cascades personal records) -> verify -> tombstone -> purge
 *   manifest. Account deletion does NOT cancel a store subscription.
 * A website route (outside the app) verifies email ownership with a token.
 */
import { env } from '../config/env.js';
import { AppError, check, conflict, notFound } from '../lib/errors.js';
import { normalizeEmail, pepperedHash, randomToken } from '../lib/crypto.js';
import { logger } from '../lib/logger.js';
import { BUCKETS, serviceClient } from '../lib/supabase.js';
import { sendMail } from './mail.service.js';
import { audit, enqueueJob } from './ops.service.js';

type Row = Record<string, unknown>;

export const STORE_NOTICE =
  'Deleting your account does not cancel an App Store or Google Play subscription. Cancel it in your store account settings to stop renewal.';

export async function requestDeletion(userId: string, source: 'in_app' | 'web') {
  const svc = serviceClient();
  const open = check(await svc.from('deletion_requests').select('*').eq('user_id', userId)
    .not('state', 'in', '(completed,cancelled,failed)').maybeSingle()) as Row | null;
  if (open) return { request: open, store_notice: STORE_NOTICE };
  const req = check(await svc.from('deletion_requests').insert({
    user_id: userId, source, state: 'requested', reauthenticated_at: source === 'in_app' ? new Date().toISOString() : null,
  }).select('*').single()) as Row;
  // Stop new work immediately (uploads, scans, new items are refused while pending).
  await svc.from('profiles').update({ account_state: 'deletion_pending' }).eq('id', userId);
  await audit({ actorType: 'user', actorId: userId, action: 'deletion.requested', targetType: 'deletion_request', targetId: String(req.id), metadata: { source } });
  return {
    request: req,
    store_notice: STORE_NOTICE,
    export_offer: 'You can download an export of your data before confirming (POST /v1/me/exports).',
  };
}

export async function cancelDeletion(userId: string) {
  const svc = serviceClient();
  const r = check(await svc.from('deletion_requests').update({ state: 'cancelled' }).eq('user_id', userId).eq('state', 'requested').select('id')) as Row[];
  if (r.length === 0) throw conflict('deletion_not_cancellable', 'Deletion is already in progress or completed');
  await svc.from('profiles').update({ account_state: 'active' }).eq('id', userId);
  await audit({ actorType: 'user', actorId: userId, action: 'deletion.cancelled' });
  return { cancelled: true };
}

export async function confirmDeletion(userId: string) {
  const svc = serviceClient();
  const req = check(await svc.from('deletion_requests').select('*').eq('user_id', userId).eq('state', 'requested').maybeSingle()) as Row | null;
  if (!req) throw notFound('deletion_request_not_found');
  check(await svc.from('deletion_requests').update({ state: 'confirmed', confirmed_at: new Date().toISOString() }).eq('id', req.id as string));
  await enqueueJob('account_deletion', { deletion_request_id: req.id }, { userId, dedupeKey: `del:${req.id}`, priority: 20, maxAttempts: 20 });
  await audit({ actorType: 'user', actorId: userId, action: 'deletion.confirmed', targetType: 'deletion_request', targetId: String(req.id) });
  return { state: 'confirmed', store_notice: STORE_NOTICE };
}

async function listPrefix(bucket: string, prefix: string): Promise<string[]> {
  const svc = serviceClient();
  const out: string[] = [];
  const walk = async (path: string) => {
    for (let offset = 0; ; offset += 1000) {
      const { data, error } = await svc.storage.from(bucket).list(path, { limit: 1000, offset });
      if (error) throw new AppError(502, 'storage_error', 'list failed');
      for (const entry of data ?? []) {
        const full = path ? `${path}/${entry.name}` : entry.name;
        if (entry.id === null) await walk(full); // folder
        else out.push(full);
      }
      if (!data || data.length < 1000) break;
    }
  };
  await walk(prefix);
  return out;
}

/** Worker handler for `account_deletion`. Idempotent and resumable at every step. */
export async function runDeletion(deletionRequestId: string) {
  const svc = serviceClient();
  const req = check(await svc.from('deletion_requests').select('*').eq('id', deletionRequestId).maybeSingle()) as Row | null;
  if (!req || req.state === 'completed' || req.state === 'cancelled') return { skipped: true };
  const userId = String(req.user_id);
  const bump = (patch: Row) => svc.from('deletion_requests').update({ ...patch, attempts: Number(req.attempts) + 1 }).eq('id', deletionRequestId);

  try {
    await svc.from('profiles').update({ account_state: 'deleting' }).eq('id', userId);

    // 1. Manifest (stored outside the profile cascade).
    if (req.state === 'confirmed' || req.objects_total === null) {
      const paths: Array<{ bucket: string; storage_path: string }> = [];
      const atts = check(await svc.from('attachments').select('storage_path').eq('user_id', userId)) as Row[];
      atts.forEach((a) => paths.push({ bucket: BUCKETS.files, storage_path: String(a.storage_path) }));
      for (const bucket of [BUCKETS.files, BUCKETS.exports, BUCKETS.claimPacks]) {
        for (const p of await listPrefix(bucket, userId)) paths.push({ bucket, storage_path: p });
      }
      const unique = [...new Map(paths.map((p) => [`${p.bucket}:${p.storage_path}`, p])).values()];
      for (let i = 0; i < unique.length; i += 500) {
        await svc.from('deletion_manifests').upsert(unique.slice(i, i + 500).map((p) => ({ ...p, deletion_request_id: deletionRequestId, user_id: userId })),
          { onConflict: 'deletion_request_id,bucket,storage_path', ignoreDuplicates: true });
      }
      await bump({ state: 'deleting_objects', objects_total: unique.length });
    }

    // 2. Delete objects (retry failures on the next attempt).
    const pending = check(await svc.from('deletion_manifests').select('id, bucket, storage_path, attempts')
      .eq('deletion_request_id', deletionRequestId).neq('state', 'deleted')) as Row[];
    const byBucket = new Map<string, Row[]>();
    pending.forEach((p) => byBucket.set(String(p.bucket), [...(byBucket.get(String(p.bucket)) ?? []), p]));
    let failures = 0;
    for (const [bucket, rows] of byBucket) {
      for (let i = 0; i < rows.length; i += 100) {
        const chunk = rows.slice(i, i + 100);
        const { error } = await svc.storage.from(bucket).remove(chunk.map((r) => String(r.storage_path)));
        const ids = chunk.map((r) => r.id as string);
        if (error) {
          failures += chunk.length;
          await svc.from('deletion_manifests').update({ state: 'failed', last_error: error.message.slice(0, 200) }).in('id', ids);
        } else {
          await svc.from('deletion_manifests').update({ state: 'deleted' }).in('id', ids);
        }
      }
    }
    if (failures > 0) throw new AppError(503, 'storage_delete_failed', `${failures} objects failed`);

    // 3. Delete auth user -> cascades profile and all personal records.
    await bump({ state: 'deleting_records' });
    const { error: delErr } = await svc.auth.admin.deleteUser(userId);
    if (delErr && !/not found/i.test(delErr.message)) throw new AppError(502, 'auth_delete_failed', delErr.message);
    // Pseudonymous analytics rows are detached from the deleted user.
    await svc.from('analytics_events').update({ user_id: null }).eq('user_id', userId);

    // 4. Verify.
    await bump({ state: 'verifying' });
    const leftovers = await Promise.all(['profiles', 'items', 'attachments'].map((t) =>
      svc.from(t).select('id', { count: 'exact', head: true }).eq(t === 'profiles' ? 'id' : 'user_id', userId)));
    const remainingRows = leftovers.reduce((a, r) => a + (r.count ?? 0), 0);
    const remainingObjects = (await listPrefix(BUCKETS.files, userId)).length;
    if (remainingRows > 0 || remainingObjects > 0) throw new AppError(503, 'deletion_verification_failed', `rows=${remainingRows} objects=${remainingObjects}`);

    // 5. Tombstone (replayed after any restore), purge manifest, complete.
    check(await svc.from('deletion_tombstones').upsert({ user_id: userId, request_id: deletionRequestId }));
    await svc.from('deletion_manifests').delete().eq('deletion_request_id', deletionRequestId);
    // Originals also live in the separate storage backup: purge them there too.
    await enqueueJob('storage_backup', { purge_user_id: userId }, { dedupeKey: `backup-purge:${userId}`, maxAttempts: 20 });
    await svc.from('deletion_requests').update({ state: 'completed', completed_at: new Date().toISOString(), last_error: null }).eq('id', deletionRequestId);
    await audit({ actorType: 'worker', action: 'deletion.completed', targetType: 'deletion_request', targetId: deletionRequestId });
    return { completed: true };
  } catch (err) {
    logger.warn({ err, deletionRequestId }, 'deletion attempt failed; will retry');
    await svc.from('deletion_requests').update({ last_error: (err as Error).message.slice(0, 300), attempts: Number(req.attempts) + 1 }).eq('id', deletionRequestId);
    throw err;
  }
}

// ---------------------------------------------------------------------------
// Website deletion route (outside the app)
// ---------------------------------------------------------------------------
export async function startWebDeletion(email: string) {
  const svc = serviceClient();
  const token = randomToken(32);
  const emailHash = pepperedHash(normalizeEmail(email));
  await svc.from('web_deletion_requests').insert({ email_hash: emailHash, token_hash: pepperedHash(token) });
  const link = `${env().PUBLIC_BASE_URL}/account-deletion/verify?token=${encodeURIComponent(token)}`;
  // Always send/acknowledge the same way to avoid revealing whether an account exists.
  await sendMail({
    to: email,
    subject: 'Confirm your Warrantra account deletion request',
    text: `We received a request to delete the Warrantra account for this email.\n\nTo continue, open this link within 24 hours:\n${link}\n\n${STORE_NOTICE}\n\nIf you did not request this, ignore this email.`,
  });
  return { accepted: true, message: 'If an account exists for this email, we sent instructions to confirm deletion.' };
}

export async function verifyWebDeletion(token: string) {
  const svc = serviceClient();
  const row = check(await svc.from('web_deletion_requests').select('*').eq('token_hash', pepperedHash(token)).maybeSingle()) as Row | null;
  if (!row || row.state !== 'pending_verification' || new Date(String(row.expires_at)) < new Date()) {
    throw notFound('deletion_link_invalid', 'This link is invalid or has expired');
  }
  // Find the account by verified email via the admin API.
  let userId: string | null = null;
  for (let page = 1; page <= 50 && !userId; page++) {
    const { data, error } = await svc.auth.admin.listUsers({ page, perPage: 1000 });
    if (error) throw new AppError(502, 'auth_provider_error', 'Lookup failed');
    const match = data.users.find((u) => u.email && pepperedHash(normalizeEmail(u.email)) === row.email_hash);
    if (match) userId = match.id;
    if (data.users.length < 1000) break;
  }
  if (!userId) {
    await svc.from('web_deletion_requests').update({ state: 'no_account', verified_at: new Date().toISOString() }).eq('id', row.id as string);
    return { state: 'received', message: 'Your request was received. If an account exists it will be deleted.' };
  }
  const { request } = await requestDeletion(userId, 'web');
  await svc.from('deletion_requests').update({ state: 'confirmed', confirmed_at: new Date().toISOString() }).eq('id', request.id as string);
  await enqueueJob('account_deletion', { deletion_request_id: request.id }, { userId, dedupeKey: `del:${request.id}`, priority: 20, maxAttempts: 20 });
  await svc.from('web_deletion_requests').update({ state: 'verified', verified_at: new Date().toISOString(), deletion_request_id: request.id }).eq('id', row.id as string);
  return { state: 'received', message: 'Your request was received. If an account exists it will be deleted.', store_notice: STORE_NOTICE };
}
