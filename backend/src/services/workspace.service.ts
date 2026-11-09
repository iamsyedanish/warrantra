/**
 * Household vault and business/property portfolio pilot (shared workspaces):
 * owner/admin/editor/viewer roles, invitations, revocation, item sharing,
 * locations, asset assignment, service history and maintenance.
 * Authorization is enforced by RLS + triggers; this layer adds invitations.
 */
import type { z } from 'zod';
import { env } from '../config/env.js';
import { check, forbidden, notFound } from '../lib/errors.js';
import { normalizeEmail, pepperedHash, randomToken } from '../lib/crypto.js';
import { serviceClient, type Db } from '../lib/supabase.js';
import { Locations, MaintenanceTasks, ServiceRecords, Workspaces, linkRows } from '../models/index.js';
import type {
  AssignBody, InviteBody, LocationBody, MaintenanceCompleteBody, MaintenanceTaskBody, MemberPatch, ServiceRecordBody, WorkspaceBody,
} from '../validators/index.js';
import { sendMail } from './mail.service.js';
import { audit, track } from './ops.service.js';

type Row = Record<string, unknown>;

export async function createWorkspace(db: Db, userId: string, body: z.infer<typeof WorkspaceBody>) {
  const ws = await Workspaces(db).insert({ ...body, owner_id: userId });
  await track(userId, 'household_created', {});
  await audit({ actorType: 'user', actorId: userId, action: 'workspace.created', targetType: 'workspace', targetId: String(ws.id), metadata: { kind: body.kind } });
  return ws;
}

export async function listWorkspaces(db: Db) {
  return check(await db.from('workspaces').select('*, workspace_members(user_id, role, state)').eq('archived', false));
}

export async function getWorkspace(db: Db, id: string) {
  const ws = await Workspaces(db).get(id, 'workspace_not_found');
  const [members, items, locations] = await Promise.all([
    db.from('workspace_members').select('user_id, role, state, joined_at, profiles(display_name)').eq('workspace_id', id),
    db.from('workspace_items').select('item_id, location_id, shared_by, shared_at, items(id, name, brand, model_number, lifecycle_state)').eq('workspace_id', id),
    db.from('locations').select('*').eq('workspace_id', id).eq('archived', false),
  ]);
  return { ...ws, members: check(members), items: check(items), locations: check(locations) };
}

async function requireAdmin(db: Db, workspaceId: string, userId: string) {
  const m = check(await db.from('workspace_members').select('role, state').eq('workspace_id', workspaceId).eq('user_id', userId).maybeSingle()) as Row | null;
  if (!m || m.state !== 'active' || !['owner', 'admin'].includes(String(m.role))) throw forbidden('workspace_admin_required');
}

export async function invite(db: Db, userId: string, workspaceId: string, body: z.infer<typeof InviteBody>) {
  await requireAdmin(db, workspaceId, userId);
  const ws = await Workspaces(db).get(workspaceId, 'workspace_not_found');
  const token = randomToken(32);
  const inv = check(await serviceClient().from('workspace_invitations').insert({
    workspace_id: workspaceId, email_normalized: normalizeEmail(body.email), role: body.role, token_hash: pepperedHash(token), invited_by: userId,
  }).select('id, role, expires_at').single()) as Row;
  await sendMail({
    to: body.email,
    subject: `You're invited to "${String(ws.name)}" on Warrantra`,
    text: `You've been invited to join "${String(ws.name)}" as ${body.role}.\n\nOpen Warrantra and accept with this code, or follow the link:\n` +
          `${env().PUBLIC_BASE_URL}/invite?token=${encodeURIComponent(token)}\n\nThe invitation expires in 7 days.`,
  });
  await audit({ actorType: 'user', actorId: userId, action: 'workspace.invited', targetType: 'workspace', targetId: workspaceId, metadata: { role: body.role } });
  return inv;
}

export async function acceptInvite(db: Db, userId: string, token: string) {
  const workspaceId = check(await db.rpc('accept_workspace_invitation', { p_token_hash: pepperedHash(token) })) as string;
  await audit({ actorType: 'user', actorId: userId, action: 'workspace.joined', targetType: 'workspace', targetId: workspaceId });
  return { workspace_id: workspaceId };
}

export async function revokeInvite(db: Db, userId: string, workspaceId: string, invitationId: string) {
  await requireAdmin(db, workspaceId, userId);
  check(await serviceClient().from('workspace_invitations').update({ revoked_at: new Date().toISOString() })
    .eq('id', invitationId).eq('workspace_id', workspaceId));
  return { revoked: true };
}

export async function updateMember(db: Db, userId: string, workspaceId: string, memberId: string, patch: z.infer<typeof MemberPatch>) {
  const res = check(await db.from('workspace_members').update(patch).eq('workspace_id', workspaceId).eq('user_id', memberId).select('*')) as Row[];
  if (res.length === 0) throw notFound('member_not_found');
  await audit({ actorType: 'user', actorId: userId, action: patch.state === 'revoked' ? 'workspace.member_revoked' : 'workspace.member_updated',
                targetType: 'workspace', targetId: workspaceId, metadata: { member: memberId, ...patch } });
  return { ...res[0], note: patch.state === 'revoked' ? 'Access was removed. Download links already issued expire within minutes.' : undefined };
}

