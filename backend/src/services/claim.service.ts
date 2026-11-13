/**
 * Claim readiness: user-reviewed snapshot + chosen evidence -> deterministic
 * factual template (text/PDF). Pro adds an assembled evidence package and an
 * optional bounded AI draft. Warrantra never submits claims and never invents
 * defects, rights, proof, dates or eligibility.
 */
import PDFKit from 'pdfkit';
import { PDFDocument } from 'pdf-lib';
import type { z } from 'zod';
import { env } from '../config/env.js';
import { AppError, check, forbidden, notFound, unprocessable } from '../lib/errors.js';
import { sha256Hex } from '../lib/crypto.js';
import { BUCKETS, serviceClient, type Db } from '../lib/supabase.js';
import { Claims, linkRows } from '../models/index.js';
import type { ClaimCreateBody, ClaimPatch, OutcomeBody } from '../validators/index.js';
import { AiProviderError, generateText, moderate } from './ai/provider.js';
import { recordAbuseSignal } from './scan.service.js';
import { CLAIM_DRAFT_PROMPT_VERSION, CLAIM_DRAFT_SYSTEM } from './ai/prompts.js';
import { audit, getSetting, track } from './ops.service.js';

type Row = Record<string, unknown>;
export const TEMPLATE_VERSION = 'claim-template-v1';

const DISCLAIMER =
  'Prepared by the customer using Warrantra. Warrantra is not an insurer, lawyer or manufacturer, does not submit claims, ' +
  'and does not determine eligibility or legal rights. Facts below were reviewed by the customer; items marked "estimated" or "unknown" were not verified.';

export async function createClaim(db: Db, userId: string, body: z.infer<typeof ClaimCreateBody>) {
  const item = check(await db.from('items').select('id, name, brand, brand_id').eq('id', body.item_id).maybeSingle()) as Row | null;
  if (!item) throw notFound('item_not_found');
  // Prefill provider contact from curated brand data when the user gave none (they can edit it).
  if (!body.provider_contact && (item.brand_id || item.brand)) {
    let q = db.from('brands').select('name, support_email, support_phone, support_url');
    q = item.brand_id ? q.eq('id', String(item.brand_id)) : q.eq('normalized_name', String(item.brand).trim().toLowerCase());
    const b = check(await q.maybeSingle()) as Row | null;
    if (b && (b.support_email || b.support_phone || b.support_url)) {
      body = {
        ...body,
        provider_name: body.provider_name ?? String(b.name),
        provider_contact: Object.fromEntries(Object.entries({ email: b.support_email, phone: b.support_phone, url: b.support_url })
          .filter(([, v]) => v)) as NonNullable<typeof body.provider_contact>,
      };
    }
  }
  const facts = check(await db.rpc('build_claim_facts', { p_item_id: body.item_id, p_warranty_id: body.warranty_id ?? null }));
  const { attachment_ids, ...rest } = body;
  const claim = await Claims(db).insert({
    ...rest,
    user_id: userId,
    item_label: String(item.name),
    provider_contact: body.provider_contact ?? {},
    // Proposed facts — becomes the official snapshot only after the user reviews it.
    snapshot: { proposed: facts },
    status: 'draft',
  });
  if (attachment_ids?.length) {
    await linkRows(db, 'claim_attachments', attachment_ids.map((a, i) => ({ claim_id: claim.id, attachment_id: a, user_id: userId, sort_order: i })));
  }
  await track(userId, 'claim_started', { claim_kind: body.claim_kind });
  return claim;
}

export async function getClaim(db: Db, id: string) {
  const claim = await Claims(db).get(id, 'claim_not_found');
  const [attachments, history, packs, outcome] = await Promise.all([
    db.from('claim_attachments').select('attachment_id, include_in_pack, caption, sort_order, attachments(id, file_type, original_filename, verified_mime_type, page_count)').eq('claim_id', id).order('sort_order'),
    db.from('claim_status_history').select('from_status, to_status, note, created_at').eq('claim_id', id).order('created_at'),
    db.from('claim_packs').select('id, format, pack_level, generated_at, byte_size').eq('claim_id', id).order('generated_at', { ascending: false }),
    db.from('outcomes').select('*').eq('claim_id', id).maybeSingle(),
  ]);
  return { ...claim, attachments: check(attachments), history: check(history), packs: check(packs), outcome: check(outcome) };
}

