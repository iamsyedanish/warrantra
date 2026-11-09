/** Claims, claim packs, AI drafts, outcomes. */
import type { Request, Response } from 'express';
import { z } from 'zod';
import { authOf } from '../middleware/auth.js';
import { check } from '../lib/errors.js';
import { expectedVersion, idempotencyKey, PaginationQuery, parseOrThrow } from '../lib/http.js';
import * as claims from '../services/claim.service.js';
import { claimView, list, one } from '../views/index.js';
import * as V from '../validators/index.js';

const id = (req: Request) => parseOrThrow(z.object({ id: V.Uuid }), req.params, 'params').id;

export const ClaimController = {
  create: async (req: Request, res: Response) => {
    const a = authOf(req);
    res.status(201).json(one(claimView(await claims.createClaim(a.db, a.userId, parseOrThrow(V.ClaimCreateBody, req.body, 'body')))));
  },
  list: async (req: Request, res: Response) => {
    const p = parseOrThrow(PaginationQuery.extend({ status: z.string().max(30).optional() }), req.query, 'query');
    let q = authOf(req).db.from('claims').select('id, item_id, item_label, claim_kind, status, provider_name, claim_number, follow_up_on, created_at, updated_at')
      .order('created_at', { ascending: false });
    if (p.status) q = q.eq('status', p.status);
    res.json(list(check(await q.range(p.offset, p.offset + p.limit - 1)) as unknown[], p));
  },
  get: async (req: Request, res: Response) => {
    res.json(one(claimView(await claims.getClaim(authOf(req).db, id(req)))));
  },
  update: async (req: Request, res: Response) => {
    res.json(one(claimView(await claims.updateClaim(authOf(req).db, id(req), parseOrThrow(V.ClaimPatch, req.body, 'body'), expectedVersion(req)))));
  },
  remove: async (req: Request, res: Response) => {
    check(await authOf(req).db.from('claims').delete().eq('id', id(req)));
    res.status(204).end();
  },
  proposedFacts: async (req: Request, res: Response) => {
    const claim = (await claims.getClaim(authOf(req).db, id(req))) as Record<string, unknown>;
    res.json(one({ proposed: (claim.snapshot as { proposed?: unknown })?.proposed ?? null, reviewed: (claim.snapshot as { reviewed?: unknown })?.reviewed ?? null,
      instructions: 'Check every fact. Remove anything incorrect; mark unknown items as unknown. Nothing is sent anywhere by Warrantra.' }));
  },
  reviewSnapshot: async (req: Request, res: Response) => {
    res.json(one(claimView(await claims.reviewSnapshot(authOf(req).db, id(req), parseOrThrow(V.ClaimSnapshotBody, req.body, 'body').facts))));
  },
  pack: async (req: Request, res: Response) => {
    const a = authOf(req);
    res.status(201).json(one(await claims.generatePack(a.db, a.userId, id(req), parseOrThrow(V.ClaimPackBody, req.body ?? {}, 'body').format)));
  },
  packUrl: async (req: Request, res: Response) => {
    const packId = parseOrThrow(z.object({ packId: V.Uuid }), req.params, 'params').packId;
    res.json(one(await claims.signedPackUrl(authOf(req).db, packId)));
  },
  aiDraft: async (req: Request, res: Response) => {
    const a = authOf(req);
    res.status(201).json(one(await claims.aiDraft(a.db, a.userId, id(req), idempotencyKey(req)!)));
  },
};

export const OutcomeController = {
  create: async (req: Request, res: Response) => {
    const a = authOf(req);
    res.status(201).json(one(await claims.recordOutcome(a.db, a.userId, parseOrThrow(V.OutcomeBody, req.body, 'body'))));
  },
  list: async (req: Request, res: Response) => {
    res.json(list(check(await authOf(req).db.from('outcomes').select('*').order('outcome_date', { ascending: false }).limit(200)) as unknown[]));
  },
  summary: async (req: Request, res: Response) => {
    res.json(one(await claims.outcomeSummary(authOf(req).db)));
  },
  update: async (req: Request, res: Response) => {
    const patch = parseOrThrow(V.OutcomeBody.omit({ claim_id: true, return_window_id: true }).partial(), req.body, 'body');
    res.json(one(check(await authOf(req).db.from('outcomes').update(patch).eq('id', id(req)).select('*').maybeSingle())));
  },
  remove: async (req: Request, res: Response) => {
    check(await authOf(req).db.from('outcomes').delete().eq('id', id(req)));
    res.status(204).end();
  },
};
