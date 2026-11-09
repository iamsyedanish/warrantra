/** Accounts, identity, profile, devices, entitlements, usage, consent, deletion. */
import type { Request, Response } from 'express';
import { authOf } from '../middleware/auth.js';
import { check } from '../lib/errors.js';
import { parseOrThrow } from '../lib/http.js';
import { serviceClient } from '../lib/supabase.js';
import { Profiles } from '../models/index.js';
import * as auth from '../services/auth.service.js';
import * as billing from '../services/billing/billing.service.js';
import * as deletion from '../services/deletion.service.js';
import * as exporter from '../services/export.service.js';
import { deviceView, entitlementView, list, one } from '../views/index.js';
import * as V from '../validators/index.js';

export const AuthController = {
  signUp: async (req: Request, res: Response) => {
    res.status(201).json(one(await auth.signUp(parseOrThrow(V.SignUpBody, req.body, 'body'))));
  },
  signIn: async (req: Request, res: Response) => {
    const b = parseOrThrow(V.SignInBody, req.body, 'body');
    res.json(one(await auth.signInWithPassword(b.email, b.password)));
  },
  signInWithIdToken: async (req: Request, res: Response) => {
    res.json(one(await auth.signInWithIdToken(parseOrThrow(V.IdTokenBody, req.body, 'body'))));
  },
  refresh: async (req: Request, res: Response) => {
    res.json(one(await auth.refresh(parseOrThrow(V.RefreshBody, req.body, 'body').refresh_token)));
  },
  signOut: async (req: Request, res: Response) => {
    const scope = req.query.scope === 'global' ? 'global' : 'local';
    res.json(one(await auth.signOut(authOf(req).token, scope)));
  },
  passwordReset: async (req: Request, res: Response) => {
    res.status(202).json(one(await auth.sendPasswordReset(parseOrThrow(V.EmailBody, req.body, 'body').email)));
  },
  updatePassword: async (req: Request, res: Response) => {
    res.json(one(await auth.updatePassword(authOf(req).userId, parseOrThrow(V.PasswordUpdateBody, req.body, 'body').password)));
  },
  identities: async (req: Request, res: Response) => {
    res.json(list(await auth.listIdentities(authOf(req).userId)));
  },
  linkIntent: async (req: Request, res: Response) => {
    const a = authOf(req);
    res.status(201).json(one(await auth.requestIdentityLink(a.db, a.userId, parseOrThrow(V.LinkIntentBody, req.body, 'body').provider)));
  },
};

