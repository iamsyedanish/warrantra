/** Document vault, scans (AI extraction), capture drafts, email forwarding, reminders. */
import type { Request, Response } from 'express';
import { z } from 'zod';
import { authOf } from '../middleware/auth.js';
import { check } from '../lib/errors.js';
import { idempotencyKey, PaginationQuery, parseOrThrow } from '../lib/http.js';
import * as att from '../services/attachment.service.js';
import * as capture from '../services/capture.service.js';
import * as reminders from '../services/reminder.service.js';
import * as scans from '../services/scan.service.js';
import { attachmentView, list, one } from '../views/index.js';
import * as V from '../validators/index.js';

const id = (req: Request) => parseOrThrow(z.object({ id: V.Uuid }), req.params, 'params').id;

export const AttachmentController = {
  begin: async (req: Request, res: Response) => {
    const a = authOf(req);
    const r = await att.beginUpload(a.db, a.userId, idempotencyKey(req)!, parseOrThrow(V.BeginUploadBody, req.body, 'body'));
    res.status(201).json(one({ attachment: attachmentView(r.attachment), upload: r.upload, already_completed: r.already_completed,
      next_step: 'Upload the bytes with the signed URL/token, then POST /v1/attachments/{id}/complete.' }));
  },
  complete: async (req: Request, res: Response) => {
    const r = await att.completeUpload(id(req), authOf(req).userId);
    res.json(one({ attachment: attachmentView(r.attachment as Record<string, unknown>), duplicate_of: r.duplicate_of, rejection_reason: r.rejection_reason ?? null }));
  },
  vault: async (req: Request, res: Response) => {
    const p = parseOrThrow(PaginationQuery.extend({ file_type: V.BeginUploadBody.shape.file_type.optional() }), req.query, 'query');
    const rows = await att.listVault(authOf(req).db, { fileType: p.file_type, limit: p.limit, offset: p.offset });
    res.json(list((rows as Record<string, unknown>[]).map(attachmentView), p, (rows as unknown[]).length === 0 && p.offset === 0
      ? { empty_state: { title: 'Your purchase documents will live here', message: 'Receipts and warranty documents you attach to purchases will automatically appear in your vault.' } }
      : {}));
  },
  get: async (req: Request, res: Response) => {
    const row = check(await authOf(req).db.from('attachments').select('*').eq('id', id(req)).maybeSingle());
    res.json(one(row ? attachmentView(row as Record<string, unknown>) : null));
  },
  update: async (req: Request, res: Response) => {
    const row = check(await authOf(req).db.from('attachments').update(parseOrThrow(V.AttachmentPatch, req.body, 'body')).eq('id', id(req)).select('*').maybeSingle());
    res.json(one(row ? attachmentView(row as Record<string, unknown>) : null));
  },
  url: async (req: Request, res: Response) => {
    const q = parseOrThrow(z.object({ preview_width: z.coerce.number().int().min(64).max(2048).optional(), download: z.enum(['true', 'false']).optional() }), req.query, 'query');
    res.json(one(await att.signedDownloadUrl(authOf(req).db, authOf(req).userId, id(req), { previewWidth: q.preview_width, download: q.download === 'true' })));
  },
  impact: async (req: Request, res: Response) => {
    res.json(one(await att.impact(authOf(req).db, id(req))));
  },
  remove: async (req: Request, res: Response) => {
    const a = authOf(req);
    res.json(one(await att.deleteAttachment(a.db, a.userId, id(req), req.query.confirm === 'true')));
  },
  link: async (req: Request, res: Response) => {
    const a = authOf(req);
    res.status(201).json(one(await att.linkAttachment(a.db, a.userId, id(req), parseOrThrow(V.LinkAttachmentBody, req.body, 'body'))));
  },
  unlink: async (req: Request, res: Response) => {
    const p = parseOrThrow(z.object({ id: V.Uuid, target: z.enum(['item', 'purchase', 'claim']), targetId: V.Uuid }), req.params, 'params');
    res.json(one(await att.unlinkAttachment(authOf(req).db, p.id, p.target, p.targetId)));
  },
};