export async function updateClaim(db: Db, id: string, patch: z.infer<typeof ClaimPatch>, version?: number) {
  const { ai_draft_reviewed, ...rest } = patch;
  const values: Row = { ...rest };
  if (ai_draft_reviewed) values.ai_draft_reviewed_at = new Date().toISOString();
  return Claims(db).update(id, values, version, 'claim_not_found');
}

/** The user reviews and confirms the facts; only then can the claim be marked ready. */
export async function reviewSnapshot(db: Db, id: string, facts: Record<string, unknown>) {
  return Claims(db).update(id, { snapshot: { reviewed: facts, template_version: TEMPLATE_VERSION }, snapshot_reviewed_at: new Date().toISOString() }, undefined, 'claim_not_found');
}

function reviewedFacts(claim: Row): Record<string, any> {
  const snap = claim.snapshot as { reviewed?: Record<string, unknown> } | null;
  if (!claim.snapshot_reviewed_at || !snap?.reviewed) {
    throw unprocessable('snapshot_review_required', 'Review and confirm the claim facts first');
  }
  return snap.reviewed as Record<string, any>;
}

const val = (v: unknown) => (v === null || v === undefined || v === '' ? 'Not recorded' : String(v));

/** Deterministic factual template (no AI). */
export function renderClaimText(claim: Row, facts: Record<string, any>, evidence: Array<{ filename: string; file_type: string; caption?: string | null }>): string {
  const p = facts.product ?? {};
  const pu = facts.purchase ?? {};
  const c = facts.coverage ?? null;
  const lines = [
    `Subject: ${claim.claim_kind === 'return_refund' ? 'Return request' : 'Warranty service request'} — ${val(p.name ?? claim.item_label)}`,
    '',
    'PRODUCT',
    `  Product: ${val(p.name ?? claim.item_label)}`,
    `  Brand: ${val(p.brand)}`,
    `  Model number: ${val(p.model_number)}`,
    `  Serial number: ${val(p.serial_number)}`,
    '',
    'PURCHASE',
    `  Retailer: ${val(pu.retailer)}`,
    `  Order number: ${val(pu.order_number)}`,
    `  Purchase date: ${val(pu.purchase_date)}`,
    `  Delivery date: ${val(pu.delivery_date)}`,
    `  Price paid: ${pu.price ? `${pu.price} ${val(pu.currency)}${pu.price_is_estimated ? ' (estimated allocation from a multi-item receipt)' : ''}` : 'Not recorded'}`,
    '',
  ];
  if (c) {
    lines.push(
      'COVERAGE (as recorded by the customer)',
      `  Type: ${val(c.coverage_type)}  Provider: ${val(c.provider_name)}`,
      `  Term: ${val(c.term_kind)}  Start: ${val(c.start_date)}  End: ${val(c.end_date)}  Date certainty: ${val(c.date_certainty)}`,
      `  Policy number: ${val(c.policy_number)}`,
      c.conditional_terms ? `  Conditions: ${c.conditional_terms}` : '',
      '',
    );
  }
  lines.push(
    'ISSUE',
    `  Started on: ${val(claim.issue_started_on)}`,
    `  Description (customer's words): ${val(claim.issue_description)}`,
    '',
    'EVIDENCE INCLUDED',
    ...(evidence.length ? evidence.map((e, i) => `  ${i + 1}. ${e.file_type}: ${e.filename}${e.caption ? ` — ${e.caption}` : ''}`) : ['  None attached']),
    '',
    'REQUEST',
    '  Please let me know whether this product is eligible for service under the applicable terms, and what the next steps are.',
    '',
    DISCLAIMER,
  );
  return lines.filter((l) => l !== '').join('\n').replace(/\n(PRODUCT|PURCHASE|COVERAGE|ISSUE|EVIDENCE|REQUEST)/g, '\n\n$1');
}

function textToPdf(text: string, title: string): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const doc = new PDFKit({ size: 'LETTER', margin: 54, info: { Title: title, Producer: 'Warrantra' } });
    const chunks: Buffer[] = [];
    doc.on('data', (c: Buffer) => chunks.push(c));
    doc.on('end', () => resolve(Buffer.concat(chunks)));
    doc.on('error', reject);
    doc.fontSize(16).text(title);
    doc.moveDown(0.5).fontSize(10).fillColor('#444').text(`Generated ${new Date().toISOString().slice(0, 10)} · ${TEMPLATE_VERSION}`);
    doc.moveDown().fillColor('#000').fontSize(11);
    for (const line of text.split('\n')) {
      if (/^[A-Z ()]+$/.test(line.trim()) && line.trim().length > 2) doc.moveDown(0.4).font('Helvetica-Bold').text(line.trim()).font('Helvetica');
      else doc.text(line);
    }
    doc.end();
  });
}

