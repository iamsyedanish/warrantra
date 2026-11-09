/**
 * Receipt extraction pipeline:
 *   upload (or on-device OCR text) -> reserve allowance atomically -> queued job
 *   -> worker calls provider (bounded attempts) -> field validation -> review
 *   draft returned to the user -> user confirms through POST /purchases.
 * AI failure never blocks manual entry; failed actions release their allowance.
 */
import { PDFDocument } from 'pdf-lib';
import type { z } from 'zod';
import { env } from '../config/env.js';
import { AppError, check, notFound, unprocessable } from '../lib/errors.js';
import { todayIn } from '../lib/dates.js';
import { logger } from '../lib/logger.js';
import { BUCKETS, serviceClient, type Db } from '../lib/supabase.js';
import type { ScanBody } from '../validators/index.js';
import { AiProviderError, extractStructured, type AiInput, type AiUsage } from './ai/provider.js';
import { LABEL_PROMPT_VERSION, LABEL_SYSTEM, RECEIPT_PROMPT_VERSION, RECEIPT_SYSTEM, wrapDocumentText } from './ai/prompts.js';
import { ProductLabelExtraction, ReceiptExtraction, SCHEMA_VERSION } from './ai/schema.js';
import { validateReceiptCandidate } from './ai/validate.js';
import { enqueueJob, track } from './ops.service.js';

type Row = Record<string, unknown>;
const CANDIDATE_RETENTION_DAYS = 30;
const MAX_IMAGE_BYTES_FOR_AI = 5 * 1024 * 1024;

export async function startScan(db: Db, userId: string, idempotencyKey: string, body: z.infer<typeof ScanBody>) {
  // Idempotent: same key returns the same job (and never reserves twice).
  const existing = check(await db.from('scan_jobs').select('*').eq('idempotency_key', idempotencyKey).maybeSingle()) as Row | null;
  if (existing) return existing;

  let pageCount: number | null = null;
  if (body.attachment_id) {
    const att = check(await db.from('attachments').select('id, processing_state, verified_mime_type, page_count')
      .eq('id', body.attachment_id).maybeSingle()) as Row | null;
    if (!att || att.processing_state !== 'ready') throw notFound('attachment_not_found');
    if (att.verified_mime_type === 'image/heic' || att.verified_mime_type === 'image/heif') {
      throw unprocessable('heic_not_supported_for_ai', 'Use on-device text recognition or upload a JPEG/PNG for AI extraction. Manual entry is always available.');
    }
    pageCount = (att.page_count as number | null) ?? 1;
  }

  const svc = serviceClient();
  const limits = check(await svc.rpc('get_plan_limits_for_user', { p_user_id: userId })) as Row;
  if (body.ocr_text && body.ocr_text.length > Number(limits.max_ai_input_chars)) {
    throw unprocessable('input_too_large', 'Receipt text is too long for one AI action');
  }

  // Atomic reservation under the caller's identity (consent, kill switch, budgets, quota, rate limit).
  const reservation = check(await db.rpc('reserve_ai_action', {
    p_idempotency_key: `scan:${idempotencyKey}`, p_source_type: 'scan_job', p_source_id: null,
  })) as Row;

  const job = check(await svc.from('scan_jobs').insert({
    user_id: userId,
    idempotency_key: idempotencyKey,
    feature: body.feature,
    input_kind: body.attachment_id ? 'attachment' : 'ocr_text',
    input_attachment_id: body.attachment_id ?? null,
    input_page_count: pageCount,
    input_chars: body.ocr_text?.length ?? null,
    state: 'queued',
    usage_reservation_id: reservation.id,
    quota_period: reservation.quota_period,
    max_attempts: Number(await svc.from('system_settings').select('value').eq('key', 'ai_max_attempts').maybeSingle()
      .then((r) => r.data?.value ?? 2)),
    prompt_version: body.feature === 'receipt_extraction' ? RECEIPT_PROMPT_VERSION : LABEL_PROMPT_VERSION,
    schema_version: SCHEMA_VERSION,
    provider: 'anthropic',
    model: env().AI_MODEL,
  }).select('*').single()) as Row;

  await svc.from('usage_ledger').update({ source_id: job.id }).eq('id', reservation.id as string);
  if (body.capture_draft_id) {
    await svc.from('capture_drafts').update({ scan_job_id: job.id, state: 'processing' })
      .eq('id', body.capture_draft_id).eq('user_id', userId);
  }

  // OCR text is passed through the queue payload only transiently (never stored on the job row).
  await enqueueJob('scan_process', { scan_job_id: job.id, ocr_text: body.ocr_text ?? null }, { userId, dedupeKey: `scan:${job.id}`, priority: 10 });
  await track(userId, 'receipt_scan_started', { input_kind: String(job.input_kind) });
  return job;
}

