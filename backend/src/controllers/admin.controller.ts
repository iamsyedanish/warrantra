/**
 * Restricted administration. Every route requires an active admin_users row,
 * the right role and (by default) MFA; every mutation is audited. Admins see
 * operational metadata, not receipt contents, serial numbers or documents.
 */
import type { Request, Response } from 'express';
import { z } from 'zod';
import { check, forbidden, notFound } from '../lib/errors.js';
import { PaginationQuery, parseOrThrow } from '../lib/http.js';
import { serviceClient } from '../lib/supabase.js';
import { hasRank } from '../middleware/admin.js';
import * as backup from '../services/backup.service.js';
import * as billing from '../services/billing/billing.service.js';
import { audit, enqueueJob } from '../services/ops.service.js';
import { computeProfit, PLANNING_CASE } from '../services/profitability/calculator.js';
import { computeSnapshot } from '../services/profitability/profitability.service.js';
import { list, one } from '../views/index.js';
import { Uuid } from '../validators/index.js';

const svc = () => serviceClient();
const adminId = (req: Request) => req.admin!.userId;
const id = (req: Request) => parseOrThrow(z.object({ id: Uuid }), req.params, 'params').id;
const act = (req: Request, action: string, targetType?: string, targetId?: string, metadata?: Record<string, unknown>) =>
  audit({ actorType: 'admin', actorId: adminId(req), action, targetType, targetId, metadata, ip: req.ip });

const REFERENCE_TABLES = ['warranty_reference', 'return_policy_reference', 'card_benefits', 'brands', 'categories'] as const;