export async function generatePack(db: Db, userId: string, claimId: string, format: 'text' | 'pdf') {
  const claim = await Claims(db).get(claimId, 'claim_not_found');
  const facts = reviewedFacts(claim);
  const svc = serviceClient();
  const limits = check(await svc.rpc('get_plan_limits_for_user', { p_user_id: userId })) as Row;
  const level = limits.claim_pack_level === 'assembled' ? 'assembled' : 'basic';

  const links = check(await db.from('claim_attachments')
    .select('caption, sort_order, include_in_pack, attachments(id, storage_path, file_type, original_filename, verified_mime_type, processing_state)')
    .eq('claim_id', claimId).eq('include_in_pack', true).order('sort_order')) as unknown as Array<Row & { attachments: Row }>;
  const evidence = links.filter((l) => l.attachments?.processing_state === 'ready');
  const text = renderClaimText(claim, facts, evidence.map((l) => ({
    filename: String(l.attachments.original_filename ?? 'document'), file_type: String(l.attachments.file_type), caption: l.caption as string | null,
  })));

  let bytes: Buffer;
  let contentType: string;
  if (format === 'text') {
    bytes = Buffer.from(text, 'utf8');
    contentType = 'text/plain';
  } else {
    let pdf = await textToPdf(text, `Claim information — ${claim.item_label}`);
    if (level === 'assembled' && evidence.length) {
      // Assembled evidence package: append chosen originals (PDF pages / JPEG / PNG).
      const out = await PDFDocument.load(pdf);
      for (const l of evidence) {
        const a = l.attachments;
        const dl = await svc.storage.from(BUCKETS.files).download(String(a.storage_path));
        if (dl.error || !dl.data) continue;
        const buf = Buffer.from(await dl.data.arrayBuffer());
        if (a.verified_mime_type === 'application/pdf') {
          const src = await PDFDocument.load(buf);
          (await out.copyPages(src, src.getPageIndices())).forEach((p) => out.addPage(p));
        } else if (a.verified_mime_type === 'image/jpeg' || a.verified_mime_type === 'image/png') {
          const img = a.verified_mime_type === 'image/png' ? await out.embedPng(buf) : await out.embedJpg(buf);
          const page = out.addPage([612, 792]);
          const scale = Math.min(540 / img.width, 700 / img.height, 1);
          page.drawImage(img, { x: 36, y: 792 - 54 - img.height * scale, width: img.width * scale, height: img.height * scale });
        }
      }
      pdf = Buffer.from(await out.save());
    }
    bytes = pdf;
    contentType = 'application/pdf';
  }

  const packId = crypto.randomUUID();
  const path = `${userId}/${claimId}/${packId}.${format === 'pdf' ? 'pdf' : 'txt'}`;
  const up = await svc.storage.from(BUCKETS.claimPacks).upload(path, bytes, { contentType, upsert: false });
  if (up.error) throw new AppError(502, 'storage_error', 'Could not store the claim package');
  check(await svc.from('claim_packs').insert({
    id: packId, claim_id: claimId, user_id: userId, format, pack_level: level, template_version: TEMPLATE_VERSION,
    storage_path: path, content_sha256: sha256Hex(bytes), byte_size: bytes.length,
  }));
  const ttl = Number(await getSetting('signed_url_ttl_seconds', 300));
  const signed = await svc.storage.from(BUCKETS.claimPacks).createSignedUrl(path, ttl, { download: `claim-${claimId.slice(0, 8)}.${format === 'pdf' ? 'pdf' : 'txt'}` });
  await track(userId, 'claim_pack_exported', { format, pack_level: level });
  return {
    pack_id: packId, format, pack_level: level, text: format === 'text' ? text : undefined,
    url: signed.data?.signedUrl ?? null, expires_in_seconds: ttl,
    note: 'Review the package and send it to the provider yourself. Opening an email app is not submission.',
  };
}

