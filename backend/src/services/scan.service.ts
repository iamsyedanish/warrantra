/**
 * Receipt extraction pipeline:
 *   upload (or on-device OCR text) -> reserve allowance atomically -> queued job
 *   -> worker calls provider (bounded attempts) -> field validation -> review
 *   draft returned to the user -> user confirms through POST /purchases.
 * AI failure never blocks manual entry; failed actions release their allowance.
 */
import { PDFDocument } from 'pdf-lib';
import sharp from 'sharp';
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
import { validateLabelCandidate, validateReceiptCandidate } from './ai/validate.js';
import { audit, enqueueJob, track } from './ops.service.js';
import { sha256Hex } from '../lib/crypto.js';

type Row = Record<string, unknown>;
const CANDIDATE_RETENTION_DAYS = 30;
const MAX_IMAGE_BYTES_FOR_AI = 5 * 1024 * 1024;

export async function startScan(db: Db, userId: string, idempotencyKey: string, body: z.infer<typeof ScanBody>) {
  // Idempotent: same key returns the same job (and never reserves twice).
  const existing = check(await db.from('scan_jobs').select('*').eq('idempotency_key', idempotencyKey).maybeSingle()) as Row | null;
  if (existing) return existing;

  let pageCount: number | null = null;
  let inputHash: string | null = body.ocr_text ? sha256Hex(body.ocr_text.trim()) : null;
  if (body.attachment_id) {
    const att = check(await db.from('attachments').select('id, processing_state, verified_mime_type, page_count, checksum_sha256')
      .eq('id', body.attachment_id).maybeSingle()) as Row | null;
    if (!att || att.processing_state !== 'ready') throw notFound('attachment_not_found');
    if (att.verified_mime_type === 'image/heic' || att.verified_mime_type === 'image/heif') {
      throw unprocessable('heic_not_supported_for_ai', 'Use on-device text recognition or upload a JPEG/PNG for AI extraction. Manual entry is always available.');
    }
    pageCount = (att.page_count as number | null) ?? 1;
    inputHash = (att.checksum_sha256 as string | null) ?? null;
  }

  // The same file/text was already processed: reuse that result — no new AI call, no charge.
  if (inputHash) {
    const prior = check(await db.from('scan_jobs').select('id, state, candidate, validation_warnings, error_code, model, model_version, prompt_version, schema_version')
      .eq('feature', body.feature).eq('input_sha256', inputHash).in('state', ['succeeded', 'confirmed', 'rejected'])
      .not('candidate', 'is', null).order('created_at', { ascending: false }).limit(1).maybeSingle()) as Row | null;
    if (prior) {
      const reused = check(await serviceClient().from('scan_jobs').insert({
        user_id: userId, idempotency_key: idempotencyKey, feature: body.feature,
        input_kind: body.attachment_id ? 'attachment' : 'ocr_text', input_attachment_id: body.attachment_id ?? null,
        input_page_count: pageCount, input_chars: body.ocr_text?.length ?? null, input_sha256: inputHash,
        state: prior.state === 'rejected' ? 'rejected' : 'succeeded', error_code: prior.error_code ?? null,
        candidate: prior.candidate, validation_warnings: prior.validation_warnings, reused_from_job_id: prior.id,
        provider: 'reuse', model: prior.model, model_version: prior.model_version, prompt_version: prior.prompt_version,
        schema_version: prior.schema_version, actual_cost_usd: 0, completed_at: new Date().toISOString(),
        candidate_expires_at: new Date(Date.now() + CANDIDATE_RETENTION_DAYS * 86_400_000).toISOString(),
      }).select('*').single()) as Row;
      if (reused.state === 'rejected') await recordAbuseSignal(userId);
      return reused;
    }
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
    input_sha256: inputHash,
    state: 'queued',
    usage_reservation_id: reservation.id,
    quota_period: reservation.quota_period,
    max_attempts: Number(await svc.from('system_settings').select('value').eq('key', 'ai_max_attempts').maybeSingle()
      .then((r) => r.data?.value ?? 2)),
    prompt_version: body.feature === 'receipt_extraction' ? RECEIPT_PROMPT_VERSION : LABEL_PROMPT_VERSION,
    schema_version: SCHEMA_VERSION,
    provider: env().AI_PROVIDER,
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
  const prepared = await prepareImageForAi(bytes);
  if (prepared.length > MAX_IMAGE_BYTES_FOR_AI) {
    throw new AiProviderError('invalid_output', 'image_too_large_for_ai', false);
  }
  return { kind: 'image', mediaType: 'image/jpeg', base64: prepared.toString('base64') };
}

/**
 * Normalise a stored original for the AI (the original itself is never changed):
 * apply EXIF rotation, flatten transparency onto WHITE (a transparent screenshot
 * would otherwise read as black text on black), cap the long edge, and re-encode
 * as JPEG so large phone photos stay within provider limits.
 */
export async function prepareImageForAi(bytes: Buffer, maxEdge = 2048): Promise<Buffer> {
  return sharp(bytes, { failOn: 'error' })
    .rotate()
    .flatten({ background: '#ffffff' })
    .resize({ width: maxEdge, height: maxEdge, fit: 'inside', withoutEnlargement: true })
    .jpeg({ quality: 85, mozjpeg: true })
    .toBuffer();
}

async function recordUsage(job: Row, usage: AiUsage | undefined, outcome: string) {
  if (!usage) return;
  const ledger = job.usage_reservation_id
    ? (await serviceClient().from('usage_ledger').select('plan_code').eq('id', job.usage_reservation_id as string).maybeSingle()).data
    : null;
  await serviceClient().from('usage_events').insert({
    plan_code: (ledger?.plan_code as string | undefined) ?? null,
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
      schemaName: isReceipt ? 'receipt_extraction' : 'product_label_extraction',
    });
    await recordUsage(job, usage, 'success');

    const docType = (output as { document_type?: string }).document_type;
    if (docType === 'other') {
      return rejectScan(job, isReceipt ? 'not_a_receipt' : 'not_a_product_label', usage);
    }

    const draft = isReceipt
      ? validateReceiptCandidate(output as ReceiptExtraction, {
          locale: profile.country_code as 'US' | 'CA' | 'GB',
          today: todayIn(String(profile.timezone)),
        })
      : await withCoverageSuggestion(validateLabelCandidate(output as ProductLabelExtraction), String(profile.country_code));
    const warnings = (draft as { warnings: string[] }).warnings;

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
    const failed = await failScan(job, e.message === 'image_too_large_for_ai' ? 'image_too_large_for_ai' : e.code);
    if (e.code === 'refused') await recordAbuseSignal(String(job.user_id));
    return failed;
  }
}

