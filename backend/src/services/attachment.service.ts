/**
 * Document vault — upload lifecycle:
 *   authorize account/plan -> reserve bytes -> pending record (RPC, user JWT)
 *   -> server-authorized signed upload URL -> client uploads
 *   -> server verifies stored object (size, real MIME, PDF pages, active content,
 *      checksum) -> ready / quarantined / failed -> reservation settled/released.
 * PostgreSQL cannot atomically include the Storage write, so every step is
 * idempotent and abandoned uploads are cleaned up by the worker.
 */
import { fileTypeFromBuffer } from 'file-type';
import { PDFDocument } from 'pdf-lib';
import type { z } from 'zod';
import { AppError, check, conflict, notFound, unprocessable } from '../lib/errors.js';
import { sha256Hex } from '../lib/crypto.js';
import { logger } from '../lib/logger.js';
import { BUCKETS, serviceClient, type Db } from '../lib/supabase.js';
import { Attachments, linkRows, unlinkRow } from '../models/index.js';
import type { BeginUploadBody, LinkAttachmentBody } from '../validators/index.js';
import { audit, enqueueJob, getSetting, track } from './ops.service.js';

type Row = Record<string, unknown>;

const ALLOWED = new Set(['image/jpeg', 'image/png', 'image/heic', 'image/heif', 'application/pdf']);
// Active content markers that must never be rendered or forwarded.
const PDF_ACTIVE_MARKERS = [/\/JavaScript\b/, /\/JS\s*[(<]/, /\/Launch\b/, /\/EmbeddedFile\b/, /\/RichMedia\b/, /\/XFA\b/, /\/OpenAction\b[^>]*\/JS/];

export async function beginUpload(db: Db, userId: string, idempotencyKey: string, body: z.infer<typeof BeginUploadBody>) {
  const att = check(
    await db.rpc('begin_attachment_upload', {
      p_idempotency_key: idempotencyKey,
      p_file_type: body.file_type,
      p_filename: body.filename,
      p_declared_mime: body.mime_type,
      p_declared_size: body.byte_size,
    }),
  ) as Row;

  if (att.processing_state !== 'pending_upload') {
    return { attachment: att, upload: null, already_completed: true };
  }
  const { data, error } = await serviceClient().storage.from(BUCKETS.files).createSignedUploadUrl(String(att.storage_path), { upsert: true });
  if (error || !data) throw new AppError(502, 'storage_error', 'Could not authorize the upload');
  await audit({ actorType: 'user', actorId: userId, action: 'attachment.upload_authorized', targetType: 'attachment', targetId: String(att.id) });
  return {
    attachment: att,
    upload: { bucket: BUCKETS.files, path: data.path, token: data.token, signed_url: data.signedUrl, expires_in_seconds: 7200 },
    already_completed: false,
  };
}

export interface VerificationResult {
  outcome: 'ready' | 'quarantined' | 'failed';
  verifiedMime: string | null;
  size: number;
  pageCount: number | null;
  checksum: string | null;
  reason?: string;
}

/** Pure inspection of uploaded bytes (unit-tested). */
export async function inspectBytes(bytes: Buffer, declaredMime: string, limits: { maxBytes: number; maxPdfPages: number }): Promise<VerificationResult> {
  const size = bytes.length;
  const checksum = sha256Hex(bytes);
  if (size === 0) return { outcome: 'failed', verifiedMime: null, size, pageCount: null, checksum: null, reason: 'empty_file' };
  if (size > limits.maxBytes) return { outcome: 'failed', verifiedMime: null, size, pageCount: null, checksum, reason: 'file_too_large' };

  const head = bytes.subarray(0, 1024).toString('latin1').toLowerCase();
  if (/<html|<script|<svg|<!doctype html/.test(head)) {
    return { outcome: 'quarantined', verifiedMime: null, size, pageCount: null, checksum, reason: 'active_markup_detected' };
  }

  const detected = await fileTypeFromBuffer(bytes);
  let mime = detected?.mime ?? null;
  if (mime === 'image/heif-sequence' || mime === 'image/heic-sequence') mime = 'image/heic';
  if (!mime || !ALLOWED.has(mime)) {
    return { outcome: 'quarantined', verifiedMime: null, size, pageCount: null, checksum, reason: `unsupported_content:${mime ?? 'unknown'}` };
  }
  const declaredFamily = declaredMime === 'application/pdf' ? 'pdf' : 'image';
  const actualFamily = mime === 'application/pdf' ? 'pdf' : 'image';
  if (declaredFamily !== actualFamily) {
    return { outcome: 'quarantined', verifiedMime: mime, size, pageCount: null, checksum, reason: 'declared_type_mismatch' };
  }

  let pageCount: number | null = null;
  if (mime === 'application/pdf') {
    const text = bytes.toString('latin1');
    if (PDF_ACTIVE_MARKERS.some((re) => re.test(text))) {
      return { outcome: 'quarantined', verifiedMime: mime, size, pageCount: null, checksum, reason: 'pdf_active_content' };
    }
    try {
      const doc = await PDFDocument.load(bytes, { ignoreEncryption: false, updateMetadata: false });
      pageCount = doc.getPageCount();
    } catch (err) {
      const encrypted = /encrypt/i.test((err as Error).message);
      return { outcome: 'quarantined', verifiedMime: mime, size, pageCount: null, checksum, reason: encrypted ? 'pdf_encrypted' : 'pdf_unreadable' };
    }
    if (pageCount > limits.maxPdfPages) {
      return { outcome: 'failed', verifiedMime: mime, size, pageCount, checksum, reason: 'too_many_pdf_pages' };
    }
  }
  return { outcome: 'ready', verifiedMime: mime, size, pageCount, checksum };
}

/** Called by the client after its upload finishes (and by the worker as a fallback). */
export async function completeUpload(attachmentId: string, expectedUserId?: string) {
  const svc = serviceClient();
  const att = check(await svc.from('attachments').select('*').eq('id', attachmentId).maybeSingle()) as Row | null;
  if (!att || (expectedUserId && att.user_id !== expectedUserId)) throw notFound('attachment_not_found');
  if (att.processing_state !== 'pending_upload' && att.processing_state !== 'verifying') {
    return { attachment: att, duplicate_of: null };
  }
  const limits = check(await svc.rpc('get_plan_limits_for_user', { p_user_id: att.user_id })) as Row | null;

  const dl = await svc.storage.from(BUCKETS.files).download(String(att.storage_path));
  if (dl.error || !dl.data) throw conflict('upload_not_found', 'The file has not finished uploading');
  const bytes = Buffer.from(await dl.data.arrayBuffer());

  const result = await inspectBytes(bytes, String(att.declared_mime_type), {
    maxBytes: Number(limits?.max_file_bytes ?? 10 * 1024 * 1024),
    maxPdfPages: Number(limits?.max_pdf_pages_stored ?? 10),
  });

  const updated = check(
    await svc.rpc('worker_complete_attachment_upload', {
      p_attachment_id: attachmentId,
      p_verified_mime: result.verifiedMime,
      p_actual_size: result.size,
      p_page_count: result.pageCount,
      p_checksum: result.checksum,
      p_outcome: result.outcome,
      p_reason: result.reason ?? null,
    }),
  ) as Row;

  if (result.outcome !== 'ready') {
    // Do not keep rejected bytes around; quarantined files are retained only as metadata.
    await svc.storage.from(BUCKETS.files).remove([String(att.storage_path)]);
    logger.info({ attachmentId, reason: result.reason }, 'upload rejected');
  }

  // Account-local duplicate detection (never cross-account).
  let duplicateOf: string | null = null;
  if (result.outcome === 'ready' && result.checksum) {
    const dup = await svc
      .from('attachments')
      .select('id')
      .eq('user_id', att.user_id as string)
      .eq('checksum_sha256', result.checksum)
      .eq('deletion_state', 'active')
      .eq('processing_state', 'ready')
      .neq('id', attachmentId)
      .limit(1);
    duplicateOf = (dup.data?.[0]?.id as string | undefined) ?? null;
  }
  return { attachment: updated, duplicate_of: duplicateOf, rejection_reason: result.outcome === 'ready' ? null : result.reason };
}

export async function signedDownloadUrl(db: Db, userId: string, attachmentId: string, opts: { previewWidth?: number; download?: boolean } = {}) {
  // RLS decides visibility (owner or active workspace member).
  const att = check(await db.from('attachments').select('id, storage_path, processing_state, verified_mime_type, original_filename, file_type')
    .eq('id', attachmentId).maybeSingle()) as Row | null;
  if (!att || att.processing_state !== 'ready') throw notFound('attachment_not_found');
  const ttl = Number(await getSetting('signed_url_ttl_seconds', 300));
  const isImage = String(att.verified_mime_type).startsWith('image/') && att.verified_mime_type !== 'image/heic' && att.verified_mime_type !== 'image/heif';
  const { data, error } = await serviceClient().storage.from(BUCKETS.files).createSignedUrl(String(att.storage_path), ttl, {
    download: opts.download ? String(att.original_filename ?? 'document') : undefined,
    transform: opts.previewWidth && isImage ? { width: opts.previewWidth, resize: 'contain', quality: 80 } : undefined,
  });
  if (error || !data) throw new AppError(502, 'storage_error', 'Could not create a download link');
  await track(userId, 'proof_retrieved', { file_type: String(att.file_type) });
  // The URL is a bearer credential until expiry: returned to the client only, never logged.
  return { url: data.signedUrl, expires_in_seconds: ttl };
}

export async function listVault(db: Db, opts: { fileType?: string; limit: number; offset: number }) {
  let q = db.from('attachments')
    .select('id, file_type, original_filename, verified_mime_type, actual_byte_size, page_count, processing_state, created_at, item_attachments(item_id, role), claim_attachments(claim_id)')
    .eq('deletion_state', 'active')
    .in('processing_state', ['ready', 'quarantined'])
    .order('created_at', { ascending: false });
  if (opts.fileType) q = q.eq('file_type', opts.fileType);
  return check(await q.range(opts.offset, opts.offset + opts.limit - 1));
}

export async function impact(db: Db, attachmentId: string) {
  const r = check(await db.rpc('get_attachment_impact', { p_attachment_id: attachmentId }));
  if (!r) throw notFound('attachment_not_found');
  return r as Row;
}

/** Explicit document deletion: the caller must have seen the impact (confirm=true). */
export async function deleteAttachment(db: Db, userId: string, attachmentId: string, confirm: boolean) {
  const effect = await impact(db, attachmentId);
  const linked = (effect.items as unknown[]).length + (effect.purchases as unknown[]).length + (effect.claims as unknown[]).length;
  if (linked > 0 && !confirm) {
    throw conflict('confirmation_required', 'This document is linked to other records. Review the impact and confirm.', { impact: effect });
  }
  const svc = serviceClient();
  const att = check(await svc.from('attachments').select('id, user_id, storage_path').eq('id', attachmentId).eq('user_id', userId).maybeSingle()) as Row | null;
  if (!att) throw notFound('attachment_not_found');
  check(await svc.from('attachments').update({ deletion_state: 'pending_deletion' }).eq('id', attachmentId));
  const rm = await svc.storage.from(BUCKETS.files).remove([String(att.storage_path)]);
  if (rm.error) {
    await enqueueJob('maintenance', { task: 'delete_attachment', attachment_id: attachmentId }, { userId, dedupeKey: `del-att:${attachmentId}` });
  } else {
    check(await svc.from('attachments').delete().eq('id', attachmentId));
  }
  await audit({ actorType: 'user', actorId: userId, action: 'attachment.deleted', targetType: 'attachment', targetId: attachmentId, metadata: { linked } });
  return { deleted: true, impact: effect };
}

export async function linkAttachment(db: Db, userId: string, attachmentId: string, body: z.infer<typeof LinkAttachmentBody>) {
  const att = await Attachments(db).get(attachmentId, 'attachment_not_found');
  if (att.processing_state !== 'ready') throw unprocessable('attachment_not_ready');
  if (body.target === 'item') {
    await linkRows(db, 'item_attachments', [{ item_id: body.target_id, attachment_id: attachmentId, user_id: userId, role: body.role ?? 'document' }]);
  } else if (body.target === 'purchase') {
    await linkRows(db, 'purchase_attachments', [{ purchase_group_id: body.target_id, attachment_id: attachmentId, user_id: userId }]);
  } else {
    await linkRows(db, 'claim_attachments', [{
      claim_id: body.target_id, attachment_id: attachmentId, user_id: userId,
      include_in_pack: body.include_in_pack ?? true, caption: body.caption ?? null,
    }]);
  }
  return { linked: true };
}

export async function unlinkAttachment(db: Db, attachmentId: string, target: 'item' | 'purchase' | 'claim', targetId: string) {
  const table = { item: 'item_attachments', purchase: 'purchase_attachments', claim: 'claim_attachments' }[target];
  const col = { item: 'item_id', purchase: 'purchase_group_id', claim: 'claim_id' }[target];
  const n = await unlinkRow(db, table, { attachment_id: attachmentId, [col]: targetId });
  if (n === 0) throw notFound('link_not_found');
  return { unlinked: true, note: 'The document stays in your vault until you delete it.' };
}
