/** Household / business workspaces, locations, assets, service history, maintenance. */
import type { Request, Response } from 'express';
import { z } from 'zod';
import { authOf } from '../middleware/auth.js';
import { expectedVersion, parseOrThrow } from '../lib/http.js';
import { Workspaces } from '../models/index.js';
import * as ws from '../services/workspace.service.js';
import { list, one } from '../views/index.js';
import * as V from '../validators/index.js';

const P = (req: Request) => parseOrThrow(z.object({ id: V.Uuid }).passthrough(), req.params, 'params') as { id: string; [k: string]: string };
const uuidParam = (req: Request, name: string) => parseOrThrow(z.object({ [name]: V.Uuid }).passthrough(), req.params, 'params')[name] as string;

export const WorkspaceController = {
  create: async (req: Request, res: Response) => {
    const a = authOf(req);
    res.status(201).json(one(await ws.createWorkspace(a.db, a.userId, parseOrThrow(V.WorkspaceBody, req.body, 'body'))));
  },
  list: async (req: Request, res: Response) => res.json(list(await ws.listWorkspaces(authOf(req).db) as unknown[])),
  get: async (req: Request, res: Response) => res.json(one(await ws.getWorkspace(authOf(req).db, P(req).id))),
  update: async (req: Request, res: Response) => {
    res.json(one(await Workspaces(authOf(req).db).update(P(req).id, parseOrThrow(V.WorkspacePatch, req.body, 'body'), undefined, 'workspace_not_found')));
  },
  invite: async (req: Request, res: Response) => {
    const a = authOf(req);
    res.status(201).json(one(await ws.invite(a.db, a.userId, P(req).id, parseOrThrow(V.InviteBody, req.body, 'body'))));
  },
  revokeInvite: async (req: Request, res: Response) => {
    const a = authOf(req);
    res.json(one(await ws.revokeInvite(a.db, a.userId, P(req).id, uuidParam(req, 'invitationId'))));
  },
  accept: async (req: Request, res: Response) => {
    const a = authOf(req);
    res.json(one(await ws.acceptInvite(a.db, a.userId, parseOrThrow(V.AcceptInviteBody, req.body, 'body').token)));
  },
  updateMember: async (req: Request, res: Response) => {
    const a = authOf(req);
    res.json(one(await ws.updateMember(a.db, a.userId, P(req).id, uuidParam(req, 'userId'), parseOrThrow(V.MemberPatch, req.body, 'body'))));
  },
  leave: async (req: Request, res: Response) => {
    const a = authOf(req);
    res.json(one(await ws.leave(a.db, a.userId, P(req).id)));
  },
  shareItem: async (req: Request, res: Response) => {
    const a = authOf(req);
    const b = parseOrThrow(V.ShareItemBody, req.body, 'body');
    res.status(201).json(one(await ws.shareItem(a.db, a.userId, P(req).id, b.item_id, b.location_id)));
  },
  unshareItem: async (req: Request, res: Response) => {
    res.json(one(await ws.unshareItem(authOf(req).db, P(req).id, uuidParam(req, 'itemId'))));
  },
  createLocation: async (req: Request, res: Response) => {
    const a = authOf(req);
    res.status(201).json(one(await ws.createLocation(a.db, a.userId, P(req).id, parseOrThrow(V.LocationBody, req.body, 'body'))));
  },
  updateLocation: async (req: Request, res: Response) => {
    const body = parseOrThrow(V.LocationBody.partial().extend({ archived: z.boolean().optional() }), req.body, 'body');
    res.json(one(await ws.updateLocation(authOf(req).db, uuidParam(req, 'locationId'), body)));
  },
  assign: async (req: Request, res: Response) => {
    const a = authOf(req);
    res.status(201).json(one(await ws.assign(a.db, a.userId, P(req).id, parseOrThrow(V.AssignBody, req.body, 'body'))));
  },
  assets: async (req: Request, res: Response) => res.json(list(await ws.assetsByLocation(authOf(req).db, P(req).id) as unknown[])),
};

export const ServiceController = {
  create: async (req: Request, res: Response) => {
    const a = authOf(req);
    res.status(201).json(one(await ws.addServiceRecord(a.db, a.userId, parseOrThrow(V.ServiceRecordBody, req.body, 'body'))));
  },
  listForItem: async (req: Request, res: Response) => res.json(list(await ws.listServiceRecords(authOf(req).db, P(req).id) as unknown[])),
  remove: async (req: Request, res: Response) => {
    await ws.removeServiceRecord(authOf(req).db, P(req).id);
    res.status(204).end();
  },
};

export const MaintenanceController = {
  create: async (req: Request, res: Response) => {
    const a = authOf(req);
    res.status(201).json(one(await ws.createTask(a.db, a.userId, parseOrThrow(V.MaintenanceTaskBody, req.body, 'body')),
      { note: 'Schedules are reminders you choose; Warrantra does not imply a task is legally or contractually required.' }));
  },
  list: async (req: Request, res: Response) => {
    const q = parseOrThrow(z.object({ workspace_id: V.Uuid.optional(), item_id: V.Uuid.optional() }), req.query, 'query');
    res.json(list(await ws.listTasks(authOf(req).db, { workspaceId: q.workspace_id, itemId: q.item_id }) as unknown[]));
  },
  update: async (req: Request, res: Response) => {
    res.json(one(await ws.updateTask(authOf(req).db, P(req).id, parseOrThrow(V.MaintenanceTaskBody.partial(), req.body, 'body'), expectedVersion(req))));
  },
  complete: async (req: Request, res: Response) => {
    res.json(one(await ws.completeTask(authOf(req).db, P(req).id, parseOrThrow(V.MaintenanceCompleteBody, req.body, 'body'))));
  },
  remove: async (req: Request, res: Response) => {
    await ws.removeTask(authOf(req).db, P(req).id);
    res.status(204).end();
  },
};