async function loadAiInput(job: Row, ocrText: string | null, maxPages: number): Promise<AiInput> {
  if (job.input_kind === 'ocr_text') {
    if (!ocrText) throw new AiProviderError('invalid_output', 'OCR text missing from job payload', false);
    return { kind: 'text', text: wrapDocumentText(ocrText) };
  }
  const svc = serviceClient();
  const att = check(await svc.from('attachments').select('storage_path, verified_mime_type, user_id')
    .eq('id', job.input_attachment_id as string).maybeSingle()) as Row | null;
  if (!att || att.user_id !== job.user_id) throw new AiProviderError('invalid_output', 'Attachment unavailable', false);
  const dl = await svc.storage.from(BUCKETS.files).download(String(att.storage_path));
  if (dl.error || !dl.data) throw new AiProviderError('provider_error', 'Attachment download failed', true);
  const bytes = Buffer.from(await dl.data.arrayBuffer());

  if (att.verified_mime_type === 'application/pdf') {
    // Enforce the per-action page limit by sending only the first N pages.
    const src = await PDFDocument.load(bytes);
    const out = await PDFDocument.create();
    const n = Math.min(src.getPageCount(), maxPages);
    const pages = await out.copyPages(src, Array.from({ length: n }, (_, i) => i));
    pages.forEach((p) => out.addPage(p));
    return { kind: 'pdf', base64: Buffer.from(await out.save()).toString('base64') };
  }
  if (bytes.length > MAX_IMAGE_BYTES_FOR_AI) {
    throw new AiProviderError('invalid_output', 'image_too_large_for_ai', false);
  }
  const mediaType = att.verified_mime_type === 'image/png' ? 'image/png' : 'image/jpeg';
  return { kind: 'image', mediaType, base64: bytes.toString('base64') };
}

async function recordUsage(job: Row, usage: AiUsage | undefined, outcome: string) {
  if (!usage) return;
  await serviceClient().from('usage_events').insert({
    user_id: job.user_id,
    scan_job_id: job.id,
    feature: job.feature,
    provider: usage.provider,
    model: usage.model,
    prompt_version: job.prompt_version,
    schema_version: job.schema_version,
    input_tokens: usage.inputTokens,
    output_tokens: usage.outputTokens,
    cost_usd: usage.costUsd,
    outcome,
    latency_ms: usage.latencyMs,
  });
}