/**
 * "Sony PlayStation 5 detected. Sony's standard warranty appears to be 1 year. Confirm?"
 * Suggestions come only from reviewed reference data and are never applied automatically.
 */
async function withCoverageSuggestion<T extends { brand: { value: string | null } }>(draft: T, country: string) {
  const brand = draft.brand.value?.trim().toLowerCase();
  if (!brand) return { ...draft, suggested_coverage: [] };
  const svc = serviceClient();
  const b = check(await svc.from('brands').select('id, name, support_url, registration_url').eq('normalized_name', brand).maybeSingle()) as Row | null;
  if (!b) return { ...draft, suggested_coverage: [] };
  const refs = check(await svc.from('warranty_reference').select('id, product_family, term_kind, standard_duration_months, conditions_summary, source_url, last_verified_at')
    .eq('brand_id', b.id as string).eq('country_code', country).eq('review_status', 'published')) as Row[];
  return {
    ...draft,
    brand_reference: { brand_id: b.id, name: b.name, support_url: b.support_url, registration_url: b.registration_url },
    suggested_coverage: refs.map((r) => ({
      source_reference_id: r.id, coverage_type: 'manufacturer', provider_name: b.name, product_family: r.product_family,
      term_kind: r.term_kind, duration_months: r.standard_duration_months, conditions_summary: r.conditions_summary,
      source_url: r.source_url, last_verified_at: r.last_verified_at, date_certainty: 'estimated', source_kind: 'reference_suggestion',
      prompt: r.standard_duration_months
        ? `${b.name}'s standard warranty for ${r.product_family} appears to be ${r.standard_duration_months} months. Confirm?`
        : `${b.name} lists ${r.term_kind} terms for ${r.product_family}. Confirm?`,
    })),
    suggestion_disclaimer: 'Suggested warranty based on available manufacturer information. Confirm your actual warranty terms.',
  };
}

/**
 * The model ran (and was paid for) but the input was not what the feature is for.
 * The action counts against the allowance — otherwise unrelated uploads would be a
 * free way to burn provider spend — and it is recorded as an abuse signal.
 */
async function rejectScan(job: Row, code: 'not_a_receipt' | 'not_a_product_label', usage: AiUsage): Promise<Row> {
  const svc = serviceClient();
  await svc.rpc('worker_settle_usage', { p_reservation_id: job.usage_reservation_id });
  await svc.from('scan_jobs').update({
    state: 'rejected', error_code: code, completed_at: new Date().toISOString(),
    actual_cost_usd: usage.costUsd, input_tokens: usage.inputTokens, output_tokens: usage.outputTokens,
    candidate: { rejected: code }, candidate_expires_at: new Date(Date.now() + CANDIDATE_RETENTION_DAYS * 86_400_000).toISOString(),
    validation_warnings: [code === 'not_a_receipt' ? 'This does not look like a receipt, invoice or order confirmation.' : 'This does not look like a product or product label.'],
  }).eq('id', job.id as string);
  await svc.from('capture_drafts').update({ state: 'failed', error_code: code }).eq('scan_job_id', job.id as string);
  await trackScan(String(job.user_id), 'receipt_scan_failed', { error_code: code });
  await recordAbuseSignal(String(job.user_id));
  return { state: 'rejected', error_code: code };
}

/** Evaluate recent abuse signals; suspends AI (not the account) past the threshold. */
export async function recordAbuseSignal(userId: string): Promise<void> {
  const r = check(await serviceClient().rpc('worker_ai_abuse_check', { p_user_id: userId })) as { suspended: boolean; signals: number };
  if (r.suspended) logger.warn({ userId, signals: r.signals }, 'AI suspended after repeated abuse signals');
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
      : job.state === 'failed' ? 'AI extraction failed. Enter the purchase manually; your allowance was not used.'
      : job.state === 'rejected' ? 'This did not look like a receipt or product label, so nothing was extracted. Upload a receipt or enter the purchase manually.' : null,
  };
}

export async function discardScan(db: Db, userId: string, id: string) {
  const job = check(await db.from('scan_jobs').select('id, state').eq('id', id).maybeSingle()) as Row | null;
  if (!job) throw notFound('scan_not_found');
  await serviceClient().from('scan_jobs').update({ state: 'discarded', candidate: null }).eq('id', id).eq('user_id', userId);
  return { discarded: true };
}
