/**
 * Basic data portability — never paywalled and available after cancellation.
 * Produces a machine-readable JSON file (items, coverage, purchases, claims,
 * outcomes...) plus a manifest of every original document with expiring links.
 */
import { AppError, check, notFound } from '../lib/errors.js';
import { env } from '../config/env.js';
import { BUCKETS, serviceClient, type Db } from '../lib/supabase.js';
import { audit, enqueueJob, track } from './ops.service.js';

type Row = Record<string, unknown>;

const USER_TABLES: Array<{ table: string; owner?: string; omit?: string[] }> = [
  { table: 'profiles', owner: 'id', omit: ['account_state'] },
  { table: 'purchase_groups', omit: ['idempotency_key'] },
  { table: 'receipt_lines' },
  { table: 'items', omit: ['search_text'] },
  { table: 'warranties' },
  { table: 'return_windows' },
  { table: 'registrations' },
  { table: 'attachments', omit: ['usage_reservation_id', 'idempotency_key'] },
  { table: 'item_attachments' },
  { table: 'purchase_attachments' },
  { table: 'claims' },
  { table: 'claim_attachments' },
  { table: 'claim_status_history' },
  { table: 'outcomes' },
  { table: 'payment_cards' },
  { table: 'reminders', omit: ['locked_at', 'last_error'] },
  { table: 'maintenance_tasks', owner: 'owner_id' },
  { table: 'service_records', owner: 'created_by' },
  { table: 'entitlements', omit: ['original_transaction_id', 'last_event_id'] },
  { table: 'partner_consents' },
  { table: 'support_tickets' },
];

export async function requestExport(db: Db, userId: string, opts: { includeFiles: boolean; workspaceId?: string }) {
  const svc = serviceClient();
  const job = check(await svc.from('export_jobs').insert({
    user_id: userId, include_files: opts.includeFiles, scope: opts.workspaceId ? 'workspace' : 'account', workspace_id: opts.workspaceId ?? null,
  }).select('*').single()) as Row;
  if (opts.workspaceId) {
    const ws = check(await db.from('workspaces').select('id').eq('id', opts.workspaceId).maybeSingle());
    if (!ws) throw notFound('workspace_not_found');
  }
  await enqueueJob('export_build', { export_job_id: job.id }, { userId, dedupeKey: `export:${job.id}` });
  await track(userId, 'export_requested', {});
  await audit({ actorType: 'user', actorId: userId, action: 'export.requested', targetType: 'export_job', targetId: String(job.id) });
  return job;
}

async function fetchAll(table: string, ownerCol: string, ownerId: string): Promise<Row[]> {
  const svc = serviceClient();
  const out: Row[] = [];
  for (let from = 0; ; from += 1000) {
    const page = check(await svc.from(table).select('*').eq(ownerCol, ownerId).range(from, from + 999)) as Row[];
    out.push(...page);
    if (page.length < 1000) break;
  }
  return out;
}