/** Worker handler for `scan_process` jobs. Throws only for retryable failures. */
export async function processScanJob(payload: { scan_job_id: string; ocr_text: string | null }): Promise<Row> {
  const svc = serviceClient();
  const job = check(await svc.from('scan_jobs').select('*').eq('id', payload.scan_job_id).maybeSingle()) as Row | null;
  if (!job) return { skipped: 'missing' };
  if (!['queued', 'processing'].includes(String(job.state))) return { skipped: job.state };

  const attempts = Number(job.attempts) + 1;
  await svc.from('scan_jobs').update({ state: 'processing', attempts, started_at: job.started_at ?? new Date().toISOString() }).eq('id', job.id as string);

  const kill = await svc.from('system_settings').select('value').eq('key', 'ai_kill_switch').maybeSingle();
  if (kill.data?.value === true) return failScan(job, 'ai_disabled');

  const limits = check(await svc.rpc('get_plan_limits_for_user', { p_user_id: job.user_id })) as Row;
  const profile = check(await svc.from('profiles').select('country_code, timezone').eq('id', job.user_id as string).single()) as Row;

  try {
    const input = await loadAiInput(job, payload.ocr_text, Number(limits.max_ai_pages_per_action ?? 2));
    const isReceipt = job.feature === 'receipt_extraction';
    const { output, usage } = await extractStructured({
      system: isReceipt ? RECEIPT_SYSTEM : LABEL_SYSTEM,
      input,
      instruction: isReceipt ? 'Extract the purchase facts from this document.' : 'Read the product label in this image.',
      schema: isReceipt ? ReceiptExtraction : ProductLabelExtraction,
    });
    await recordUsage(job, usage, 'success');

    const draft = isReceipt
      ? validateReceiptCandidate(output as ReceiptExtraction, {
          locale: profile.country_code as 'US' | 'CA' | 'GB',
          today: todayIn(String(profile.timezone)),
        })
      : output;
    const warnings = isReceipt ? (draft as { warnings: string[] }).warnings : (output as ProductLabelExtraction).warnings;

    await svc.rpc('worker_settle_usage', { p_reservation_id: job.usage_reservation_id });
    const done = check(await svc.from('scan_jobs').update({
      state: 'succeeded',
      model_version: usage.model,
      input_tokens: usage.inputTokens,
      output_tokens: usage.outputTokens,
      actual_cost_usd: usage.costUsd,
      candidate: { raw: output, review_draft: draft },
      candidate_expires_at: new Date(Date.now() + CANDIDATE_RETENTION_DAYS * 86_400_000).toISOString(),
      validation_warnings: warnings,
      completed_at: new Date().toISOString(),
      error_code: null,
    }).eq('id', job.id as string).select('id, state').single()) as Row;

    await svc.from('capture_drafts').update({ state: 'ready_for_review' }).eq('scan_job_id', job.id as string);
    await trackScan(String(job.user_id), 'receipt_scan_success', isReceipt ? { line_count: (draft as { lines: unknown[] }).lines.length } : {});
    return done;
  } catch (err) {
    const e = err instanceof AiProviderError ? err : new AiProviderError('provider_error', 'unexpected', true);
    await recordUsage(job, e.usage, e.code === 'refused' ? 'refused' : e.code === 'timeout' ? 'timeout' : e.code === 'invalid_output' ? 'invalid_output' : 'provider_error');
    logger.warn({ scanJobId: job.id, code: e.code, retryable: e.retryable, attempts }, 'scan attempt failed');
    if (e.retryable && attempts < Number(job.max_attempts)) {
      await svc.from('scan_jobs').update({ state: 'queued', error_code: e.code }).eq('id', job.id as string);
      throw new AppError(503, e.code, 'retry'); // job queue retries with backoff
    }
    return failScan(job, e.message === 'image_too_large_for_ai' ? 'image_too_large_for_ai' : e.code);
  }
}

async function failScan(job: Row, code: string): Promise<Row> {
  const svc = serviceClient();
  // Failed actions never consume the user's allowance.
  await svc.rpc('worker_release_usage', { p_reservation_id: job.usage_reservation_id, p_reason: code });
  await svc.from('scan_jobs').update({
    state: 'failed', error_code: code, completed_at: new Date().toISOString(),
    candidate_expires_at: new Date(Date.now() + CANDIDATE_RETENTION_DAYS * 86_400_000).toISOString(),
  }).eq('id', job.id as string);
  await svc.from('capture_drafts').update({ state: 'failed', error_code: code }).eq('scan_job_id', job.id as string);
  await trackScan(String(job.user_id), 'receipt_scan_failed', { error_code: code });
  return { state: 'failed', error_code: code };
}

const trackScan = (userId: string, name: string, props: Record<string, string | number | boolean>) => track(userId, name, props);

export async function getScan(db: Db, id: string) {
  const job = check(await db.from('scan_jobs').select('id, feature, input_kind, input_attachment_id, state, error_code, validation_warnings, candidate, created_at, completed_at, confirmed_purchase_group_id')
    .eq('id', id).maybeSingle()) as Row | null;
  if (!job) throw notFound('scan_not_found');
  const candidate = job.candidate as { review_draft?: unknown } | null;
  return {
    ...job,
    candidate: undefined,
    review_draft: candidate?.review_draft ?? null,
    next_step: job.state === 'succeeded'
      ? 'Review every field, select the lines to track, then POST /v1/purchases with scan_job_id.'
      : job.state === 'failed' ? 'AI extraction failed. Enter the purchase manually; your allowance was not used.' : null,
  };
}

export async function discardScan(db: Db, userId: string, id: string) {
  const job = check(await db.from('scan_jobs').select('id, state').eq('id', id).maybeSingle()) as Row | null;
  if (!job) throw notFound('scan_not_found');
  await serviceClient().from('scan_jobs').update({ state: 'discarded', candidate: null }).eq('id', id).eq('user_id', userId);
  return { discarded: true };
}