/** Optional, bounded AI draft (Pro). Counts as one AI action; failure releases it. */
export async function aiDraft(db: Db, userId: string, claimId: string, idempotencyKey: string) {
  const svc = serviceClient();
  const limits = check(await svc.rpc('get_plan_limits_for_user', { p_user_id: userId })) as Row;
  if (!limits.ai_claim_draft) throw new AppError(402, 'plan_required', 'AI claim drafts are part of Pro');
  const claim = await Claims(db).get(claimId, 'claim_not_found');
  const facts = reviewedFacts(claim);
  const issue = String(claim.issue_description ?? '');
  if (issue.length > 2000) {
    throw unprocessable('issue_too_long_for_ai', 'Shorten the issue description to 2,000 characters for an AI draft. The factual template has no limit.');
  }
  const reservation = check(await db.rpc('reserve_ai_action', { p_idempotency_key: `claim:${idempotencyKey}`, p_source_type: 'claim_draft', p_source_id: claimId })) as Row;
  if (reservation.state === 'settled' && claim.ai_draft_text) {
    return { draft: claim.ai_draft_text, reused: true };
  }
  const job = check(await svc.from('scan_jobs').upsert({
    user_id: userId, idempotency_key: `claim-${idempotencyKey}`.slice(0, 128), feature: 'claim_draft', input_kind: 'claim',
    input_claim_id: claimId, state: 'processing', usage_reservation_id: reservation.id, quota_period: reservation.quota_period,
    prompt_version: CLAIM_DRAFT_PROMPT_VERSION, provider: env().AI_PROVIDER, model: env().AI_MODEL, attempts: 1, started_at: new Date().toISOString(),
  }, { onConflict: 'user_id,idempotency_key' }).select('*').single()) as Row;

  // Moderation before any generation (free). Flagged input releases the allowance but is an abuse signal.
  const mod = await moderate(issue).catch(() => ({ flagged: false, categories: [] as string[] }));
  if (mod.flagged) {
    await svc.rpc('worker_release_usage', { p_reservation_id: reservation.id, p_reason: 'moderation_flagged' });
    await svc.from('scan_jobs').update({ state: 'rejected', error_code: 'moderation_flagged', completed_at: new Date().toISOString() }).eq('id', job.id as string);
    await recordAbuseSignal(userId);
    throw unprocessable('content_not_allowed', 'The issue description cannot be used for an AI draft. You can still export the factual template.');
  }

  const prompt = `<facts>\n${JSON.stringify(facts).slice(0, 12_000)}\n</facts>\n<issue>\n${String(claim.issue_description).slice(0, 5000)}\n</issue>\n` +
    `Claim type: ${claim.claim_kind}. Provider: ${claim.provider_name ?? '[provider name]'}.`;
  try {
    const { text, usage } = await generateText({ system: CLAIM_DRAFT_SYSTEM, prompt, maxTokens: env().AI_CLAIM_DRAFT_MAX_TOKENS });
    if (!isClaimLetter(text)) {
      // Paid call, wrong purpose: counts as used and is an abuse signal.
      await svc.from('usage_events').insert({ user_id: userId, scan_job_id: job.id, feature: 'claim_draft', provider: usage.provider, model: usage.model,
        prompt_version: CLAIM_DRAFT_PROMPT_VERSION, input_tokens: usage.inputTokens, output_tokens: usage.outputTokens, cost_usd: usage.costUsd,
        outcome: 'invalid_output', latency_ms: usage.latencyMs, plan_code: reservation.plan_code });
      await svc.rpc('worker_settle_usage', { p_reservation_id: reservation.id });
      await svc.from('scan_jobs').update({ state: 'rejected', error_code: 'off_topic_draft', actual_cost_usd: usage.costUsd, completed_at: new Date().toISOString() })
        .eq('id', job.id as string);
      await recordAbuseSignal(userId);
      throw unprocessable('off_topic_draft', 'AI drafts are only for describing a problem with this product. Edit the issue description and try again.');
    }
    await svc.from('usage_events').insert({ user_id: userId, scan_job_id: job.id, feature: 'claim_draft', provider: usage.provider, model: usage.model,
      prompt_version: CLAIM_DRAFT_PROMPT_VERSION, input_tokens: usage.inputTokens, output_tokens: usage.outputTokens, cost_usd: usage.costUsd,
      outcome: 'success', latency_ms: usage.latencyMs, plan_code: reservation.plan_code });
    await svc.rpc('worker_settle_usage', { p_reservation_id: reservation.id });
    await svc.from('scan_jobs').update({ state: 'succeeded', actual_cost_usd: usage.costUsd, input_tokens: usage.inputTokens,
      output_tokens: usage.outputTokens, completed_at: new Date().toISOString() }).eq('id', job.id as string);
    await svc.from('claims').update({ ai_draft_text: text.slice(0, 8000), ai_draft_job_id: job.id, ai_draft_reviewed_at: null })
      .eq('id', claimId).eq('user_id', userId);
    return { draft: text, label: 'AI-assisted draft — check every statement before sending.', reused: false };
  } catch (err) {
    if (err instanceof AppError) throw err;
    const code = err instanceof AiProviderError ? err.code : 'provider_error';
    await svc.rpc('worker_release_usage', { p_reservation_id: reservation.id, p_reason: code });
    await svc.from('scan_jobs').update({ state: 'failed', error_code: code, completed_at: new Date().toISOString() }).eq('id', job.id as string);
    throw new AppError(503, 'ai_draft_failed', 'The AI draft could not be generated. Your allowance was not used; the factual template is still available.');
  }
}