/** Worker handler for `export_build`. */
export async function buildExport(exportJobId: string) {
  const svc = serviceClient();
  const job = check(await svc.from('export_jobs').select('*').eq('id', exportJobId).maybeSingle()) as Row | null;
  if (!job || job.state === 'ready') return { skipped: true };
  await svc.from('export_jobs').update({ state: 'running', attempts: Number(job.attempts) + 1 }).eq('id', exportJobId);
  const userId = String(job.user_id);
  const ttl = env().EXPORT_LINK_TTL_SECONDS;

  const data: Record<string, Row[]> = {};
  if (job.scope === 'workspace') {
    const wsId = String(job.workspace_id);
    const shared = check(await svc.from('workspace_items').select('item_id, location_id').eq('workspace_id', wsId)) as Row[];
    const itemIds = shared.map((s) => String(s.item_id));
    data.workspace = check(await svc.from('workspaces').select('*').eq('id', wsId)) as Row[];
    data.locations = check(await svc.from('locations').select('*').eq('workspace_id', wsId)) as Row[];
    data.assets = shared;
    data.items = itemIds.length ? (check(await svc.from('items').select('id, name, brand, model_number, serial_number, purchase_date, retailer_name, lifecycle_state').in('id', itemIds)) as Row[]) : [];
    data.warranties = itemIds.length ? (check(await svc.from('warranties').select('*').in('item_id', itemIds)) as Row[]) : [];
    data.service_records = check(await svc.from('service_records').select('*').eq('workspace_id', wsId)) as Row[];
    data.maintenance_tasks = check(await svc.from('maintenance_tasks').select('*').eq('workspace_id', wsId)) as Row[];
  } else {
    for (const t of USER_TABLES) {
      const rows = await fetchAll(t.table, t.owner ?? 'user_id', userId);
      data[t.table] = rows.map((r) => {
        const copy = { ...r };
        for (const k of t.omit ?? []) delete copy[k];
        return copy;
      });
    }
  }

  const files: Row[] = [];
  if (job.include_files && job.scope === 'account') {
    for (const a of data.attachments ?? []) {
      if (a.processing_state !== 'ready' || a.deletion_state !== 'active') continue;
      const s = await svc.storage.from(BUCKETS.files).createSignedUrl(String(a.storage_path), ttl, { download: String(a.original_filename ?? a.id) });
      files.push({ attachment_id: a.id, filename: a.original_filename, file_type: a.file_type, sha256: a.checksum_sha256,
                   bytes: a.actual_byte_size, url: s.data?.signedUrl ?? null });
    }
  }

  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const dataPath = `${userId}/${exportJobId}/warrantra-export-${stamp}.json`;
  const manifestPath = `${userId}/${exportJobId}/files-manifest-${stamp}.json`;
  const payload = {
    format: 'warrantra-export', format_version: 1, generated_at: new Date().toISOString(), scope: job.scope,
    notes: [
      'Coverage dates carry date_certainty; "estimated" and "unknown" values were not verified.',
      'Money values are decimal strings in the stated currency.',
    ],
    data,
  };
  const up1 = await svc.storage.from(BUCKETS.exports).upload(dataPath, Buffer.from(JSON.stringify(payload, null, 2)), { contentType: 'application/json', upsert: true });
  const up2 = await svc.storage.from(BUCKETS.exports).upload(manifestPath, Buffer.from(JSON.stringify({ expires_in_seconds: ttl, files }, null, 2)), { contentType: 'application/json', upsert: true });
  if (up1.error || up2.error) throw new AppError(502, 'storage_error', 'Export upload failed');

  check(await svc.from('export_jobs').update({
    state: 'ready', data_path: dataPath, manifest_path: manifestPath, item_count: (data.items ?? []).length, file_count: files.length,
    expires_at: new Date(Date.now() + env().EXPORT_RETENTION_DAYS * 86_400_000).toISOString(), completed_at: new Date().toISOString(), error_code: null,
  }).eq('id', exportJobId));
  return { ready: true, items: (data.items ?? []).length, files: files.length };
}

export async function exportLinks(db: Db, exportJobId: string) {
  const job = check(await db.from('export_jobs').select('*').eq('id', exportJobId).maybeSingle()) as Row | null;
  if (!job) throw notFound('export_not_found');
  if (job.state !== 'ready') return { state: job.state };
  if (new Date(String(job.expires_at)) < new Date()) return { state: 'expired' };
  const ttl = env().EXPORT_LINK_TTL_SECONDS;
  const svc = serviceClient();
  const [d, m] = await Promise.all([
    svc.storage.from(BUCKETS.exports).createSignedUrl(String(job.data_path), ttl, { download: true }),
    svc.storage.from(BUCKETS.exports).createSignedUrl(String(job.manifest_path), ttl, { download: true }),
  ]);
  return {
    state: 'ready', expires_in_seconds: ttl, data_url: d.data?.signedUrl ?? null, files_manifest_url: m.data?.signedUrl ?? null,
    note: 'Links to original files inside the manifest expire; request a new export to refresh them.',
  };
}

/** Purge expired export bundles (retention schedule). */
export async function purgeExpiredExports() {
  const svc = serviceClient();
  const rows = check(await svc.from('export_jobs').select('id, data_path, manifest_path').eq('state', 'ready').lt('expires_at', new Date().toISOString()).limit(200)) as Row[];
  for (const r of rows) {
    await svc.storage.from(BUCKETS.exports).remove([String(r.data_path), String(r.manifest_path)].filter(Boolean));
    await svc.from('export_jobs').update({ state: 'expired' }).eq('id', r.id as string);
  }
  return rows.length;
}
