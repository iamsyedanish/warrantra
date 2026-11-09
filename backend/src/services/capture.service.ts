/**
 * Capture drafts (share-to-app, uploads) and email forwarding ingestion.
 * - Share-to-app: only files the user explicitly shares become a draft.
 * - Email forwarding: unique rotatable address, authenticated webhook,
 *   SPF/DKIM verdict check, file screening, per-address daily quota,
 *   duplicate detection by Message-ID and file checksum. No message bodies kept.
 */
import type { z } from 'zod';
import { env } from '../config/env.js';
import { AppError, check, notFound, unauthorized } from '../lib/errors.js';
import { pepperedHash, safeEqual, sha256Hex } from '../lib/crypto.js';
import { logger } from '../lib/logger.js';
import { BUCKETS, serviceClient, type Db } from '../lib/supabase.js';
import { CaptureDrafts, linkRows } from '../models/index.js';
import type { CaptureDraftBody } from '../validators/index.js';
import { inspectBytes } from './attachment.service.js';
import { enqueueJob } from './ops.service.js';

type Row = Record<string, unknown>;

export async function createDraft(db: Db, userId: string, body: z.infer<typeof CaptureDraftBody>) {
  const draft = await CaptureDrafts(db).insert({ user_id: userId, source: body.source, title: body.title ?? null, state: 'pending' });
  await linkRows(db, 'capture_draft_attachments', body.attachment_ids.map((a) => ({ draft_id: draft.id, attachment_id: a, user_id: userId })));
  return draft;
}

export const listDrafts = async (db: Db) =>
  check(await db.from('capture_drafts').select('*, capture_draft_attachments(attachment_id)')
    .in('state', ['pending', 'processing', 'ready_for_review', 'failed']).order('created_at', { ascending: false }));

export async function discardDraft(db: Db, id: string) {
  const res = check(await db.from('capture_drafts').update({ state: 'discarded' }).eq('id', id).select('id')) as Row[];
  if (res.length === 0) throw notFound('draft_not_found');
  return { discarded: true, note: 'Attached documents remain in your vault until you delete them.' };
}

export async function forwardingAddress(db: Db) {
  const row = check(await db.from('inbound_addresses').select('id, local_part, state, created_at').eq('state', 'active').maybeSingle()) as Row | null;
  return row ? { address: `${row.local_part}@${env().INBOUND_DOMAIN}`, created_at: row.created_at } : null;
}

export async function rotateAddress(db: Db) {
  const row = check(await db.rpc('rotate_inbound_address')) as Row;
  return { address: `${row.local_part}@${env().INBOUND_DOMAIN}`, created_at: row.created_at, note: 'Your previous forwarding address no longer accepts email.' };
}

export async function disableAddress(db: Db) {
  check(await db.rpc('disable_inbound_address'));
  return { disabled: true };
}

// ---------------------------------------------------------------------------
// Inbound webhook (Postmark inbound JSON format)
// ---------------------------------------------------------------------------
interface PostmarkInbound {
  MessageID: string;
  From?: string;
  OriginalRecipient?: string;
  To?: string;
  ToFull?: Array<{ Email: string }>;
  Subject?: string;
  Headers?: Array<{ Name: string; Value: string }>;
  Attachments?: Array<{ Name: string; Content: string; ContentType: string; ContentLength: number }>;
}

export function verifyInboundAuth(authHeader: string | undefined): void {
  const pass = env().INBOUND_WEBHOOK_PASSWORD;
  if (!pass) throw unauthorized('inbound_not_configured');
  const m = /^Basic\s+(.+)$/i.exec(authHeader ?? '');
  if (!m) throw unauthorized('invalid_webhook_auth');
  const decoded = Buffer.from(m[1]!, 'base64').toString('utf8');
  if (!safeEqual(decoded, `${env().INBOUND_WEBHOOK_USER}:${pass}`)) throw unauthorized('invalid_webhook_auth');
}