export const MeController = {
  get: async (req: Request, res: Response) => {
    const a = authOf(req);
    const [profile, entitlement, usage] = await Promise.all([
      Profiles(a.db).get(a.userId),
      a.db.rpc('get_my_entitlement'),
      a.db.rpc('get_my_usage'),
    ]);
    res.json(one({ profile, entitlement: entitlementView(check(entitlement) as Record<string, unknown>), usage: check(usage) }));
  },
  update: async (req: Request, res: Response) => {
    const a = authOf(req);
    const patch = parseOrThrow(V.ProfilePatch, req.body, 'body');
    if (patch.notification_preferences) {
      // Merge with existing preferences so partial updates do not erase other blocks.
      const current = (await Profiles(a.db).get(a.userId)).notification_preferences as Record<string, unknown>;
      patch.notification_preferences = { ...current, ...patch.notification_preferences } as typeof patch.notification_preferences;
    }
    res.json(one(await Profiles(a.db).update(a.userId, patch)));
  },
  aiConsent: async (req: Request, res: Response) => {
    const b = parseOrThrow(V.AiConsentBody, req.body, 'body');
    res.json(one({
      ...(await auth.recordAiConsent(authOf(req).userId, b.granted, b.consent_version)),
      disclosure: 'When you use AI extraction, the selected receipt image/PDF or text is sent to our AI provider (Anthropic) to read it. ' +
        'It is not used to make decisions about you. Manual entry never shares data with an AI provider.',
    }));
  },
  entitlement: async (req: Request, res: Response) => {
    res.json(one(entitlementView(check(await authOf(req).db.rpc('get_my_entitlement')) as Record<string, unknown>)));
  },
  usage: async (req: Request, res: Response) => {
    res.json(one(check(await authOf(req).db.rpc('get_my_usage'))));
  },
  annualSummary: async (req: Request, res: Response) => {
    const year = Number(req.query.year ?? new Date().getUTCFullYear());
    if (!Number.isInteger(year) || year < 2000 || year > 2100) {
      res.status(400).json({ error: { code: 'invalid_year', message: 'Use a four-digit year', request_id: req.id } });
      return;
    }
    res.json(one(check(await authOf(req).db.rpc('get_annual_summary', { p_year: year }))));
  },
  restorePurchases: async (req: Request, res: Response) => {
    const a = authOf(req);
    await billing.restore(a.userId);
    res.json(one(entitlementView(check(await a.db.rpc('get_my_entitlement')) as Record<string, unknown>)));
  },
  registerDevice: async (req: Request, res: Response) => {
    const b = parseOrThrow(V.DeviceBody, req.body, 'body');
    const row = check(await authOf(req).db.rpc('register_device', {
      p_installation_id: b.installation_id, p_platform: b.platform, p_push_token: b.push_token ?? null,
      p_permission_state: b.permission_state, p_app_version: b.app_version ?? null, p_locale: b.locale ?? null, p_timezone: b.timezone ?? null,
    })) as Record<string, unknown>;
    res.json(one(deviceView(row)));
  },
  listDevices: async (req: Request, res: Response) => {
    res.json(list(check(await authOf(req).db.from('devices').select('id, installation_id, platform, permission_state, token_state, app_version, last_seen_at'))));
  },
  removeDevice: async (req: Request, res: Response) => {
    check(await authOf(req).db.from('devices').delete().eq('id', String(req.params.id)));
    res.status(204).end();
  },
  // --- export (never paywalled) ---
  requestExport: async (req: Request, res: Response) => {
    const a = authOf(req);
    const includeFiles = req.body?.include_files !== false;
    const workspaceId = typeof req.body?.workspace_id === 'string' ? req.body.workspace_id : undefined;
    res.status(202).json(one(await exporter.requestExport(a.db, a.userId, { includeFiles, workspaceId })));
  },
  listExports: async (req: Request, res: Response) => {
    res.json(list(check(await authOf(req).db.from('export_jobs').select('id, scope, state, item_count, file_count, requested_at, completed_at, expires_at')
      .order('requested_at', { ascending: false }).limit(20))));
  },
  exportLinks: async (req: Request, res: Response) => {
    res.json(one(await exporter.exportLinks(authOf(req).db, String(req.params.id))));
  },
  // --- deletion ---
  requestDeletion: async (req: Request, res: Response) => {
    res.status(202).json(one(await deletion.requestDeletion(authOf(req).userId, 'in_app')));
  },
  confirmDeletion: async (req: Request, res: Response) => {
    parseOrThrow(V.DeletionConfirmBody, req.body, 'body');
    res.status(202).json(one(await deletion.confirmDeletion(authOf(req).userId)));
  },
  cancelDeletion: async (req: Request, res: Response) => {
    res.json(one(await deletion.cancelDeletion(authOf(req).userId)));
  },
  deletionStatus: async (req: Request, res: Response) => {
    res.json(list(check(await authOf(req).db.from('deletion_requests').select('id, source, state, created_at, completed_at').order('created_at', { ascending: false }).limit(5))));
  },
};

export const PublicController = {
  webDeletionStart: async (req: Request, res: Response) => {
    res.status(202).json(one(await deletion.startWebDeletion(parseOrThrow(V.EmailBody, req.body, 'body').email)));
  },
  webDeletionVerify: async (req: Request, res: Response) => {
    res.json(one(await deletion.verifyWebDeletion(parseOrThrow(V.WebDeletionVerifyBody, req.body, 'body').token)));
  },
  retention: async (_req: Request, res: Response) => {
    res.json(list(check(await serviceClient().from('retention_policies').select('data_class, retention_days, description, published_at').order('data_class'))));
  },
  plans: async (_req: Request, res: Response) => {
    const rows = check(await serviceClient().from('plan_limits').select('plan_code, version, max_items, storage_bytes, ai_actions_per_month, ai_lifetime_trial_actions, max_file_bytes, max_pdf_pages_stored, max_ai_pages_per_action, claim_pack_level, ai_claim_draft, workspaces_enabled, max_workspace_members, email_forwarding_enabled')
      .is('effective_to', null).in('plan_code', ['free', 'pro']).order('plan_code'));
    res.json(list(rows as unknown[], undefined, { note: 'Allowances are proposed operating controls. Failed AI actions do not use allowance; archived items still count.' }));
  },
};