export async function leave(db: Db, userId: string, workspaceId: string) {
  const res = check(await db.from('workspace_members').update({ state: 'left' }).eq('workspace_id', workspaceId).eq('user_id', userId).select('*')) as Row[];
  if (res.length === 0) throw notFound('member_not_found');
  return { left: true };
}

export async function shareItem(db: Db, userId: string, workspaceId: string, itemId: string, locationId?: string | null) {
  await linkRows(db, 'workspace_items', [{ workspace_id: workspaceId, item_id: itemId, user_id: userId, shared_by: userId, location_id: locationId ?? null }]);
  if (locationId) await assign(db, userId, workspaceId, { item_id: itemId, location_id: locationId });
  return { shared: true };
}

export async function unshareItem(db: Db, workspaceId: string, itemId: string) {
  const res = check(await db.from('workspace_items').delete().eq('workspace_id', workspaceId).eq('item_id', itemId).select('item_id')) as Row[];
  if (res.length === 0) throw notFound('shared_item_not_found');
  return { unshared: true };
}

export const createLocation = async (db: Db, userId: string, workspaceId: string, body: z.infer<typeof LocationBody>) => {
  const row = await Locations(db).insert({ ...body, workspace_id: workspaceId, created_by: userId });
  await track(userId, 'portfolio_location_created', {});
  return row;
};
export const updateLocation = (db: Db, id: string, patch: Partial<z.infer<typeof LocationBody>> & { archived?: boolean }) =>
  Locations(db).update(id, patch, undefined, 'location_not_found');

export async function assign(db: Db, userId: string, workspaceId: string, body: z.infer<typeof AssignBody>) {
  // Close the current assignment, then open a new one (full assignment history kept).
  check(await db.from('asset_assignments').update({ unassigned_at: new Date().toISOString() })
    .eq('workspace_id', workspaceId).eq('item_id', body.item_id).is('unassigned_at', null));
  const row = check(await db.from('asset_assignments').insert({
    workspace_id: workspaceId, item_id: body.item_id, location_id: body.location_id, assigned_by: userId, note: body.note ?? null,
  }).select('*').single());
  check(await db.from('workspace_items').update({ location_id: body.location_id }).eq('workspace_id', workspaceId).eq('item_id', body.item_id));
  return row;
}

export async function assetsByLocation(db: Db, workspaceId: string) {
  return check(await db.from('workspace_items')
    .select('location_id, locations(name, kind), items(id, name, brand, model_number, serial_number, lifecycle_state)')
    .eq('workspace_id', workspaceId));
}

// ---- service history -------------------------------------------------------
export async function addServiceRecord(db: Db, userId: string, body: z.infer<typeof ServiceRecordBody>) {
  const { attachment_ids, ...rest } = body;
  const row = await ServiceRecords(db).insert({ ...rest, created_by: userId });
  if (attachment_ids?.length) {
    await linkRows(db, 'service_record_attachments', attachment_ids.map((a) => ({ service_record_id: row.id, attachment_id: a, user_id: userId })));
  }
  return row;
}
export const listServiceRecords = async (db: Db, itemId: string) =>
  check(await db.from('service_records').select('*, service_record_attachments(attachment_id)').eq('item_id', itemId).order('service_date', { ascending: false }));
export const removeServiceRecord = (db: Db, id: string) => ServiceRecords(db).remove(id, 'service_record_not_found');

// ---- maintenance -----------------------------------------------------------
export const createTask = (db: Db, userId: string, body: z.infer<typeof MaintenanceTaskBody>) =>
  MaintenanceTasks(db).insert({ ...body, owner_id: userId });
export const updateTask = (db: Db, id: string, patch: Partial<z.infer<typeof MaintenanceTaskBody>>, version?: number) =>
  MaintenanceTasks(db).update(id, patch, version, 'task_not_found');
export const removeTask = (db: Db, id: string) => MaintenanceTasks(db).remove(id, 'task_not_found');
export const listTasks = async (db: Db, opts: { workspaceId?: string; itemId?: string }) => {
  let q = db.from('maintenance_tasks').select('*').neq('state', 'archived').order('next_due_on', { ascending: true, nullsFirst: false });
  if (opts.workspaceId) q = q.eq('workspace_id', opts.workspaceId);
  if (opts.itemId) q = q.eq('item_id', opts.itemId);
  return check(await q);
};
export async function completeTask(db: Db, id: string, body: z.infer<typeof MaintenanceCompleteBody>) {
  return check(await db.rpc('complete_maintenance_task', {
    p_task_id: id, p_service_date: body.service_date, p_notes: body.notes ?? null, p_provider: body.provider_name ?? null,
    p_cost: body.cost_amount ?? null, p_currency: body.cost_currency ?? null,
  }));
}