export function senderAuthVerdict(headers: Array<{ Name: string; Value: string }> = []): 'pass' | 'fail' | 'none' {
  const results = headers.filter((h) => /^(authentication-results|arc-authentication-results)$/i.test(h.Name)).map((h) => h.Value.toLowerCase());
  const spf = headers.find((h) => /^received-spf$/i.test(h.Name))?.Value.toLowerCase() ?? '';
  if (results.some((r) => /dkim=pass/.test(r)) || results.some((r) => /spf=pass/.test(r)) || spf.startsWith('pass')) return 'pass';
  if (results.length === 0 && !spf) return 'none';
  return 'fail';
}

/** Record and queue an inbound email; returns quickly so the provider does not retry. */
export async function receiveInbound(payload: PostmarkInbound) {
  const svc = serviceClient();
  const recipients = [payload.OriginalRecipient, payload.To, ...(payload.ToFull ?? []).map((t) => t.Email)].filter(Boolean) as string[];
  const domain = env().INBOUND_DOMAIN.toLowerCase();
  const local = recipients.map((r) => r.toLowerCase().match(/([a-z0-9]+)@([a-z0-9.-]+)/)).find((m) => m && m[2] === domain)?.[1];
  const address = local
    ? (check(await svc.from('inbound_addresses').select('id, user_id, state').eq('local_part', local).maybeSingle()) as Row | null)
    : null;

  const messageIdHeader = payload.Headers?.find((h) => /^message-id$/i.test(h.Name))?.Value ?? payload.MessageID;
  const base = {
    provider: 'postmark',
    provider_message_id: payload.MessageID,
    message_id_hash: messageIdHeader ? pepperedHash(messageIdHeader) : null,
    from_hash: payload.From ? pepperedHash(payload.From) : null,
    auth_verdict: senderAuthVerdict(payload.Headers),
    attachment_count: payload.Attachments?.length ?? 0,
    total_bytes: (payload.Attachments ?? []).reduce((a, x) => a + (x.ContentLength ?? 0), 0),
  };

  if (!address || address.state !== 'active') {
    await svc.from('inbound_emails').upsert({ ...base, state: 'unknown_address' }, { onConflict: 'provider,provider_message_id', ignoreDuplicates: true });
    return { accepted: false };
  }
  const { data, error } = await svc.from('inbound_emails')
    .insert({ ...base, inbound_address_id: address.id, user_id: address.user_id, state: 'received' }).select('id').single();
  if (error) {
    if (error.code === '23505') return { accepted: false, duplicate: true };
    throw new AppError(500, 'inbound_record_failed', 'Could not record inbound email');
  }
  // Attachments travel to the worker inside the job payload, which is cleared after processing.
  await enqueueJob('email_ingest', { inbound_email_id: data.id, attachments: payload.Attachments ?? [] },
    { userId: String(address.user_id), dedupeKey: `inbound:${data.id}`, priority: 30 });
  return { accepted: true };
}