/** A claim draft must look like a short claim letter, not arbitrary generated content. */
export function isClaimLetter(text: string): boolean {
  const t = text.trim();
  if (!t || /^OFF_TOPIC\b/.test(t)) return false;
  if (!/^Subject:/i.test(t)) return false;
  const words = t.split(/\s+/).length;
  if (words > 400) return false;
  if (/```|<script|<\/?html|def |function\s*\(|SELECT\s+.+\s+FROM/i.test(t)) return false;
  return true;
}

export async function signedPackUrl(db: Db, packId: string) {
  const pack = check(await db.from('claim_packs').select('id, storage_path, format').eq('id', packId).maybeSingle()) as Row | null;
  if (!pack) throw notFound('pack_not_found');
  const ttl = Number(await getSetting('signed_url_ttl_seconds', 300));
  const signed = await serviceClient().storage.from(BUCKETS.claimPacks).createSignedUrl(String(pack.storage_path), ttl);
  if (signed.error) throw new AppError(502, 'storage_error', 'Could not create link');
  return { url: signed.data.signedUrl, expires_in_seconds: ttl };
}

// ---------------------------------------------------------------------------
// Outcome ledger
// ---------------------------------------------------------------------------
export async function recordOutcome(db: Db, userId: string, body: z.infer<typeof OutcomeBody>) {
  if (Boolean(body.claim_id) === Boolean(body.return_window_id)) throw unprocessable('outcome_requires_exactly_one_case');
  if (body.amount && !body.currency) throw unprocessable('currency_required');
  const row = check(await db.from('outcomes').insert({ ...body, user_id: userId }).select('*').single()) as Row;
  if (body.claim_id) {
    const status = { refund_received: 'resolved', repair_completed: 'resolved', replacement_received: 'resolved', denied: 'denied', withdrawn: 'withdrawn' }[body.outcome_type];
    await db.from('claims').update({ status }).eq('id', body.claim_id);
  }
  await track(userId, 'outcome_recorded', { outcome_type: body.outcome_type, evidence_level: body.evidence_level });
  await audit({ actorType: 'user', actorId: userId, action: 'outcome.recorded', targetType: 'outcome', targetId: String(row.id) });
  return row;
}

export async function outcomeSummary(db: Db) {
  const rows = check(await db.from('outcomes').select('outcome_type, amount, currency, evidence_level')) as Row[];
  const byType: Record<string, number> = {};
  const recovered: Record<string, number> = {};
  for (const r of rows) {
    byType[String(r.outcome_type)] = (byType[String(r.outcome_type)] ?? 0) + 1;
    if (r.outcome_type === 'refund_received' && r.amount && r.currency) {
      recovered[String(r.currency)] = Math.round(((recovered[String(r.currency)] ?? 0) + Number(r.amount)) * 100) / 100;
    }
  }
  return {
    outcomes_by_type: byType,
    refunds_reported: recovered,
    note: 'Totals reflect refunds you reported. Purchase values are not counted as "money saved".',
  };
}

export function assertOwner(claim: Row, userId: string) {
  if (claim.user_id !== userId) throw forbidden();
}