export const ScanController = {
  start: async (req: Request, res: Response) => {
    const a = authOf(req);
    const job = await scans.startScan(a.db, a.userId, idempotencyKey(req)!, parseOrThrow(V.ScanBody, req.body, 'body'));
    res.status(202).json(one({ id: job.id, state: job.state, note: 'Extraction never saves records. You will review every field before saving.' }));
  },
  get: async (req: Request, res: Response) => {
    res.json(one(await scans.getScan(authOf(req).db, id(req))));
  },
  list: async (req: Request, res: Response) => {
    const p = parseOrThrow(PaginationQuery, req.query, 'query');
    res.json(list(check(await authOf(req).db.from('scan_jobs').select('id, feature, input_kind, state, error_code, created_at, completed_at')
      .order('created_at', { ascending: false }).range(p.offset, p.offset + p.limit - 1)) as unknown[], p));
  },
  discard: async (req: Request, res: Response) => {
    const a = authOf(req);
    res.json(one(await scans.discardScan(a.db, a.userId, id(req))));
  },
};

export const CaptureController = {
  create: async (req: Request, res: Response) => {
    const a = authOf(req);
    const body = parseOrThrow(V.CaptureDraftBody, req.body, 'body');
    const draft = await capture.createDraft(a.db, a.userId, body);
    let scanJob = null;
    if (body.auto_scan && body.attachment_ids.length) {
      scanJob = await scans.startScan(a.db, a.userId, `draft-${String(draft.id)}`.slice(0, 128), {
        feature: 'receipt_extraction', attachment_id: body.attachment_ids[0], capture_draft_id: String(draft.id),
      });
    }
    res.status(201).json(one({ draft, scan_job_id: scanJob?.id ?? null }));
  },
  list: async (req: Request, res: Response) => {
    res.json(list(await capture.listDrafts(authOf(req).db) as unknown[]));
  },
  discard: async (req: Request, res: Response) => {
    res.json(one(await capture.discardDraft(authOf(req).db, id(req))));
  },
  address: async (req: Request, res: Response) => {
    res.json(one(await capture.forwardingAddress(authOf(req).db)));
  },
  rotate: async (req: Request, res: Response) => {
    res.status(201).json(one(await capture.rotateAddress(authOf(req).db)));
  },
  disable: async (req: Request, res: Response) => {
    res.json(one(await capture.disableAddress(authOf(req).db)));
  },
  inboundLog: async (req: Request, res: Response) => {
    res.json(list(check(await authOf(req).db.from('inbound_emails').select('id, state, rejection_reason, attachment_count, accepted_attachments, received_at, capture_draft_id')
      .order('received_at', { ascending: false }).limit(50))));
  },
};

export const ReminderController = {
  list: async (req: Request, res: Response) => {
    const p = parseOrThrow(PaginationQuery.extend({ upcoming: z.enum(['true', 'false']).default('true') }), req.query, 'query');
    res.json(list(await reminders.listReminders(authOf(req).db, { upcoming: p.upcoming === 'true', limit: p.limit, offset: p.offset }) as unknown[], p));
  },
  createCustom: async (req: Request, res: Response) => {
    res.status(201).json(one(await reminders.createCustom(authOf(req).db, parseOrThrow(V.CustomReminderBody, req.body, 'body'))));
  },
  cancelCustom: async (req: Request, res: Response) => {
    res.json(one(await reminders.cancelCustom(authOf(req).db, id(req))));
  },
  deliveries: async (req: Request, res: Response) => {
    res.json(list(check(await authOf(req).db.from('notification_deliveries').select('id, reminder_id, channel, state, queued_at, accepted_at, failed_at, opened_at')
      .order('created_at', { ascending: false }).limit(100)) as unknown[], undefined,
      { note: 'provider_accepted means the push service accepted the message; it does not confirm delivery or reading.' }));
  },
  opened: async (req: Request, res: Response) => {
    res.json(one(await reminders.markOpened(authOf(req).db, id(req))));
  },
};