/** Worker handler for `email_ingest`. */
export async function processInbound(job: { inbound_email_id: string; attachments: PostmarkInbound['Attachments'] }) {
  const svc = serviceClient();
  const email = check(await svc.from('inbound_emails').select('*').eq('id', job.inbound_email_id).maybeSingle()) as Row | null;
  if (!email || email.state !== 'received') return { skipped: true };
  const userId = String(email.user_id);
  const reject = async (state: string, reason: string) => {
    await svc.from('inbound_emails').update({ state, rejection_reason: reason, processed_at: new Date().toISOString() }).eq('id', email.id as string);
    return { state, reason };
  };

  if (env().INBOUND_REQUIRE_SENDER_AUTH && email.auth_verdict !== 'pass') return reject('rejected_auth', 'sender_not_authenticated');

  const limits = check(await svc.rpc('get_plan_limits_for_user', { p_user_id: userId })) as Row;
  if (!limits.email_forwarding_enabled) return reject('rejected_quota', 'plan_feature_unavailable');
  const dailyLimit = Number((await svc.from('system_settings').select('value').eq('key', 'email_ingest_daily_limit').maybeSingle()).data?.value ?? 30);
  const since = new Date(Date.now() - 86_400_000).toISOString();
  const today = await svc.from('inbound_emails').select('id', { count: 'exact', head: true })
    .eq('inbound_address_id', email.inbound_address_id as string).gte('received_at', since).in('state', ['accepted', 'processed']);
  if ((today.count ?? 0) >= dailyLimit) return reject('rejected_quota', 'daily_limit');

  if (email.message_id_hash) {
    const dup = await svc.from('inbound_emails').select('id', { count: 'exact', head: true }).eq('user_id', userId)
      .eq('message_id_hash', email.message_id_hash as string).neq('id', email.id as string).in('state', ['accepted', 'processed']);
    if ((dup.count ?? 0) > 0) return reject('duplicate', 'same_message_id');
  }

  const files = (job.attachments ?? []).filter((a) => /^(image\/(jpeg|png|heic|heif)|application\/pdf)$/i.test(a.ContentType)).slice(0, 5);
  if (files.length === 0) return reject('no_attachments', 'no_supported_attachments');

  const draft = check(await svc.from('capture_drafts').insert({ user_id: userId, source: 'email_forward', state: 'pending', inbound_email_id: email.id,
    title: 'Forwarded receipt' }).select('id').single()) as Row;
  let accepted = 0;
  for (const f of files) {
    const bytes = Buffer.from(f.Content, 'base64');
    const checksum = sha256Hex(bytes);
    const existing = await svc.from('attachments').select('id').eq('user_id', userId).eq('checksum_sha256', checksum).eq('deletion_state', 'active').limit(1);
    let attachmentId = existing.data?.[0]?.id as string | undefined;
    if (!attachmentId) {
      const verdict = await inspectBytes(bytes, f.ContentType.toLowerCase(), {
        maxBytes: Number(limits.max_file_bytes), maxPdfPages: Number(limits.max_pdf_pages_stored),
      });
      if (verdict.outcome !== 'ready') {
        logger.info({ reason: verdict.reason }, 'forwarded file rejected');
        continue;
      }
      const id = crypto.randomUUID();
      const path = `${userId}/${id}/${(f.Name || 'receipt').replace(/[^A-Za-z0-9._-]+/g, '_').slice(0, 100)}`;
      const up = await svc.storage.from(BUCKETS.files).upload(path, bytes, { contentType: verdict.verifiedMime ?? undefined });
      if (up.error) continue;
      // Quota is checked atomically in the database (same lock as app uploads).
      const reg = await svc.rpc('worker_register_server_attachment', {
        p_user_id: userId, p_id: id, p_path: path, p_filename: f.Name ?? 'receipt', p_declared_mime: f.ContentType.toLowerCase(),
        p_verified_mime: verdict.verifiedMime, p_size: bytes.length, p_pages: verdict.pageCount, p_checksum: checksum, p_source: 'email_forward',
      });
      if (reg.error) {
        await svc.storage.from(BUCKETS.files).remove([path]);
        logger.info({ code: reg.error.message.slice(0, 60) }, 'forwarded file refused');
        continue;
      }
      attachmentId = id;
    }
    await svc.from('capture_draft_attachments').upsert({ draft_id: draft.id, attachment_id: attachmentId, user_id: userId }, { ignoreDuplicates: true });
    accepted++;
  }
  await svc.from('inbound_emails').update({
    state: accepted > 0 ? 'processed' : 'rejected_screening', accepted_attachments: accepted, capture_draft_id: draft.id,
    processed_at: new Date().toISOString(), rejection_reason: accepted > 0 ? null : 'all_files_rejected',
  }).eq('id', email.id as string);
  if (accepted === 0) await svc.from('capture_drafts').update({ state: 'failed', error_code: 'no_valid_files' }).eq('id', draft.id as string);
  else await svc.from('capture_drafts').update({ state: 'ready_for_review' }).eq('id', draft.id as string);
  return { accepted };
}