export const AdminController = {
  // ---- health & jobs ----
  health: async (_req: Request, res: Response) => {
    const s = svc();
    const [reminders, failedJobs, deadJobs, heartbeats, pendingBilling, deletionsStuck] = await Promise.all([
      s.rpc('reminder_health'),
      s.from('jobs').select('id', { count: 'exact', head: true }).eq('state', 'failed'),
      s.from('jobs').select('id', { count: 'exact', head: true }).eq('state', 'dead'),
      s.from('worker_heartbeats').select('*'),
      s.from('billing_events').select('id', { count: 'exact', head: true }).in('processing_state', ['received', 'failed']),
      s.from('deletion_requests').select('id', { count: 'exact', head: true }).not('state', 'in', '(completed,cancelled,requested)')
        .lt('updated_at', new Date(Date.now() - 6 * 3600_000).toISOString()),
    ]);
    res.json(one({
      reminders: check(reminders), jobs: { failed: failedJobs.count ?? 0, dead: deadJobs.count ?? 0 },
      workers: check(heartbeats), billing_unprocessed: pendingBilling.count ?? 0, deletions_stuck_6h: deletionsStuck.count ?? 0,
      ai_spend_month_usd: check(await s.rpc('get_ai_month_spend', { p_user_id: null })),
    }));
  },
  jobs: async (req: Request, res: Response) => {
    const q = parseOrThrow(PaginationQuery.extend({ state: z.enum(['queued', 'running', 'succeeded', 'failed', 'dead', 'cancelled']).optional(), kind: z.string().max(40).optional() }), req.query, 'query');
    let query = svc().from('jobs').select('id, kind, state, attempts, max_attempts, run_at, last_error, user_id, created_at, updated_at').order('updated_at', { ascending: false });
    if (q.state) query = query.eq('state', q.state);
    if (q.kind) query = query.eq('kind', q.kind);
    res.json(list(check(await query.range(q.offset, q.offset + q.limit - 1)) as unknown[], q));
  },
  retryJob: async (req: Request, res: Response) => {
    const row = check(await svc().from('jobs').update({ state: 'queued', run_at: new Date().toISOString(), attempts: 0 }).eq('id', id(req)).in('state', ['failed', 'dead']).select('id').maybeSingle());
    if (!row) throw notFound('job_not_retryable');
    await act(req, 'admin.job_retried', 'job', id(req));
    res.json(one(row));
  },
  cancelJob: async (req: Request, res: Response) => {
    check(await svc().from('jobs').update({ state: 'cancelled' }).eq('id', id(req)).in('state', ['queued', 'failed', 'dead']));
    await act(req, 'admin.job_cancelled', 'job', id(req));
    res.json(one({ cancelled: true }));
  },
  failedDeliveries: async (req: Request, res: Response) => {
    const p = parseOrThrow(PaginationQuery, req.query, 'query');
    res.json(list(check(await svc().from('notification_deliveries').select('id, user_id, reminder_id, channel, provider, error_code, attempt_count, failed_at')
      .eq('state', 'failed').order('failed_at', { ascending: false }).range(p.offset, p.offset + p.limit - 1)) as unknown[], p));
  },
  failedScans: async (req: Request, res: Response) => {
    const p = parseOrThrow(PaginationQuery, req.query, 'query');
    res.json(list(check(await svc().from('scan_jobs').select('id, user_id, feature, state, error_code, attempts, model, prompt_version, created_at')
      .eq('state', 'failed').order('created_at', { ascending: false }).range(p.offset, p.offset + p.limit - 1)) as unknown[], p));
  },

  // ---- users (minimal metadata, no documents) ----
  userLookup: async (req: Request, res: Response) => {
    const userId = id(req);
    const s = svc();
    const [profile, entitlements, usage, counts, deletions, events] = await Promise.all([
      s.from('profiles').select('id, created_at, country_code, timezone, account_state, onboarding_completed, ai_processing_consent_at').eq('id', userId).maybeSingle(),
      s.from('entitlements').select('entitlement_key, environment, state, renewal_intent, valid_until, grace_until, store, product_id, last_reconciled_at').eq('user_id', userId),
      s.from('usage_ledger').select('feature, quantity, state, quota_period, reserved_at').eq('user_id', userId).order('reserved_at', { ascending: false }).limit(50),
      s.from('items').select('id', { count: 'exact', head: true }).eq('user_id', userId),
      s.from('deletion_requests').select('id, state, source, created_at, completed_at, last_error').eq('user_id', userId),
      s.from('billing_events').select('id, event_type, environment, processing_state, event_timestamp').eq('user_id', userId).order('event_timestamp', { ascending: false }).limit(25),
    ]);
    if (!check(profile)) {
      const tomb = await s.from('deletion_tombstones').select('completed_at').eq('user_id', userId).maybeSingle();
      if (tomb.data) return res.json(one({ deleted: true, completed_at: tomb.data.completed_at }));
      throw notFound('user_not_found');
    }
    await act(req, 'admin.user_viewed', 'user', userId);
    res.json(one({ profile: check(profile), entitlements: check(entitlements), usage: check(usage), item_count: counts.count ?? 0,
      deletion_requests: check(deletions), billing_events: check(events) }));
  },
  reconcileUser: async (req: Request, res: Response) => {
    const r = await billing.reconcileUser(id(req));
    await act(req, 'admin.entitlement_reconciled', 'user', id(req));
    res.json(one(r));
  },
  grantPromotional: async (req: Request, res: Response) => {
    if (!hasRank(req.admin!.role, 'operator')) throw forbidden('admin_role_insufficient');
    const b = parseOrThrow(z.strictObject({ days: z.number().int().min(1).max(366), reason: z.string().min(3).max(300) }), req.body, 'body');
    const until = new Date(Date.now() + b.days * 86_400_000).toISOString();
    const row = check(await svc().from('entitlements').upsert({
      user_id: id(req), entitlement_key: 'pro', environment: 'PRODUCTION', state: 'active', renewal_intent: 'will_not_renew',
      valid_from: new Date().toISOString(), valid_until: until, store: 'promotional', reconciliation_source: 'admin', last_reconciled_at: new Date().toISOString(),
    }, { onConflict: 'user_id,entitlement_key,environment' }).select('*').single());
    await act(req, 'admin.promotional_granted', 'user', id(req), { days: b.days, reason: b.reason });
    res.json(one(row));
  },

  // ---- audit, settings, plan limits ----
  auditLog: async (req: Request, res: Response) => {
    const q = parseOrThrow(PaginationQuery.extend({ target_id: z.string().max(64).optional(), actor_id: Uuid.optional(), action: z.string().max(80).optional() }), req.query, 'query');
    let query = svc().from('audit_events').select('*').order('created_at', { ascending: false });
    if (q.target_id) query = query.eq('target_id', q.target_id);
    if (q.actor_id) query = query.eq('actor_id', q.actor_id);
    if (q.action) query = query.eq('action', q.action);
    res.json(list(check(await query.range(q.offset, q.offset + q.limit - 1)) as unknown[], q));
  },
  settings: async (_req: Request, res: Response) => res.json(list(check(await svc().from('system_settings').select('*').order('key')) as unknown[])),
  setSetting: async (req: Request, res: Response) => {
    if (!hasRank(req.admin!.role, 'operator')) throw forbidden('admin_role_insufficient');
    const key = parseOrThrow(z.object({ key: z.string().max(80) }), req.params, 'params').key;
    const b = parseOrThrow(z.strictObject({ value: z.union([z.boolean(), z.number(), z.string().max(100)]) }), req.body, 'body');
    const row = check(await svc().from('system_settings').update({ value: b.value, updated_at: new Date().toISOString(), updated_by: adminId(req) }).eq('key', key).select('*').maybeSingle());
    if (!row) throw notFound('setting_not_found');
    await act(req, 'admin.setting_changed', 'system_setting', key, { value: b.value });
    res.json(one(row));
  },
  planLimits: async (_req: Request, res: Response) => res.json(list(check(await svc().from('plan_limits').select('*').order('plan_code').order('version')) as unknown[])),
  newPlanVersion: async (req: Request, res: Response) => {
    if (!hasRank(req.admin!.role, 'superadmin')) throw forbidden('admin_role_insufficient');
    const b = parseOrThrow(z.object({ plan_code: z.enum(['free', 'pro', 'business_pilot']) }).passthrough(), req.body, 'body') as Record<string, unknown> & { plan_code: string };
    const s = svc();
    const current = check(await s.from('plan_limits').select('*').eq('plan_code', b.plan_code).is('effective_to', null).order('version', { ascending: false }).limit(1).single()) as Record<string, unknown>;
    const now = new Date().toISOString();
    const { id: _i, created_at: _c, ...base } = current;
    const allowed = ['max_items', 'storage_bytes', 'ai_actions_per_month', 'ai_lifetime_trial_actions', 'max_file_bytes', 'max_pdf_pages_stored',
      'max_ai_pages_per_action', 'max_ai_input_chars', 'claim_pack_level', 'ai_claim_draft', 'workspaces_enabled', 'max_workspace_members',
      'business_portfolio_enabled', 'email_forwarding_enabled', 'notes'];
    const changes = Object.fromEntries(Object.entries(b).filter(([k]) => allowed.includes(k)));
    check(await s.from('plan_limits').update({ effective_to: now }).eq('id', current.id as string));
    const row = check(await s.from('plan_limits').insert({ ...base, ...changes, version: Number(current.version) + 1, effective_from: now, effective_to: null }).select('*').single());
    await act(req, 'admin.plan_limits_versioned', 'plan_limits', b.plan_code, changes);
    res.status(201).json(one(row, { note: 'Downgrades never delete data; additions beyond the new limit pause.' }));
  },

  // ---- support ----
  tickets: async (req: Request, res: Response) => {
    const q = parseOrThrow(PaginationQuery.extend({ status: z.enum(['open', 'pending_user', 'resolved', 'closed']).optional() }), req.query, 'query');
    let query = svc().from('support_tickets').select('*').order('created_at', { ascending: false });
    if (q.status) query = query.eq('status', q.status);
    res.json(list(check(await query.range(q.offset, q.offset + q.limit - 1)) as unknown[], q));
  },
  ticket: async (req: Request, res: Response) => {
    const s = svc();
    const t = check(await s.from('support_tickets').select('*').eq('id', id(req)).maybeSingle());
    if (!t) throw notFound('ticket_not_found');
    res.json(one({ ...(t as object), messages: check(await s.from('support_messages').select('*').eq('ticket_id', id(req)).order('created_at')) }));
  },
  replyTicket: async (req: Request, res: Response) => {
    const b = parseOrThrow(z.strictObject({ message: z.string().min(1).max(10_000), internal: z.boolean().default(false),
      status: z.enum(['open', 'pending_user', 'resolved', 'closed']).optional(), support_minutes: z.number().int().min(0).max(600).optional() }), req.body, 'body');
    const s = svc();
    check(await s.from('support_messages').insert({ ticket_id: id(req), author_type: 'staff', author_id: adminId(req), body: b.message, internal: b.internal }));
    const t = check(await s.from('support_tickets').select('support_minutes').eq('id', id(req)).single()) as { support_minutes: number };
    await s.from('support_tickets').update({ status: b.status ?? 'pending_user', assigned_to: adminId(req),
      support_minutes: t.support_minutes + (b.support_minutes ?? 0) }).eq('id', id(req));
    await act(req, 'admin.ticket_replied', 'support_ticket', id(req), { internal: b.internal });
    res.status(201).json(one({ replied: true }));
  },

  // ---- reference data with review workflow ----
  listReference: async (req: Request, res: Response) => {
    const table = parseOrThrow(z.object({ table: z.enum(REFERENCE_TABLES) }), req.params, 'params').table;
    res.json(list(check(await svc().from(table).select('*').limit(500)) as unknown[]));
  },
  upsertReference: async (req: Request, res: Response) => {
    const table = parseOrThrow(z.object({ table: z.enum(REFERENCE_TABLES) }), req.params, 'params').table;
    const body = parseOrThrow(z.record(z.string(), z.unknown()), req.body, 'body');
    // Writes always enter as drafts; publishing is a separate reviewed step.
    if ('review_status' in body && table !== 'brands' && table !== 'categories') body.review_status = 'draft';
    const row = check(await svc().from(table).upsert(body).select('*').single()) as Record<string, unknown>;
    await act(req, 'admin.reference_upserted', table, String(row.id));
    res.status(201).json(one(row));
  },
  reviewReference: async (req: Request, res: Response) => {
    const p = parseOrThrow(z.object({ table: z.enum(['warranty_reference', 'return_policy_reference', 'card_benefits']), id: Uuid }), req.params, 'params');
    const b = parseOrThrow(z.strictObject({ action: z.enum(['submitted', 'approved', 'rejected', 'retired', 'verified']), notes: z.string().max(2000).optional(),
      next_review_due: z.string().optional() }), req.body, 'body');
    const s = svc();
    const status = { submitted: 'in_review', approved: 'published', rejected: 'draft', retired: 'retired', verified: undefined }[b.action];
    const patch: Record<string, unknown> = { reviewed_by: adminId(req), reviewed_at: new Date().toISOString() };
    if (status) patch.review_status = status;
    if (b.action === 'verified' || b.action === 'approved') patch.last_verified_at = new Date().toISOString();
    if (b.next_review_due) patch.next_review_due = b.next_review_due;
    const current = check(await s.from(p.table).select('reviewed_by, review_status').eq('id', p.id).maybeSingle()) as Record<string, unknown> | null;
    if (!current) throw notFound();
    check(await s.from(p.table).update(patch).eq('id', p.id));
    check(await s.from('reference_reviews').insert({ table_name: p.table, record_id: p.id, action: b.action, reviewer_id: adminId(req), notes: b.notes ?? null }));
    await act(req, 'admin.reference_reviewed', p.table, p.id, { action: b.action });
    res.json(one({ reviewed: true, review_status: status ?? current.review_status }));
  },

  // ---- profitability & analytics ----
  metrics: async (req: Request, res: Response) => {
    const q = parseOrThrow(z.object({ from: z.string().date(), to: z.string().date() }), req.query, 'query');
    res.json(one(check(await svc().rpc('admin_product_metrics', { p_from: q.from, p_to: q.to }))));
  },
  profitSnapshot: async (req: Request, res: Response) => {
    const month = typeof req.query.month === 'string' ? req.query.month : undefined;
    res.json(one(await computeSnapshot(month)));
  },
  profitHistory: async (_req: Request, res: Response) => {
    const s = svc();
    const [snapshots, alerts, cohorts] = await Promise.all([
      s.from('profitability_snapshots').select('*').order('month', { ascending: false }).limit(24),
      s.from('margin_alerts').select('*').is('acknowledged_at', null).order('created_at', { ascending: false }),
      s.from('cohort_metrics').select('*').order('as_of_month', { ascending: false }).limit(200),
    ]);
    res.json(one({ snapshots: check(snapshots), open_alerts: check(alerts), cohorts: check(cohorts) }));
  },
  ackAlert: async (req: Request, res: Response) => {
    check(await svc().from('margin_alerts').update({ acknowledged_at: new Date().toISOString(), acknowledged_by: adminId(req) }).eq('id', id(req)));
    await act(req, 'admin.margin_alert_acknowledged', 'margin_alert', id(req));
    res.json(one({ acknowledged: true }));
  },
  addCost: async (req: Request, res: Response) => {
    const b = parseOrThrow(z.strictObject({
      month: z.string().regex(/^\d{4}-\d{2}-01$/), category: z.string().max(40), amount_usd: z.number().nonnegative(),
      cost_class: z.enum(['fixed', 'variable_paid', 'variable_free']), source: z.enum(['invoice', 'estimate', 'measured']).default('estimate'), notes: z.string().max(500).optional(),
    }), req.body, 'body');
    const row = check(await svc().from('operating_costs').insert({ ...b, created_by: adminId(req) }).select('*').single());
    await act(req, 'admin.cost_added', 'operating_costs', String((row as { id: string }).id));
    res.status(201).json(one(row));
  },
  addAcquisitionSpend: async (req: Request, res: Response) => {
    const b = parseOrThrow(z.strictObject({
      month: z.string().regex(/^\d{4}-\d{2}-01$/), channel: z.enum(['paid_social', 'paid_search', 'creator', 'referral', 'partner', 'discount', 'app_store_ads', 'other']),
      amount_usd: z.number().nonnegative(), includes: z.string().max(300).optional(), notes: z.string().max(500).optional(),
    }), req.body, 'body');
    const row = check(await svc().from('acquisition_spend').insert({ ...b, created_by: adminId(req) }).select('*').single());
    await act(req, 'admin.acquisition_spend_added', 'acquisition_spend', String((row as { id: string }).id));
    res.status(201).json(one(row));
  },
  profitSettings: async (_req: Request, res: Response) => res.json(list(check(await svc().from('profit_model_settings').select('*').order('version', { ascending: false })) as unknown[])),
  newProfitSettings: async (req: Request, res: Response) => {
    if (!hasRank(req.admin!.role, 'finance')) throw forbidden('admin_role_insufficient');
    const s = svc();
    const latest = check(await s.from('profit_model_settings').select('*').order('version', { ascending: false }).limit(1).single()) as Record<string, unknown>;
    const { id: _i, created_at: _c, ...base } = latest;
    const changes = parseOrThrow(z.record(z.string(), z.union([z.number(), z.string()])), req.body, 'body');
    const row = check(await s.from('profit_model_settings').insert({ ...base, ...changes, version: Number(latest.version) + 1 }).select('*').single());
    await act(req, 'admin.profit_settings_versioned', 'profit_model_settings', String(Number(latest.version) + 1), changes);
    res.status(201).json(one(row));
  },
  calculator: async (req: Request, res: Response) => {
    const b = parseOrThrow(z.object({
      annual_price: z.number().positive().optional(), monthly_price: z.number().positive().optional(), platform_fee: z.number().min(0).max(1).default(0.15),
    }).passthrough(), req.body ?? {}, 'body') as Record<string, number | undefined>;
    const monthly = b.monthly_price ?? (b.annual_price ? b.annual_price / 12 : 169.99 / 12);
    const overrides = Object.fromEntries(Object.entries(b).filter(([k]) => k in PLANNING_CASE)) as Partial<typeof PLANNING_CASE>;
    res.json(one({ inputs: { ...PLANNING_CASE, ...overrides, monthlyPrice: monthly, platformFee: b.platform_fee },
      result: computeProfit({ ...PLANNING_CASE, ...overrides, monthlyPrice: monthly, platformFee: b.platform_fee ?? 0.15 }),
      caveat: 'Hypothesis only. Replace assumptions with measured cohort data; this is not a guarantee of profit.' }));
  },

  // ---- backup & restore ----
  backups: async (_req: Request, res: Response) => {
    const s = svc();
    const [runs, drills] = await Promise.all([
      s.from('backup_runs').select('*').order('started_at', { ascending: false }).limit(20),
      s.from('restore_drills').select('*').order('started_at', { ascending: false }).limit(10),
    ]);
    res.json(one({ runs: check(runs), drills: check(drills) }));
  },
  runBackup: async (req: Request, res: Response) => {
    const jobId = await enqueueJob('storage_backup', { mode: 'incremental' }, { dedupeKey: 'storage-backup' });
    await act(req, 'admin.backup_requested', 'job', jobId);
    res.status(202).json(one({ job_id: jobId }));
  },
  runRestoreDrill: async (req: Request, res: Response) => {
    if (!hasRank(req.admin!.role, 'operator')) throw forbidden('admin_role_insufficient');
    const r = await backup.runRestoreDrill({ performedBy: adminId(req) });
    await act(req, 'admin.restore_drill', 'restore_drill', String(r.drill_id), { passed: r.passed });
    res.json(one(r));
  },

  // ---- partners (P2) ----
  partners: async (_req: Request, res: Response) => res.json(list(check(await svc().from('partners').select('*, partner_referral_codes(*)')) as unknown[])),
  upsertPartner: async (req: Request, res: Response) => {
    const b = parseOrThrow(z.strictObject({ id: Uuid.optional(), name: z.string().min(1).max(120), kind: z.enum(['retailer', 'property_manager', 'insurer', 'creator', 'affiliate', 'other']),
      status: z.enum(['prospect', 'pilot', 'active', 'ended']).default('pilot'), contact_email: z.string().email().optional(),
      data_sharing_allowed: z.boolean().default(false), revenue_share_rate: z.number().min(0).max(1).optional(), notes: z.string().max(2000).optional() }), req.body, 'body');
    const row = check(await svc().from('partners').upsert(b).select('*').single());
    await act(req, 'admin.partner_upserted', 'partner', String((row as { id: string }).id));
    res.status(201).json(one(row));
  },
  addReferralCode: async (req: Request, res: Response) => {
    const b = parseOrThrow(z.strictObject({ code: z.string().regex(/^[A-Z0-9_-]{4,32}$/), campaign: z.string().max(80).optional() }), req.body, 'body');
    const row = check(await svc().from('partner_referral_codes').insert({ ...b, partner_id: id(req) }).select('*').single());
    await act(req, 'admin.referral_code_added', 'partner', id(req));
    res.status(201).json(one(row));
  },
  /** Only data covered by an active, explicit user consent — never anything else. */
  consentedShare: async (req: Request, res: Response) => {
    if (!hasRank(req.admin!.role, 'operator')) throw forbidden('admin_role_insufficient');
    const s = svc();
    const partner = check(await s.from('partners').select('id, data_sharing_allowed, status').eq('id', id(req)).maybeSingle()) as Record<string, unknown> | null;
    if (!partner || !partner.data_sharing_allowed) throw forbidden('partner_data_sharing_not_enabled');
    const consents = check(await s.from('partner_consents').select('user_id, scope').eq('partner_id', id(req)).is('revoked_at', null)) as Array<{ user_id: string; scope: string }>;
    const contactIds = consents.filter((c) => c.scope === 'share_contact').map((c) => c.user_id);
    const summaryIds = consents.filter((c) => c.scope === 'share_purchase_summary').map((c) => c.user_id);
    const contacts = contactIds.length ? check(await s.from('profiles').select('id, email, display_name').in('id', contactIds)) : [];
    const summaries = summaryIds.length ? check(await s.from('items').select('user_id, category_id').in('user_id', summaryIds).eq('lifecycle_state', 'owned')) : [];
    await act(req, 'admin.partner_consented_export', 'partner', id(req), { contacts: contactIds.length, summaries: summaryIds.length });
    res.json(one({ contacts, purchase_category_summaries: summaries, note: 'Includes only users with an active consent for each scope.' }));
  },
};
