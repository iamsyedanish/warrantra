/** Support, analytics ingestion, partner consents, webhooks. */
import type { Request, Response } from 'express';
import { z } from 'zod';
import { authOf } from '../middleware/auth.js';
import { check, forbidden } from '../lib/errors.js';
import { parseOrThrow } from '../lib/http.js';
import { serviceClient } from '../lib/supabase.js';
import * as billing from '../services/billing/billing.service.js';
import * as capture from '../services/capture.service.js';
import * as support from '../services/support.service.js';
import { list, one } from '../views/index.js';
import * as V from '../validators/index.js';

const id = (req: Request) => parseOrThrow(z.object({ id: V.Uuid }), req.params, 'params').id;

export const SupportController = {
  open: async (req: Request, res: Response) => {
    res.status(201).json(one(await support.openTicket(authOf(req).userId, parseOrThrow(V.SupportTicketBody, req.body, 'body'))));
  },
  openPublic: async (req: Request, res: Response) => {
    res.status(201).json(one(await support.openPublicTicket(parseOrThrow(V.PublicSupportBody, req.body, 'body'))));
  },
  mine: async (req: Request, res: Response) => res.json(list(await support.myTickets(authOf(req).db) as unknown[])),
  thread: async (req: Request, res: Response) => res.json(one(await support.ticketThread(authOf(req).db, id(req)))),
  reply: async (req: Request, res: Response) => {
    const a = authOf(req);
    res.status(201).json(one(await support.replyAsUser(a.db, a.userId, id(req), parseOrThrow(V.SupportMessageBody, req.body, 'body').message)));
  },
};

export const AnalyticsController = {
  /** Batched client events. Only allow-listed names/properties are stored, and only with consent. */
  ingest: async (req: Request, res: Response) => {
    const a = authOf(req);
    const b = parseOrThrow(V.AnalyticsBatchBody, req.body, 'body');
    const svc = serviceClient();
    const profile = check(await svc.from('profiles').select('analytics_consent').eq('id', a.userId).single()) as { analytics_consent: boolean };
    if (!profile.analytics_consent) return res.status(202).json(one({ accepted: 0, reason: 'analytics_consent_not_given' }));
    const allowed = new Set(((check(await svc.from('analytics_event_types').select('event_name')) as Array<{ event_name: string }>).map((e) => e.event_name)));
    const rows = b.events.filter((e) => allowed.has(e.event_name)).map((e) => ({
      user_id: a.userId, event_name: e.event_name, properties: e.properties ?? {}, platform: b.platform, app_version: b.app_version ?? null, occurred_at: e.occurred_at,
    }));
    if (rows.length) check(await svc.from('analytics_events').insert(rows));
    res.status(202).json(one({ accepted: rows.length, dropped: b.events.length - rows.length }));
  },
};

export const PartnerController = {
  list: async (req: Request, res: Response) => res.json(list(check(await authOf(req).db.from('partners').select('id, name, kind, status')) as unknown[])),
  consents: async (req: Request, res: Response) => res.json(list(check(await authOf(req).db.from('partner_consents').select('*').order('granted_at', { ascending: false })) as unknown[])),
  grant: async (req: Request, res: Response) => {
    const b = parseOrThrow(V.PartnerConsentBody, req.body, 'body');
    res.status(201).json(one(check(await authOf(req).db.rpc('grant_partner_consent', {
      p_partner_id: b.partner_id, p_scope: b.scope, p_consent_text_version: b.consent_text_version,
    }))));
  },
  revoke: async (req: Request, res: Response) => {
    check(await authOf(req).db.rpc('revoke_partner_consent', { p_consent_id: id(req) }));
    res.json(one({ revoked: true }));
  },
};

export const WebhookController = {
  revenuecat: async (req: Request, res: Response) => {
    billing.verifyWebhookAuth(req.header('Authorization'));
    const r = await billing.receiveWebhook(req.body);
    res.status(200).json(r);
  },
  inboundEmail: async (req: Request, res: Response) => {
    capture.verifyInboundAuth(req.header('Authorization'));
    const r = await capture.receiveInbound(req.body);
    // Always 200 so the provider does not retry rejected mail.
    res.status(200).json(r);
  },
  cron: async (req: Request, res: Response) => {
    // Optional HTTP trigger for platforms with external schedulers; authenticated by shared secret.
    const { env } = await import('../config/env.js');
    const { safeEqual } = await import('../lib/crypto.js');
    const secret = env().CRON_SECRET;
    if (!secret || !safeEqual(req.header('X-Cron-Secret') ?? '', secret)) throw forbidden();
    const { runPeriodicTask } = await import('../workers/periodic.js');
    const task = parseOrThrow(z.object({ task: z.string().max(40) }), req.params, 'params').task;
    res.json(one(await runPeriodicTask(task)));
  },
};
